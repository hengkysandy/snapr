import Foundation

/// How far OCR has got on one capture.
///
/// This enum is the reason the search field can be honest. MEASURED (probe A8):
/// `.accurate` recognition on a full 2940x1912 capture is **206 ms median**,
/// 174 MB peak resident, so OCR cannot run inline with the capture. It runs as
/// a background job.
///
/// Without a state column, a search returning nothing is indistinguishable from
/// a library that has not been indexed yet. That is the exact bug the previous
/// app shipped: it scanned only the newest 500 rows in memory, so an old row
/// simply did not exist as far as search was concerned, and the UI said
/// "no results" with total confidence.
public enum OCRState: String, Sendable, Codable, CaseIterable {
    case pending
    case running
    case done
    case failed
    /// Ran successfully and there was genuinely no text. Distinct from `failed`
    /// on purpose: one is a blank screenshot, the other is a bug to look at.
    case noTextFound

    public var isTerminal: Bool {
        self == .done || self == .failed || self == .noTextFound
    }

    public var label: String {
        switch self {
        case .pending: return "Waiting to read text"
        case .running: return "Reading text"
        case .done: return "Text read"
        case .failed: return "Could not read text"
        case .noTextFound: return "No text found"
        }
    }
}

public enum CaptureKind: String, Sendable, Codable, CaseIterable {
    case area
    case fullScreen
    case window
    case delayed
    case repeatArea

    public var label: String {
        switch self {
        case .area: return "Area"
        case .fullScreen: return "Full screen"
        case .window: return "Window"
        case .delayed: return "Delayed"
        case .repeatArea: return "Repeat area"
        }
    }
}

/// One row of the library. Metadata only. The image bytes live in an AES-GCM
/// sealed file beside the database, never in it.
///
/// MEASURED (probe A12), 200 screenshots: a blob inside SQLCipher inserted at
/// 6.12 ms median against 0.81 ms for a sealed file plus an index row. But
/// speed is not what decided it. Corruption did: a single flipped bit inside a
/// database page **read back 1,600,000 bytes with no error at all**, while the
/// AES-GCM file threw on all four corruption cases. A library that silently
/// hands back garbage is exactly the failure this app exists to avoid.
public struct Shot: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var createdAt: Date
    public var kind: CaptureKind
    /// Pixel size of the stored image.
    public var size: PixelSize
    /// Size of the sealed blob on disk, for the "manage storage" screen.
    public var blobBytes: Int
    public var ocrState: OCRState
    /// Present only when `ocrState == .done`. Never logged.
    public var ocrText: String?
    /// Payloads of any barcodes found in the same Vision pass.
    ///
    /// MEASURED (probe A10): adding barcode detection to the existing handler
    /// costs **+4.2 ms, 2.2%**, on a pass that already takes 200 ms. A fixture
    /// containing a deliberate black-and-white noise block returned nothing, so
    /// the detector does not hallucinate. Always on.
    public var barcodePayloads: [String]
    /// Application that owned the captured window, when known.
    public var sourceApp: String?
    public var isFavourite: Bool

    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                kind: CaptureKind,
                size: PixelSize,
                blobBytes: Int = 0,
                ocrState: OCRState = .pending,
                ocrText: String? = nil,
                barcodePayloads: [String] = [],
                sourceApp: String? = nil,
                isFavourite: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.size = size
        self.blobBytes = blobBytes
        self.ocrState = ocrState
        self.ocrText = ocrText
        self.barcodePayloads = barcodePayloads
        self.sourceApp = sourceApp
        self.isFavourite = isFavourite
    }

    /// Filenames for the two sealed files. UUID only, never derived from the
    /// content: a filename built from OCR text would leak the screenshot's
    /// contents to anything that can list the directory, which defeats the
    /// encryption entirely.
    public var blobFilename: String { "\(id.uuidString).snapr" }
    public var thumbFilename: String { "\(id.uuidString).snapr" }
}

/// Filename template for explicit saves.
///
/// The library is encrypted. `Cmd+S` writes an ordinary PNG, because a file the
/// user asked for is not the library.
public enum SaveName {
    public static func suggested(for shot: Shot, at date: Date? = nil) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Snapr \(f.string(from: date ?? shot.createdAt)).png"
    }
}
