import AppKit
import XCTest
import SnaprCore
@testable import SnaprMac

/// Tests for the history grid, the search field and the settings window.
///
/// None of them touch `~/Library/Application Support/Snapr`. The grid is driven
/// through a spy library and the settings store through its own `UserDefaults`
/// suite, which is removed again in `tearDown`.
@MainActor
final class HistoryTests: XCTestCase {

    // MARK: - The bug shape this whole feature exists to rule out

    /// A search that returns zero must never look like a library that is not
    /// indexed yet. The previous app searched only the newest 500 rows in
    /// memory, so an old row simply did not exist as far as search was
    /// concerned, and the UI said "no results" with total confidence.
    func testEmptyExplanationSaysWhichKindOfEmpty() {
        let nothingCaptured = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 0, totalCount: 0)
        let indexedAndNoMatch = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 0, totalCount: 120)
        let stillIndexing = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 7, failedOCRCount: 0, totalCount: 120)

        XCTAssertNotEqual(nothingCaptured, indexedAndNoMatch)
        XCTAssertNotEqual(nothingCaptured, stillIndexing)
        XCTAssertNotEqual(indexedAndNoMatch, stillIndexing)

        // The pending case has to carry the number, otherwise the user cannot
        // tell that waiting would change the answer.
        XCTAssertTrue(stillIndexing.contains("7"), stillIndexing)
    }

    /// A fourth kind of empty: everything was read, but some rows failed. That
    /// is a different sentence again.
    func testFailedOCRIsItsOwnExplanation() {
        let failed = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 3, totalCount: 120)
        let plain = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 0, totalCount: 120)
        XCTAssertNotEqual(failed, plain)
        XCTAssertTrue(failed.contains("3"), failed)
    }

    // MARK: - The 30x mistake

    /// The grid must read stored thumbnails and never decode a full original.
    ///
    /// MEASURED (probe A12): a stored thumbnail costs about 1 ms and a full
    /// decode costs 31 to 35 ms per tile, a 32x to 37x difference. The spy
    /// fails the test if the expensive path is taken even once.
    func testGridReadsThumbnailsAndNeverFullImages() {
        let spy = SpyLibrary(shotCount: 4)
        let grid = ShotGridView(source: spy.source)
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let window = NSWindow(contentRect: grid.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: true)
        window.contentView?.addSubview(grid)

        grid.setShots(spy.shots)
        grid.layoutSubtreeIfNeeded()

        XCTAssertEqual(spy.fullPNGCalls, 0, "the grid decoded a full original")

        // Drive the tile loader directly too, so the assertion does not depend
        // on whether a windowless collection view decided to make items.
        let image = grid.thumbnailImage(for: spy.shots[0].id)
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(spy.thumbnailPNGCalls, 0)
        XCTAssertEqual(spy.fullPNGCalls, 0, "the grid decoded a full original")
    }

    /// The same tile asked for twice costs one read, not two. A collection view
    /// asks again on every scroll pass.
    func testThumbnailIsCachedAfterTheFirstRead() {
        let spy = SpyLibrary(shotCount: 1)
        let grid = ShotGridView(source: spy.source)
        let id = spy.shots[0].id

        XCTAssertNotNil(grid.thumbnailImage(for: id))
        let afterFirst = spy.thumbnailPNGCalls
        XCTAssertNotNil(grid.thumbnailImage(for: id))
        XCTAssertEqual(spy.thumbnailPNGCalls, afterFirst)
    }

    /// One unreadable thumbnail must not blank the grid. The tile reports it.
    func testOneBadThumbnailDoesNotBlankTheGrid() {
        let spy = SpyLibrary(shotCount: 2)
        spy.failingThumbnails.insert(spy.shots[1].id)
        let grid = ShotGridView(source: spy.source)
        grid.setShots(spy.shots)

        XCTAssertNotNil(grid.thumbnailImage(for: spy.shots[0].id))
        XCTAssertNil(grid.thumbnailImage(for: spy.shots[1].id))
        XCTAssertEqual(grid.shots.count, 2)
    }

    // MARK: - A failure must be loud

    /// A library throw must produce a stated error, never a silent empty grid.
    /// An empty grid where an error happened looks exactly like data loss.
    func testALibraryThrowIsShownRatherThanAnEmptyGrid() {
        let spy = SpyLibrary(shotCount: 2)
        spy.failEverything = true
        let controller = HistoryWindowController(source: spy.source)

        controller.refresh()

        let message = controller.visibleMessage
        XCTAssertNotNil(message, "a thrown error left the grid silently empty")
        XCTAssertTrue(message?.contains("Could not") ?? false, message ?? "nil")
        // And it must not read like a library that simply has nothing in it.
        XCTAssertFalse(message?.contains("No screenshots yet") ?? true, message ?? "nil")
    }

    /// Results showing means no message on top of them.
    func testResultsLeaveNoMessageOverTheGrid() {
        let spy = SpyLibrary(shotCount: 3)
        let controller = HistoryWindowController(source: spy.source)
        controller.refresh()
        XCTAssertNil(controller.visibleMessage)
    }

    // MARK: - Search debounce

    /// Rapid typing must collapse into fewer queries than keystrokes.
    ///
    /// MEASURED (probe A13): the worst query over 5000 documents is 2.0 ms, so
    /// this is not a performance fix. It stops thirty queries being queued for
    /// results nobody will ever read.
    func testDebounceCoalescesRapidTyping() {
        let debouncer = SearchDebouncer(delay: 0.05)
        let counter = CallCounter()
        let done = expectation(description: "the debounced query ran")

        let keystrokes = 30
        for index in 0..<keystrokes {
            debouncer.schedule {
                counter.value += 1
                if index == keystrokes - 1 { done.fulfill() }
            }
        }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(counter.value, 1)
        XCTAssertLessThan(counter.value, keystrokes)
    }

    func testDebounceStillRunsTheLastQuery() {
        let debouncer = SearchDebouncer(delay: 0.02)
        let counter = CallCounter()
        let done = expectation(description: "ran")
        debouncer.schedule { counter.value += 1; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Settings

    func testSettingsRoundTripThroughTheStore() {
        let suite = "snapr.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not make a test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.afterCapture = .saveToDownloads
            $0.playShutterSound = false
            $0.showCursorInCapture = true
            $0.copyOnClose = true
            $0.colourFormat = .cssRGB
            $0.keepHistory = false
            $0.historyRetentionDays = 30
            $0.enableOCR = false
            $0.defaultAnnotationColour = SRGB(r: 10, g: 20, b: 30)
            $0.defaultLineWidth = 9
            $0.blurBlockSize = 20
            $0.hotkeys[.openHistory] = HotkeySpec(keyCode: HotkeySpec.Key.w,
                                                  modifiers: HotkeySpec.optionKey)
        }
        let written = store.settings

        // A fresh store reading the same defaults is what the next launch does.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings, written)
        XCTAssertEqual(reloaded.settings.historyRetentionDays, 30)
        XCTAssertEqual(reloaded.settings.hotkeys[.openHistory],
                       HotkeySpec(keyCode: HotkeySpec.Key.w, modifiers: HotkeySpec.optionKey))
    }

    func testDefaultSettingsHaveNoConflicts() {
        XCTAssertTrue(Settings().conflicts.isEmpty)
    }

    /// A collision inside our own set is the only kind that can be found before
    /// registration. A collision with another app on the Mac surfaces later, as
    /// OSStatus -9878.
    func testConflictInsideOurOwnSetIsDetected() {
        var settings = Settings()
        let taken = HotkeySpec(keyCode: HotkeySpec.Key.four,
                               modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        settings.hotkeys[.captureArea] = taken
        settings.hotkeys[.openHistory] = taken

        let conflicts = settings.conflicts
        XCTAssertEqual(conflicts.count, 1)
        let clashing = Set(conflicts[taken] ?? [])
        XCTAssertEqual(clashing, Set([HotkeyAction.captureArea, .openHistory]))
    }

    // MARK: - The hotkey recorder's rules

    func testCarbonModifiersMapFromEventFlags() {
        XCTAssertEqual(HotkeyRecorderView.carbonModifiers(from: [.control, .shift]),
                       HotkeySpec.controlKey | HotkeySpec.shiftKey)
        XCTAssertEqual(HotkeyRecorderView.carbonModifiers(from: [.command, .option]),
                       HotkeySpec.cmdKey | HotkeySpec.optionKey)
        // A flag we do not bind must not leak into the mask.
        XCTAssertEqual(HotkeyRecorderView.carbonModifiers(from: [.capsLock]), 0)
    }
}

/// A counter a `@MainActor` closure can add to without capturing a local `var`.
@MainActor
private final class CallCounter {
    var value = 0
}

/// A stand-in library that records which read the grid asked for.
@MainActor
private final class SpyLibrary {

    private(set) var shots: [Shot] = []
    var thumbnailPNGCalls = 0
    var fullPNGCalls = 0
    var failingThumbnails: Set<UUID> = []
    /// Every read throws, the way a wrong key or a corrupted index would.
    var failEverything = false

    private let png: Data

    init(shotCount: Int) {
        self.png = SpyLibrary.makePNG()
        for index in 0..<shotCount {
            shots.append(Shot(createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                              kind: .area,
                              size: PixelSize(width: 8, height: 8),
                              blobBytes: png.count,
                              ocrState: index == 0 ? .pending : .done))
        }
    }

    var source: ShotSource {
        ShotSource(
            recent: { [self] limit, _ in
                if failEverything { throw SpyError.unreadable }
                return Array(shots.prefix(limit))
            },
            search: { [self] _, limit in
                if failEverything { throw SpyError.unreadable }
                return Array(shots.prefix(limit))
            },
            thumbnailPNG: { [self] id in
                thumbnailPNGCalls += 1
                if failingThumbnails.contains(id) { throw SpyError.unreadable }
                return png
            },
            fullPNG: { [self] _ in
                fullPNGCalls += 1
                return png
            },
            counts: { [self] in
                if failEverything { throw SpyError.unreadable }
                return (total: shots.count, pending: 1, failed: 0)
            },
            diskBytes: { [self] in
                if failEverything { throw SpyError.unreadable }
                return png.count * shots.count
            },
            delete: { [self] id in shots.removeAll { $0.id == id } },
            deleteAll: { [self] in shots.removeAll() })
    }

    enum SpyError: Error { case unreadable }

    /// A real 8x8 PNG, so the grid's decode path is exercised for real.
    private static func makePNG() -> Data {
        // Force unwraps are fine here: this is a test fixture, and a failure to
        // build it must stop the test rather than be quietly worked around.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 8, height: 8,
                                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ImageBridge.pngData(from: context.makeImage()!)!
    }
}
