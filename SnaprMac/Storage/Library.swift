import CryptoKit
import Foundation
import SnaprCore
import SQLCipher

enum LibraryError: Error, CustomStringConvertible {
    case openFailed(String)
    case sqlite(String, Int32)
    case notFound(UUID)
    case blobMissing(UUID)
    case decryptFailed(UUID)
    /// The database exists but this key does not open it.
    ///
    /// This case exists so the failure is loud. A wrong key that returns zero
    /// rows looks exactly like an empty history, which looks exactly like data
    /// loss, and the user would have no way to tell the difference.
    case wrongKey

    var description: String {
        switch self {
        case .openFailed(let what): return "open failed: \(what)"
        case .sqlite(let what, let code): return "sqlite \(code) during \(what)"
        case .notFound(let id): return "no shot \(id.uuidString)"
        case .blobMissing(let id): return "blob missing for \(id.uuidString)"
        case .decryptFailed(let id): return "blob failed to decrypt for \(id.uuidString)"
        case .wrongKey: return "wrong database key"
        }
    }
}

/// `SQLITE_TRANSIENT` is a macro, so it does not survive into Swift. Without it
/// sqlite keeps the caller's pointer, which is dangling the moment the bridged
/// Swift string goes away.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The encrypted library: a SQLCipher index next to AES-GCM sealed image files.
///
/// Layout, and it is a locked decision:
/// ```
/// <directory>/index.db          SQLCipher. Metadata, OCR text, FTS5. No image bytes
/// <directory>/blobs/<uuid>.snapr   sealed PNG, the full capture
/// <directory>/thumbs/<uuid>.snapr  sealed PNG, ~320 px on the long edge
/// ```
///
/// MEASURED (probe A12), 200 screenshots from 250 KB to 8 MB: inserting a blob
/// into SQLCipher took 6.12 ms median against 0.81 ms for a sealed file plus an
/// index row, and 504 MB on disk against 530 MB. Speed is not why this design
/// won. Corruption handling is: see `BlobCrypto`.
///
/// `@unchecked Sendable` because the sqlite handle is a C pointer the compiler
/// cannot reason about. Every access to it goes through one serial queue, which
/// is the invariant that makes the annotation true.
final class Library: @unchecked Sendable {

    private var handle: OpaquePointer?
    private let key: SymmetricKey
    private let directory: URL
    private let blobsDir: URL
    private let thumbsDir: URL

    /// The only thread that ever touches `handle` or the sealed files. Serial,
    /// so no method needs its own lock and none of them can interleave.
    private let queue = DispatchQueue(label: "com.hengkysandy.snapr.library")

    /// Opens (or creates) the library in `directory`.
    ///
    /// Tests pass a temporary directory. The app passes `Paths.support`, which
    /// `standard(key:)` below does for it.
    init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory
        self.key = key
        self.blobsDir = directory.appendingPathComponent("blobs", isDirectory: true)
        self.thumbsDir = directory.appendingPathComponent("thumbs", isDirectory: true)

