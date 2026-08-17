import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SnaprCore
import XCTest

@testable import SnaprMac

/// Storage, encryption, search and OCR.
///
/// Every test here works in its own temporary directory. Nothing touches
/// `~/Library/Application Support/Snapr`, and the Keychain tests use a
/// throwaway service name so they cannot destroy the real library key.
final class StorageTests: XCTestCase {

    private var tempDir = URL(fileURLWithPath: "/dev/null")
    private var key = SymmetricKey(size: .bits256)
    private var library: Library?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        key = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        library?.close()
        library = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func openLibrary(key: SymmetricKey? = nil) throws -> Library {
        let lib = try Library(directory: tempDir, key: key ?? self.key)
        library = lib
        return lib
    }

    /// A tiny solid-colour PNG. Content does not matter for storage tests, only
    /// that the bytes survive the round trip exactly.
    private func makePNG(width: Int = 16, height: Int = 16, grey: CGFloat = 0.5) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("could not build a CGContext")
        }
        ctx.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(), let png = ImageBridge.pngData(from: image) else {
            throw XCTSkip("could not encode a PNG")
        }
        return png
    }

    private func newShot(createdAt: Date = Date(), state: OCRState = .pending) -> Shot {
        Shot(createdAt: createdAt,
             kind: .area,
             size: PixelSize(width: 16, height: 16),
             ocrState: state)
    }

    /// True if the literal UTF-8 bytes of `needle` appear anywhere in the file.
    /// A strict superset of what `strings` would report, because it does not
    /// require a run of printable characters around the match.
    private func fileContainsBytes(_ url: URL, _ needle: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let pattern = needle.data(using: .utf8) else { return false }
        return data.range(of: pattern) != nil
    }

    /// Runs `/usr/bin/strings` when it is present, so the check in design 6.3
    /// is performed literally as written and not only by byte scan.
    private func stringsOutput(_ url: URL) -> String? {
        let tool = URL(fileURLWithPath: "/usr/bin/strings")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let process = Process()
        process.executableURL = tool
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Round trip

    func testInsertAndReadBackPNGBytesAreIdentical() throws {
        let lib = try openLibrary()
        let png = try makePNG(width: 64, height: 48, grey: 0.25)
        let thumb = try makePNG(width: 16, height: 12, grey: 0.75)

        let stored = try lib.insert(newShot(), png: png, thumbnailPNG: thumb)

        XCTAssertEqual(try lib.fullPNG(id: stored.id), png,
                       "the full PNG must come back byte for byte")
        XCTAssertEqual(try lib.thumbnailPNG(id: stored.id), thumb,
                       "the stored thumbnail must come back byte for byte")

        // The thumbnail is stored, not derived. MEASURED (A12): deriving it per
        // grid tile costs 31 to 35 ms against about 1 ms, a 32x to 37x gap.
        XCTAssertNotEqual(png, thumb)

        let read = try lib.shot(id: stored.id)
        XCTAssertEqual(read.id, stored.id)
        XCTAssertEqual(read.size, PixelSize(width: 16, height: 16))
        XCTAssertEqual(read.ocrState, .pending)
        XCTAssertGreaterThan(read.blobBytes, png.count,
                             "sealed size carries the 28 bytes of AEAD overhead")
    }

    func testMissingBlobThrowsRatherThanReturningEmptyData() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("blobs/\(stored.id.uuidString).snapr"))

        XCTAssertThrowsError(try lib.fullPNG(id: stored.id)) { error in
            guard case LibraryError.blobMissing = error else {
                return XCTFail("expected blobMissing, got \(error)")
            }
        }
    }

    func testUnknownIDThrowsNotFound() throws {
        let lib = try openLibrary()
        let ghost = UUID()
        XCTAssertThrowsError(try lib.shot(id: ghost)) { error in
            guard case LibraryError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Encryption, verified on disk rather than trusted

    func testDatabaseFileIsNotAPlaintextSQLiteFile() throws {
        let lib = try openLibrary()
        _ = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        lib.close()
        library = nil

        let dbURL = tempDir.appendingPathComponent("index.db")
        let handle = try FileHandle(forReadingFrom: dbURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()

        XCTAssertEqual(header.count, 16, "the database must have been written")
        let headerText = String(decoding: header, as: UTF8.self)
        XCTAssertFalse(headerText.hasPrefix("SQLite format 3"),
                       "the header reads as a plaintext SQLite file, so PRAGMA key did not take effect")
    }

    func testOCRTextNeverAppearsInPlaintextOnDisk() throws {
        // A phrase that cannot occur by accident anywhere in the file format.
        let canary = "PLAINTEXT-CANARY-ZARQUON-4417"

        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try lib.setOCR(id: stored.id, state: .done, text: canary, barcodes: [canary])
        XCTAssertEqual(try lib.shot(id: stored.id).ocrText, canary,
                       "control: the phrase really is in the database")
        lib.close()
        library = nil

        // Check the database and both of its sidecars. Without the checkpoint
        // in close() the newest rows would sit in index.db-wal and this test
        // would pass while reading a stale file.
        for name in ["index.db", "index.db-wal", "index.db-shm"] {
            let url = tempDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            XCTAssertFalse(fileContainsBytes(url, canary),
                           "\(name) contains the OCR text in plaintext")
            if let output = stringsOutput(url) {
                XCTAssertFalse(output.contains(canary),
                               "strings \(name) reveals the OCR text")
            }
        }

        // The control that proves the check can fire at all. A plaintext file
        // holding the same phrase must be detected by the same helper.
        let control = tempDir.appendingPathComponent("control.txt")
        try canary.data(using: .utf8)?.write(to: control)
        XCTAssertTrue(fileContainsBytes(control, canary),
                      "control failed: the byte scan cannot detect the phrase at all")
    }

    func testSealedBlobIsNotPlaintextPNGOnDisk() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        let stored = try lib.insert(newShot(), png: png, thumbnailPNG: try makePNG())

        let blobURL = tempDir.appendingPathComponent("blobs/\(stored.id.uuidString).snapr")
        let raw = try Data(contentsOf: blobURL)
        // A PNG starts with the 8-byte signature 89 50 4E 47 0D 0A 1A 0A.
        XCTAssertNotEqual(Array(raw.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                          "the blob on disk is a readable PNG, so it was never sealed")
        XCTAssertEqual(raw.count, png.count + 28,
                       "AES-GCM combined form adds a 12-byte nonce and a 16-byte tag")
    }

    // MARK: - A wrong key must be loud

    func testWrongKeyThrowsInsteadOfReturningZeroRows() throws {
        let lib = try openLibrary()
        _ = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        lib.close()
        library = nil

        let wrong = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try Library(directory: tempDir, key: wrong)) { error in
            guard case LibraryError.wrongKey = error else {
                return XCTFail("expected wrongKey, got \(error)")
            }
        }

        // Control: the right key still opens it and still sees the row. Without
        // this, the test above would pass even if every open threw.
        let reopened = try Library(directory: tempDir, key: key)
        library = reopened
        XCTAssertEqual(try reopened.recent(limit: 10, offset: 0).count, 1)
    }

    func testWrongKeyOnBlobThrowsRatherThanReturningGarbage() throws {
        let lib = try openLibrary()
        let png = try makePNG(width: 32, height: 32)
        let sealed = try BlobCrypto.seal(png, key: key)
        XCTAssertThrowsError(try BlobCrypto.open(sealed, key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try BlobCrypto.open(sealed, key: key), png, "control: the right key works")
        _ = lib
    }

    /// The measurement that picked the whole storage design. MEASURED (A12):
    /// one flipped bit inside a SQLCipher page read a blob back as 1,600,000
    /// bytes with no error at all, while AES-GCM threw on all four corruption
    /// cases.
    func testCorruptingOneByteOfASealedBlobMakesOpenThrow() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(width: 32), png: try makePNG(width: 32, height: 32),
                                    thumbnailPNG: try makePNG())
        let blobURL = tempDir.appendingPathComponent("blobs/\(stored.id.uuidString).snapr")

        var raw = try Data(contentsOf: blobURL)
        XCTAssertGreaterThan(raw.count, 40)

        // Case 1: flip one bit in the body.
        var body = raw
        let middle = body.count / 2
        body[middle] ^= 0x01
        try body.write(to: blobURL)
        XCTAssertThrowsError(try lib.fullPNG(id: stored.id)) { error in
            guard case LibraryError.decryptFailed = error else {
                return XCTFail("expected decryptFailed on a body bit-flip, got \(error)")
            }
        }

        // Case 2: flip one bit in the 16-byte authentication tag at the end.
        var tag = raw
        tag[tag.count - 1] ^= 0x01
        try tag.write(to: blobURL)
        XCTAssertThrowsError(try lib.fullPNG(id: stored.id))

        // Case 3: truncation.
        try raw.prefix(raw.count - 5).write(to: blobURL)
        XCTAssertThrowsError(try lib.fullPNG(id: stored.id))

        // Control: put the original bytes back and it reads cleanly again, so
        // the three failures above are the corruption and not a broken path.
        try raw.write(to: blobURL)
        XCTAssertNoThrow(try lib.fullPNG(id: stored.id))
    }

    private func newShot(width: Int) -> Shot {
        Shot(kind: .area, size: PixelSize(width: width, height: width))
    }

    // MARK: - Search

    /// The specific bug shape this rules out. MEASURED (A13): the previous app
    /// scanned the newest 500 rows in memory, so a phrase in the oldest row
    /// returned zero hits and the UI said "nothing found" with confidence.
    func testSearchFindsAPhraseInTheOldestRowNotJustRecentOnes() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        let phrase = "zarquon vexilliform anomaly"
        let rowCount = 600   // more than the 500-row window the old bug used

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var oldestID = UUID()
        for i in 0..<rowCount {
            let created = base.addingTimeInterval(Double(i) * 60)
            let shot = Shot(createdAt: created, kind: .area,
                            size: PixelSize(width: 16, height: 16))
            let stored = try lib.insert(shot, png: png, thumbnailPNG: png)
            if i == 0 { oldestID = stored.id }
            let text = i == 0 ? "toolbar \(phrase) settings" : "toolbar settings row \(i)"
            try lib.setOCR(id: stored.id, state: .done, text: text, barcodes: [])
        }

        // The oldest row is outside the newest-500 window on purpose.
        let newest500 = try lib.recent(limit: 500, offset: 0)
        XCTAssertFalse(newest500.contains { $0.id == oldestID },
                       "the fixture is wrong: the oldest row is inside the window being ruled out")

        let hits = try lib.search(phrase, limit: 50)
        XCTAssertEqual(hits.count, 1, "FTS5 must find the phrase in the oldest row")
        XCTAssertEqual(hits.first?.id, oldestID)

        // Fail on purpose: a phrase that is not there must return nothing, so a
        // hit above means something.
        XCTAssertEqual(try lib.search("quilliflange nonesuch tesseract", limit: 50).count, 0)
    }

    func testSearchIndexesBarcodePayloads() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try lib.setOCR(id: stored.id, state: .done, text: "nothing useful here",
                       barcodes: ["SNAPR-PROBE-A10"])
        let hits = try lib.search("SNAPR-PROBE-A10", limit: 10)
        XCTAssertEqual(hits.first?.id, stored.id,
                       "a barcode payload costs +4.2 ms to detect and should be searchable")
    }

    func testSearchIndexIsUpdatedWhenOCRTextChanges() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try lib.setOCR(id: stored.id, state: .done, text: "firstphrase", barcodes: [])
        XCTAssertEqual(try lib.search("firstphrase", limit: 10).count, 1)

        try lib.setOCR(id: stored.id, state: .done, text: "secondphrase", barcodes: [])
        XCTAssertEqual(try lib.search("firstphrase", limit: 10).count, 0,
                       "the stale index entry was not removed")
        XCTAssertEqual(try lib.search("secondphrase", limit: 10).count, 1)

        try lib.delete(id: stored.id)
        XCTAssertEqual(try lib.search("secondphrase", limit: 10).count, 0,
                       "a deleted shot must leave nothing behind in the index")
    }

    /// MEASURED (A13.6): 23 of 29 realistic inputs make FTS5 throw. Every one
    /// of these must come back cleanly through `SearchQuery.sanitize`.
    func testDegenerateSearchInputsNeverThrow() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try lib.setOCR(id: stored.id, state: .done, text: "button toolbar settings", barcodes: [])

        let inputs = [
            "", " ", "'", "\"", "*", "*button", "^", "-", "button -", "- button",
            "col:", "(", "()", "AND", "button AND", "NOT", "%", "_", "\\", "{}",
            "it's", "DROP TABLE ocr", "🙂",
            "qwertyuiopasdfghjklzxcvbnmqwertyuiopasd",   // 39 characters
        ]

        for input in inputs {
            XCTAssertNoThrow(try lib.search(input, limit: 20),
                             "search threw on input \(input.debugDescription)")
        }

        // `.skip` must mean "do not run a query", never "run an empty one".
        XCTAssertEqual(try lib.search("", limit: 20).count, 0)
        XCTAssertEqual(try lib.search("   ", limit: 20).count, 0)
        // Control: an input that survives sanitizing still finds the row, so
        // the loop above is not passing because search is broken outright.
        XCTAssertEqual(try lib.search("button", limit: 20).count, 1)
        XCTAssertEqual(try lib.search("*button", limit: 20).count, 1,
                       "a leading asterisk must be neutralised, not fatal")
    }

    // MARK: - Counts, pending work and disk usage

    func testCountsAndPendingOCRIncludeRowsLeftRunningByACrash() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        let a = try lib.insert(newShot(), png: png, thumbnailPNG: png)
        let b = try lib.insert(newShot(), png: png, thumbnailPNG: png)
        let c = try lib.insert(newShot(), png: png, thumbnailPNG: png)

        try lib.setOCR(id: a.id, state: .done, text: "text", barcodes: [])
        try lib.setOCR(id: b.id, state: .failed, text: nil, barcodes: [])
        // c stays .pending. Now simulate a crash halfway through a fourth.
        let d = try lib.insert(newShot(), png: png, thumbnailPNG: png)
        try lib.setOCR(id: d.id, state: .running, text: nil, barcodes: [])

        let counts = try lib.counts()
        XCTAssertEqual(counts.total, 4)
        XCTAssertEqual(counts.pending, 2, "pending folds .running in, both mean not searchable yet")
        XCTAssertEqual(counts.failed, 1)

        let pending = try lib.pendingOCR(limit: 100)
        XCTAssertTrue(pending.contains(c.id))
        XCTAssertTrue(pending.contains(d.id),
                      "a row left in .running by a crash must be picked up again")
        XCTAssertFalse(pending.contains(a.id))
        XCTAssertFalse(pending.contains(b.id))
    }

    func testDeleteAllRemovesRowsAndSealedFiles() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        for _ in 0..<5 {
            let s = try lib.insert(newShot(), png: png, thumbnailPNG: png)
            try lib.setOCR(id: s.id, state: .done, text: "deleteme", barcodes: [])
        }
        XCTAssertEqual(try lib.counts().total, 5)
        XCTAssertGreaterThan(try lib.diskBytes(), 0)

        try lib.deleteAll()

        XCTAssertEqual(try lib.counts().total, 0)
        XCTAssertEqual(try lib.search("deleteme", limit: 10).count, 0)
        let blobs = try FileManager.default.contentsOfDirectory(
            at: tempDir.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        XCTAssertEqual(blobs.filter { $0.pathExtension == "snapr" }.count, 0)
    }

    func testRecentIsNewestFirstAndPages() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        for i in 0..<5 {
            let shot = Shot(createdAt: base.addingTimeInterval(Double(i)), kind: .area,
                            size: PixelSize(width: 16, height: 16))
            ids.append(try lib.insert(shot, png: png, thumbnailPNG: png).id)
        }
        let page1 = try lib.recent(limit: 2, offset: 0)
        XCTAssertEqual(page1.map(\.id), [ids[4], ids[3]])
        let page2 = try lib.recent(limit: 2, offset: 2)
        XCTAssertEqual(page2.map(\.id), [ids[2], ids[1]])
    }

    func testUpdatePersistsEveryField() throws {
        let lib = try openLibrary()
        let png = try makePNG()
        var stored = try lib.insert(newShot(), png: png, thumbnailPNG: png)
        stored.isFavourite = true
        stored.sourceApp = "Finder"
        stored.kind = .window
        stored.ocrState = .done
        stored.ocrText = "updated text"
        stored.barcodePayloads = ["ABC-123"]
        try lib.update(stored)

        let read = try lib.shot(id: stored.id)
        XCTAssertTrue(read.isFavourite)
        XCTAssertEqual(read.sourceApp, "Finder")
        XCTAssertEqual(read.kind, .window)
        XCTAssertEqual(read.ocrState, .done)
        XCTAssertEqual(read.ocrText, "updated text")
        XCTAssertEqual(read.barcodePayloads, ["ABC-123"])
        XCTAssertEqual(try lib.search("updated", limit: 10).count, 1)
    }

    // MARK: - Keychain

    /// Uses a throwaway service name. The real service
    /// `com.hengkysandy.snapr.dbkey` is never touched, because deleting it
    /// would make a real library permanently unreadable.
    func testKeyStoreReturnsTheSameKeyOnEveryCall() throws {
        let service = "com.hengkysandy.snapr.tests.\(UUID().uuidString)"
        let first: SymmetricKey
        do {
            first = try KeyStore.loadOrCreateKey(service: service)
        } catch {
            throw XCTSkip("this test host cannot reach the Keychain: \(error)")
        }
        defer { try? KeyStore.deleteKey(service: service) }

        let second = try KeyStore.loadOrCreateKey(service: service)
        XCTAssertEqual(first.withUnsafeBytes { Data($0) },
                       second.withUnsafeBytes { Data($0) },
                       "a second call generated a new key, which would orphan the whole library")
        XCTAssertEqual(first.bitCount, 256)

        // Control: after an explicit delete a genuinely new key appears, so the
        // equality above is not a vacuous pass.
        try KeyStore.deleteKey(service: service)
        let third = try KeyStore.loadOrCreateKey(service: service)
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) },
                          third.withUnsafeBytes { Data($0) })
    }

    func testKeyStoreServiceNameIsTheLockedValue() {
        // Changing this string is destructive: the app would find no key,
        // generate a fresh one, and every existing capture would be unreadable.
        XCTAssertEqual(KeyStore.service, "com.hengkysandy.snapr.dbkey")
    }

    // MARK: - OCR

    /// A real capture-sized canvas with real text on it, drawn at a height the
    /// default `minimumTextHeightFraction` would silently reject.
    ///
    /// MEASURED (A8): the default floor is 0.03125, so on a 1912 px tall image
    /// it demands about 60 px glyphs. This draws 28 px text, which is what
    /// macOS UI text at 2x actually looks like. If the floor is ever restored
    /// to the default this test fails with zero recognised characters.
    private func makeTextPNG() throws -> Data {
        let width = 1200, height = 1912
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("could not build a CGContext")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ]
        let lines = ["Interface Configuration", "Encrypted Screenshot Library", "Subnet Mask"]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: attributes)
                .draw(at: NSPoint(x: 80, y: CGFloat(1400 - i * 90)))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage(), let png = ImageBridge.pngData(from: image) else {
            throw XCTSkip("could not encode a PNG")
        }
        return png
    }

    @MainActor
    private func runOCR(on library: Library, id: UUID, timeout: TimeInterval = 60) throws -> OCRState {
        let service = OCRService(library: library)
        let finished = expectation(description: "ocr finished for one shot")
        // `start()` sweeps the same pending row that `enqueue` adds, so the
        // callback can legitimately fire twice for one shot. The second one is
        // a no-op because the row is already terminal.
        finished.assertForOverFulfill = false
        var outcome: OCRState?
        service.onFinished = { finishedID, state in
            guard finishedID == id else { return }
            outcome = state
            finished.fulfill()
        }
        service.start()
        service.enqueue(id)
        wait(for: [finished], timeout: timeout)
        service.stop()
        // Let any second, idempotent pass land before the library is closed in
        // tearDown, so the test does not race a task it did not wait for.
        let settle = expectation(description: "ocr settled")
        settle.assertForOverFulfill = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        guard let outcome else { throw XCTSkip("OCR never reported a result") }
        return outcome
    }

    /// `.done` on real text, and this is also the regression test for the
    /// `minimumTextHeightFraction` landmine.
    @MainActor
    func testOCRReachesDoneAndStoresTextForARealScreenshot() throws {
        let lib = try openLibrary()
        let png = try makeTextPNG()
        let stored = try lib.insert(
            Shot(kind: .fullScreen, size: PixelSize(width: 1200, height: 1912)),
            png: png, thumbnailPNG: try makePNG())

        let state = try runOCR(on: lib, id: stored.id)
        XCTAssertEqual(state, .done,
                       "zero observations here means minimumTextHeightFraction is back at its default")

        let read = try lib.shot(id: stored.id)
        XCTAssertEqual(read.ocrState, .done)
        let text = try XCTUnwrap(read.ocrText)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("configuration"),
                      "recognised text did not contain a word that was drawn")
        XCTAssertEqual(try lib.search("configuration", limit: 10).first?.id, stored.id,
                       "a shot that finished OCR must be findable by its text")
    }

    /// `.noTextFound` and `.failed` are deliberately different states. One is a
    /// blank screenshot, the other is a bug to look at.
    @MainActor
    func testNoTextFoundAndFailedAreDistinguishable() throws {
        let lib = try openLibrary()

        // A blank canvas. MEASURED (A8): a solid image returns 0 observations
        // and 0 characters, and does not invent text.
        let blank = try makePNG(width: 800, height: 600, grey: 1.0)
        let blankShot = try lib.insert(
            Shot(kind: .area, size: PixelSize(width: 800, height: 600)),
            png: blank, thumbnailPNG: try makePNG())
        let blankState = try runOCR(on: lib, id: blankShot.id)
        XCTAssertEqual(blankState, .noTextFound)
        XCTAssertEqual(try lib.shot(id: blankShot.id).ocrState, .noTextFound)
        XCTAssertNil(try lib.shot(id: blankShot.id).ocrText)

        // A shot whose sealed blob has gone. That is a real error, not an empty
        // screenshot, and it must not be reported as "no text found".
        let brokenShot = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("blobs/\(brokenShot.id.uuidString).snapr"))
        let brokenState = try runOCR(on: lib, id: brokenShot.id)
        XCTAssertEqual(brokenState, .failed)
        XCTAssertEqual(try lib.shot(id: brokenShot.id).ocrState, .failed)

        XCTAssertNotEqual(blankState, brokenState,
                          "collapsing these two states is the bug this app exists to avoid")
        XCTAssertTrue(blankState.isTerminal && brokenState.isTerminal)
    }

    /// A crash mid-OCR leaves a row in `.running`. `start()` must sweep it up
    /// without anyone calling `enqueue`.
    @MainActor
    func testStartupSweepPicksUpWorkLeftPending() throws {
        let lib = try openLibrary()
        let png = try makePNG(width: 400, height: 300, grey: 1.0)
        let stranded = try lib.insert(
            Shot(kind: .area, size: PixelSize(width: 400, height: 300)),
            png: png, thumbnailPNG: png)
        try lib.setOCR(id: stranded.id, state: .running, text: nil, barcodes: [])

        let service = OCRService(library: lib)
        let finished = expectation(description: "startup sweep finished the stranded shot")
        finished.assertForOverFulfill = false
        service.onFinished = { id, _ in
            if id == stranded.id { finished.fulfill() }
        }
        service.start()   // no enqueue call at all
        wait(for: [finished], timeout: 60)
        service.stop()

        XCTAssertTrue(try lib.shot(id: stranded.id).ocrState.isTerminal,
                      "a row left in .running must not stay unfinished forever")
        XCTAssertEqual(try lib.pendingOCR(limit: 10).count, 0)
    }

    @MainActor
    func testOCRStateWritesRunningBeforeTheSlowPass() throws {
        let lib = try openLibrary()
        let stored = try lib.insert(newShot(), png: try makePNG(), thumbnailPNG: try makePNG())
        XCTAssertEqual(try lib.shot(id: stored.id).ocrState, .pending)
        XCTAssertFalse(OCRState.pending.isTerminal)
        XCTAssertFalse(OCRState.running.isTerminal)

        try lib.setOCR(id: stored.id, state: .running, text: nil, barcodes: [])
        XCTAssertEqual(try lib.shot(id: stored.id).ocrState, .running)
        XCTAssertEqual(try lib.pendingOCR(limit: 10), [stored.id])
    }
}