        let fm = FileManager.default
        for dir in [directory, blobsDir, thumbsDir] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw LibraryError.openFailed("could not create \(dir.lastPathComponent)")
            }
        }

        let dbPath = directory.appendingPathComponent("index.db").path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            if h != nil { sqlite3_close_v2(h) }
            throw LibraryError.openFailed("sqlite3_open_v2 returned \(rc)")
        }
        handle = opened

        do {
            try applyKey()
            try verifyKey()
            try configure()
            try migrate()
        } catch {
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }

        Log.library.info("library opened at index.db")
    }

    /// The app's library, in the locked support directory.
    static func standard(key: SymmetricKey) throws -> Library {
        try Paths.createIfNeeded()
        return try Library(directory: Paths.support, key: key)
    }

    deinit {
        if handle != nil { sqlite3_close_v2(handle) }
    }

    func close() {
        queue.sync {
            guard handle != nil else { return }
            // Fold the WAL back into index.db before closing. Without this the
            // newest rows live in index.db-wal, and anything inspecting the
            // file (including the on-disk encryption tests) reads a stale one.
            sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
            sqlite3_close_v2(handle)
            handle = nil
        }
    }

    // MARK: - Opening

    /// `PRAGMA key` in raw form, and it MUST be the very first statement after
    /// `sqlite3_open`. If anything else runs first, SQLCipher writes the file
    /// as plaintext and nothing reports a problem.
    ///
    /// `PRAGMA key`, not `sqlite3_key()`: the C function is only declared when
    /// `SQLITE_HAS_CODEC` is defined at header level, which a binary target
    /// does not do for its consumers.
    ///
    /// The raw `x'...'` form skips PBKDF2 entirely. That is correct here
    /// because the key is already 256 bits of CryptoKit randomness, not a
    /// passphrase, so there is nothing for a KDF to stretch.
    private func applyKey() throws {
        // Not user input and not concatenated SQL in the injection sense: this
        // is 64 characters of hex produced from a CryptoKit key. A PRAGMA
        // cannot take a bound parameter, so there is no other way to pass it.
        let hex = key.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
        try exec("PRAGMA key = \"x'\(hex)'\";", what: "PRAGMA key")
    }

    /// The check that separates "wrong key" from "empty database".
    ///
    /// `PRAGMA key` always returns OK, even with a completely wrong key. The
    /// failure appears only on the first real read. Skipping this read is the
    /// dangerous pattern: the caller then sees zero rows and calls it an empty
    /// history.
    private func verifyKey() throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard rc == SQLITE_OK, let stmt else {
            Log.library.error("database did not open with this key, prepare rc \(rc)")
            throw LibraryError.wrongKey
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            // Measured on the probe: a wrong key gives 26 SQLITE_NOTADB here.
            Log.library.error("database did not open with this key, step rc \(step)")
            throw LibraryError.wrongKey
        }
    }

    private func configure() throws {
        // WAL keeps a background OCR write from blocking a foreground read of
        // the history grid. busy_timeout covers the short overlap anyway.
        try exec("PRAGMA journal_mode = WAL;", what: "journal_mode")
        try exec("PRAGMA synchronous = NORMAL;", what: "synchronous")
        try exec("PRAGMA busy_timeout = 3000;", what: "busy_timeout")
        try exec("PRAGMA foreign_keys = ON;", what: "foreign_keys")
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS shots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uuid TEXT NOT NULL UNIQUE,
              created_at REAL NOT NULL,
              kind TEXT NOT NULL,
              width INTEGER NOT NULL,
              height INTEGER NOT NULL,
              blob_bytes INTEGER NOT NULL,
              ocr_state TEXT NOT NULL,
              ocr_text TEXT,
              barcodes TEXT NOT NULL DEFAULT '[]',
              source_app TEXT,
              is_favourite INTEGER NOT NULL DEFAULT 0
            );
            """, what: "create shots")
        try exec("CREATE INDEX IF NOT EXISTS idx_shots_created ON shots(created_at DESC);",
                 what: "create idx_shots_created")
        try exec("CREATE INDEX IF NOT EXISTS idx_shots_state ON shots(ocr_state);",
                 what: "create idx_shots_state")

        // Contentless FTS5: the index stores no copy of the text, only the
        // terms. The text itself already lives in shots.ocr_text, so a copy
        // would double the encrypted footprint for nothing.
        //
        // MEASURED (probe A13), 5000 documents and 3.21 MB of OCR text: 21 ms
        // to build the whole index, 1.32 MB on disk, worst query 2.0 ms, and a
        // rare phrase in the OLDEST row found in 0.010 ms. That last number is
        // the point. The previous app scanned the newest 500 rows in memory,
        // so an old row simply did not exist as far as search was concerned.
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS ocr USING fts5(body, content='');",
                 what: "create ocr fts5")
    }

    // MARK: - Writing

    func insert(_ shot: Shot, png: Data, thumbnailPNG: Data) throws -> Shot {
        try queue.sync {
            let sealedFull = try BlobCrypto.seal(png, key: key)
            let sealedThumb = try BlobCrypto.seal(thumbnailPNG, key: key)
            let fullURL = blobsDir.appendingPathComponent(shot.blobFilename)
            let thumbURL = thumbsDir.appendingPathComponent(shot.thumbFilename)

            do {
                try sealedFull.write(to: fullURL, options: .atomic)
                try sealedThumb.write(to: thumbURL, options: .atomic)
            } catch {
                // Do not leave one half of a capture on disk.
                try? FileManager.default.removeItem(at: fullURL)
                try? FileManager.default.removeItem(at: thumbURL)
                throw LibraryError.openFailed("could not write sealed blob")
            }

            var stored = shot
            stored.blobBytes = sealedFull.count

            do {
                let sql = """
                    INSERT INTO shots
                      (uuid, created_at, kind, width, height, blob_bytes,
                       ocr_state, ocr_text, barcodes, source_app, is_favourite)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                let stmt = try prepare(sql, what: "insert shot")
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, stored.id.uuidString)
                sqlite3_bind_double(stmt, 2, stored.createdAt.timeIntervalSince1970)
                bindText(stmt, 3, stored.kind.rawValue)
                sqlite3_bind_int64(stmt, 4, Int64(stored.size.width))
                sqlite3_bind_int64(stmt, 5, Int64(stored.size.height))
                sqlite3_bind_int64(stmt, 6, Int64(stored.blobBytes))
                bindText(stmt, 7, stored.ocrState.rawValue)
                bindTextOrNull(stmt, 8, stored.ocrText)
                bindText(stmt, 9, encodeBarcodes(stored.barcodePayloads))
                bindTextOrNull(stmt, 10, stored.sourceApp)
                sqlite3_bind_int64(stmt, 11, stored.isFavourite ? 1 : 0)
                try step(stmt, what: "insert shot")

                let rowid = sqlite3_last_insert_rowid(handle)
                try reindex(rowid: rowid,
                            oldBody: nil,
                            text: stored.ocrText,
                            barcodes: stored.barcodePayloads)
            } catch {
                try? FileManager.default.removeItem(at: fullURL)
                try? FileManager.default.removeItem(at: thumbURL)
                throw error
            }

            Log.library.info("""
                inserted shot kind=\(stored.kind.rawValue, privacy: .public) \
                px=\(stored.size.width)x\(stored.size.height) \
                sealed=\(Redact.bytes(stored.blobBytes), privacy: .public) \
                thumb=\(Redact.bytes(sealedThumb.count), privacy: .public)
                """)
            return stored
        }
    }

    /// Replaces every metadata field of an existing row, and reindexes its text.
    func update(_ shot: Shot) throws {
        try queue.sync {
            let (rowid, existing) = try rowLocked(id: shot.id)
            let sql = """
                UPDATE shots SET created_at = ?, kind = ?, width = ?, height = ?,
                  blob_bytes = ?, ocr_state = ?, ocr_text = ?, barcodes = ?,
                  source_app = ?, is_favourite = ?
                WHERE id = ?;
                """
            let stmt = try prepare(sql, what: "update shot")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, shot.createdAt.timeIntervalSince1970)
            bindText(stmt, 2, shot.kind.rawValue)
            sqlite3_bind_int64(stmt, 3, Int64(shot.size.width))
            sqlite3_bind_int64(stmt, 4, Int64(shot.size.height))
            sqlite3_bind_int64(stmt, 5, Int64(shot.blobBytes))
            bindText(stmt, 6, shot.ocrState.rawValue)
            bindTextOrNull(stmt, 7, shot.ocrText)
            bindText(stmt, 8, encodeBarcodes(shot.barcodePayloads))
            bindTextOrNull(stmt, 9, shot.sourceApp)
            sqlite3_bind_int64(stmt, 10, shot.isFavourite ? 1 : 0)
            sqlite3_bind_int64(stmt, 11, rowid)
            try step(stmt, what: "update shot")

            try reindex(rowid: rowid,
                        oldBody: indexBody(text: existing.ocrText,
                                           barcodes: existing.barcodePayloads),
                        text: shot.ocrText,
                        barcodes: shot.barcodePayloads)
        }
    }

    /// Writes the outcome of one OCR pass.
    ///
    /// This is a full setter, not a merge. `.running` is written with no text on
    /// purpose: whatever was there is about to be replaced, and a row left in
    /// `.running` by a crash is picked up again by `pendingOCR`.
    func setOCR(id: UUID, state: OCRState, text: String?, barcodes: [String]) throws {
        try queue.sync {
            let (rowid, existing) = try rowLocked(id: id)
            let sql = "UPDATE shots SET ocr_state = ?, ocr_text = ?, barcodes = ? WHERE id = ?;"
            let stmt = try prepare(sql, what: "set ocr")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            bindTextOrNull(stmt, 2, text)
            bindText(stmt, 3, encodeBarcodes(barcodes))
            sqlite3_bind_int64(stmt, 4, rowid)
            try step(stmt, what: "set ocr")

            try reindex(rowid: rowid,
                        oldBody: indexBody(text: existing.ocrText,
                                           barcodes: existing.barcodePayloads),
                        text: text,
                        barcodes: barcodes)

            // Redact.text gives a character count, never the characters.
            Log.library.info("""
                ocr state=\(state.rawValue, privacy: .public) \
                text=\(Redact.text(text), privacy: .public) \
                barcodes=\(barcodes.count, privacy: .public)
                """)
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            let (rowid, existing) = try rowLocked(id: id)
            try reindex(rowid: rowid,
                        oldBody: indexBody(text: existing.ocrText,
                                           barcodes: existing.barcodePayloads),
                        text: nil,
                        barcodes: [])
            let stmt = try prepare("DELETE FROM shots WHERE id = ?;", what: "delete shot")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, rowid)
            try step(stmt, what: "delete shot")

            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(existing.blobFilename))
            try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(existing.thumbFilename))
            Log.library.info("deleted 1 shot")
        }
    }

    func deleteAll() throws {
        try queue.sync {
            try exec("DELETE FROM shots;", what: "delete all shots")
            // A contentless FTS5 table has no `DELETE FROM`. This special
            // insert is the documented way to empty one.
            try exec("INSERT INTO ocr(ocr) VALUES('delete-all');", what: "delete all ocr")

            let fm = FileManager.default
            var removed = 0
            for dir in [blobsDir, thumbsDir] {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for f in files where f.pathExtension == "snapr" {
                    try? fm.removeItem(at: f)
                    removed += 1
                }
            }
            Log.library.info("deleted whole library, \(removed, privacy: .public) sealed files removed")
        }
    }

    // MARK: - Reading

    func shot(id: UUID) throws -> Shot {
        try queue.sync {
            try rowLocked(id: id).shot
        }
    }

    func recent(limit: Int, offset: Int) throws -> [Shot] {
        try queue.sync {
            let sql = """
                SELECT \(Library.columns) FROM shots
                ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?;
                """
            let stmt = try prepare(sql, what: "recent")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))
            sqlite3_bind_int64(stmt, 2, Int64(max(0, offset)))
            return try collect(stmt, what: "recent").map { $0.shot }
        }
    }

    /// Full-text search over OCR text and barcode payloads.
    ///
    /// The raw string is routed through `SearchQuery.sanitize` and never
    /// reaches `MATCH` directly. MEASURED (probe A13.6): **23 of 29 realistic
    /// inputs make FTS5 throw**, including a single apostrophe. Every query is
    /// already a bound parameter, so SQL injection was never the risk. FTS5
    /// expression parsing is.
    ///
    /// `.skip` returns an empty array without running a query, because an empty
    /// token list must mean "do not search", never "search for nothing".
    func search(_ rawQuery: String, limit: Int) throws -> [Shot] {
        guard case .match(let expression) = SearchQuery.sanitize(rawQuery) else {
            return []
        }
        return try queue.sync {
            let sql = """
                SELECT \(Library.prefixedColumns) FROM ocr
                JOIN shots s ON s.id = ocr.rowid
                WHERE ocr MATCH ? ORDER BY rank LIMIT ?;
                """
            let stmt = try prepare(sql, what: "search")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, expression)
            sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
            let rows = try collect(stmt, what: "search").map { $0.shot }
            Log.library.info("search returned \(rows.count, privacy: .public) rows")
            return rows
        }
    }

    /// Everything OCR has not finished with, oldest first.
    ///
    /// `.running` is included on purpose. A crash in the middle of a Vision
    /// pass leaves a row in `.running` forever otherwise, and the shot would
    /// never become searchable.
    func pendingOCR(limit: Int) throws -> [UUID] {
        try queue.sync {
            let sql = """
                SELECT uuid FROM shots
                WHERE ocr_state IN ('pending', 'running')
                ORDER BY created_at ASC LIMIT ?;
                """
            let stmt = try prepare(sql, what: "pending ocr")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))
            var out: [UUID] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0),
                       let id = UUID(uuidString: String(cString: c)) {
                        out.append(id)
                    }
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw LibraryError.sqlite("pending ocr", rc)
                }
            }
            return out
        }
    }

    /// Counts for the honest empty-search message.
    ///
    /// `pending` folds `.running` in with `.pending`: from the user's point of
    /// view both mean "not searchable yet", and
    /// `SearchQuery.emptyResultExplanation` takes one number.
    func counts() throws -> (total: Int, pending: Int, failed: Int) {
        try queue.sync {
            let sql = """
                SELECT
                  count(*),
                  sum(CASE WHEN ocr_state IN ('pending','running') THEN 1 ELSE 0 END),
                  sum(CASE WHEN ocr_state = 'failed' THEN 1 ELSE 0 END)
                FROM shots;
                """
            let stmt = try prepare(sql, what: "counts")
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else {
                if rc == SQLITE_DONE { return (0, 0, 0) }
                throw LibraryError.sqlite("counts", rc)
            }
            return (Int(sqlite3_column_int64(stmt, 0)),
                    Int(sqlite3_column_int64(stmt, 1)),
                    Int(sqlite3_column_int64(stmt, 2)))
        }
    }

    /// Bytes the library occupies: the database and its sidecars, plus every
    /// sealed blob and thumbnail. For the "manage storage" screen.
    func diskBytes() throws -> Int {
        queue.sync {
            let fm = FileManager.default
            var total = 0
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let p = directory.appendingPathComponent("index.db" + suffix).path
                if let a = try? fm.attributesOfItem(atPath: p), let s = a[.size] as? Int {
                    total += s
                }
            }
            for dir in [blobsDir, thumbsDir] {
                let files = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for f in files {
                    if let v = try? f.resourceValues(forKeys: [.fileSizeKey]),
                       let s = v.fileSize { total += s }
                }
            }
            return total
        }
    }

    func fullPNG(id: UUID) throws -> Data {
        try queue.sync {
            try readSealed(at: blobsDir.appendingPathComponent("\(id.uuidString).snapr"), id: id)
        }
    }

    /// MEASURED (probe A12): decoding the full original per grid tile costs 31
    /// to 35 ms, reading this stored thumbnail costs about 1 ms. A **32x to
    /// 37x** difference, so the thumbnail is rendered once at insert time and
    /// never derived on the fly.
    func thumbnailPNG(id: UUID) throws -> Data {
        try queue.sync {
            try readSealed(at: thumbsDir.appendingPathComponent("\(id.uuidString).snapr"), id: id)
        }
    }

    // MARK: - Private helpers (all called on `queue`)

    private static let columns =
        "id, uuid, created_at, kind, width, height, blob_bytes, ocr_state, ocr_text, barcodes, source_app, is_favourite"
    private static let prefixedColumns =
        "s.id, s.uuid, s.created_at, s.kind, s.width, s.height, s.blob_bytes, s.ocr_state, s.ocr_text, s.barcodes, s.source_app, s.is_favourite"

    private func readSealed(at url: URL, id: UUID) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.blobMissing(id)
        }
        guard let sealed = try? Data(contentsOf: url) else {
            throw LibraryError.blobMissing(id)
        }
        do {
            return try BlobCrypto.open(sealed, key: key)
        } catch {
            // AES-GCM turned silent corruption into a catchable failure. That
            // is the entire reason the image bytes are not in the database.
            Log.library.error("sealed blob failed to authenticate, \(Redact.bytes(sealed.count), privacy: .public) on disk")
            throw LibraryError.decryptFailed(id)
        }
    }

    private func rowLocked(id: UUID) throws -> (rowid: Int64, shot: Shot) {
        let sql = "SELECT \(Library.columns) FROM shots WHERE uuid = ? LIMIT 1;"
        let stmt = try prepare(sql, what: "shot by id")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        let rows = try collect(stmt, what: "shot by id")
        guard let first = rows.first else { throw LibraryError.notFound(id) }
        return first
    }

    private func collect(_ stmt: OpaquePointer, what: String) throws -> [(rowid: Int64, shot: Shot)] {
        var out: [(rowid: Int64, shot: Shot)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(readRow(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw LibraryError.sqlite(what, rc)
            }
        }
        return out
    }

    private func readRow(_ stmt: OpaquePointer) -> (rowid: Int64, shot: Shot) {
        let rowid = sqlite3_column_int64(stmt, 0)
        let uuid = UUID(uuidString: text(stmt, 1) ?? "") ?? UUID()
        let kind = CaptureKind(rawValue: text(stmt, 3) ?? "") ?? .area
        let state = OCRState(rawValue: text(stmt, 7) ?? "") ?? .pending
        let shot = Shot(
            id: uuid,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            kind: kind,
            size: PixelSize(width: Int(sqlite3_column_int64(stmt, 4)),
                            height: Int(sqlite3_column_int64(stmt, 5))),
            blobBytes: Int(sqlite3_column_int64(stmt, 6)),
            ocrState: state,
            ocrText: text(stmt, 8),
            barcodePayloads: decodeBarcodes(text(stmt, 9)),
            sourceApp: text(stmt, 10),
            isFavourite: sqlite3_column_int64(stmt, 11) != 0)
        return (rowid, shot)
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// What actually goes into the FTS5 index.
    ///
    /// Barcode payloads are indexed alongside the text. MEASURED (probe A10):
    /// barcode detection costs +4.2 ms on a 200 ms pass, so "there is a QR code
    /// in this screenshot" becomes a searchable fact for 2% of work that is
    /// already happening.
    private func indexBody(text: String?, barcodes: [String]) -> String? {
        var parts: [String] = []
        if let text, !text.isEmpty { parts.append(text) }
        parts.append(contentsOf: barcodes)
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Replaces one row in the contentless FTS5 index.
    ///
    /// A contentless table cannot look up its own old text, so the delete
    /// command has to be handed the exact body that was indexed. That body is
    /// rebuilt from `shots.ocr_text`, which is the copy of record.
    private func reindex(rowid: Int64, oldBody: String?, text: String?, barcodes: [String]) throws {
        if let oldBody {
            let stmt = try prepare("INSERT INTO ocr(ocr, rowid, body) VALUES('delete', ?, ?);",
                                   what: "fts delete")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, rowid)
            bindText(stmt, 2, oldBody)
            try step(stmt, what: "fts delete")
        }
        guard let body = indexBody(text: text, barcodes: barcodes) else { return }
        let stmt = try prepare("INSERT INTO ocr(rowid, body) VALUES(?, ?);", what: "fts insert")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        bindText(stmt, 2, body)
        try step(stmt, what: "fts insert")
    }

    private func encodeBarcodes(_ payloads: [String]) -> String {
        guard !payloads.isEmpty,
              let data = try? JSONEncoder().encode(payloads),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func decodeBarcodes(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    // MARK: - Thin sqlite wrappers

    /// A closed library must say so, not hand a nil pointer to the C API.
    /// The background OCR worker can still be mid-shot when the app closes the
    /// library at quit, and "closed" is a clear answer where SQLITE_MISUSE is
    /// not.
    private func liveHandle(_ what: String) throws -> OpaquePointer {
        guard let handle else { throw LibraryError.openFailed("library is closed (\(what))") }
        return handle
    }

    private func exec(_ sql: String, what: String) throws {
        let rc = sqlite3_exec(try liveHandle(what), sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw LibraryError.sqlite(what, rc) }
    }

    private func prepare(_ sql: String, what: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try liveHandle(what), sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if stmt != nil { sqlite3_finalize(stmt) }
            throw LibraryError.sqlite(what, rc)
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer, what: String) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw LibraryError.sqlite(what, rc)
        }
    }

    /// Every value the app writes goes through a bound parameter. No SQL is
    /// ever built by concatenating a value into a string.
    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindTextOrNull(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
