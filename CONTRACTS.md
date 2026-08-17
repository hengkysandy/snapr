# Module contracts

Snapr is built by several people at once. These signatures are **fixed**. Do not
change one without saying so, because someone else has already written a call to
it.

Everything already exists and compiles: `SnaprCore` (pure logic, no AppKit),
`SnaprMac/App/Logging.swift`, `SnaprMac/App/ImageBridge.swift`,
`SnaprMac/App/SettingsStore.swift`.

## Rules that apply to every file

1. **Never log user content.** No OCR text, no window titles, no filenames the
   user chose, no clipboard contents. Log kinds, counts, sizes, durations and
   error reasons. Use `Redact.text(_:)` and `Redact.bytes(_:)` from
   `Logging.swift`. A diagnostic that prints what was on the user's screen is a
   data leak with a helpful tone.
2. **`os.Logger`, never `NSLog` or `print`.** `NSLog` redacts its own arguments
   as `<private>` on macOS 26, so every diagnostic is unreadable and looks
   exactly like "nothing happened". Categories are in `Log`.
3. **A failure must be loud.** Never return an empty array where an error
   happened. An empty history looks exactly like data loss. Throw, or return a
   state that says which one it was.
4. **Swift 6 strict concurrency is on.** UI types are `@MainActor`. A Carbon C
   callback needs `@MainActor` plus `MainActor.assumeIsolated`.
5. **No `any` types, no force unwraps outside tests**, and every non-obvious
   line gets a comment saying *why*, not what.
6. Comments explaining a measured decision must keep the number. The measurement
   is the reason the code looks the way it does.

---

## `SnaprCore` — already written, do not modify

```swift
PixelPoint(x:y:) / PixelSize(width:height:) / PixelRect(x0:y0:x1:y1:)
PixelRect.xywh(_:_:_:_:)  .width .height .area .isEmpty .centre .contains(_:)
          .intersection(_:) .union(_:) .clamped(to:) .inset(by:) .offsetBy(dx:dy:) .iou(_:)
Selection(from:to:bounds:) / .move(dx:dy:) / .resize(_:dx:dy:) / .handle(at:slop:)
SelectionHandle: .topLeft .top .topRight .right .bottomRight .bottom .bottomLeft .left .inside

PixelBuffer(width:height:rgba:)   // rgba8, row stride == width*4, top-left origin
   .bounds .contains(_:_:) .colour(x:y:) -> SRGB?   // nil out of bounds
   .lumaAt(x:y:) .darkestColour(around:boxSize:) .modalColour(around:radius:)

SRGB(r:g:b:) .hex .hexLowercase .cssRGB .swiftLiteral .nsColorLiteral .isDark
ColourFormat.string(for:)
Contrast.relativeLuminance(_:) .ratio(_:_:) .grade(_:largeText:) .formatted(_:)

EdgeSnap.snap(in:at:tolerance:maxLevels:) -> EdgeSnap.Result
EdgeSnap.snap(in:roughly:tolerance:maxLevels:) -> EdgeSnap.Result
EdgeSnap.Result: .levels [PixelRect] .rect .accepted .reason .confidence
TextSnap.line(at:lines:) -> PixelRect?
TextSnap.block(containing:lines:maxGap:) -> PixelRect

SearchQuery.sanitize(_:prefixLastToken:) -> .skip | .match(String)
SearchQuery.emptyResultExplanation(pendingOCRCount:failedOCRCount:totalCount:) -> String

Shot(id:createdAt:kind:size:blobBytes:ocrState:ocrText:barcodePayloads:sourceApp:isFavourite:)
   .blobFilename .thumbFilename
OCRState: .pending .running .done .failed .noTextFound   (.isTerminal, .label)
CaptureKind: .area .fullScreen .window .delayed .repeatArea
SaveName.suggested(for:at:)

Annotation(id:kind:from:to:colour:lineWidth:text:counterValue:fontSize:)
Annotation.Kind: .arrow .box .text .counter .blur .highlight  (.label, .shortcut)
   .boundingBox .hitTest(_:slop:) .translate(dx:dy:)
AnnotationStack: .annotations .canUndo .canRedo .nextCounterValue
   .add(_:) .remove(id:) .update(_:) .updateInteractive(_:) .beginInteractive()
   .clear() .undo() .redo() .hitTest(_:slop:)

HotkeySpec(keyCode:modifiers:) .displayString
   .cmdKey .shiftKey .optionKey .controlKey   HotkeySpec.Key.one/two/.../h/r/w
HotkeyAction: .captureArea .captureFullScreen .captureWindow .captureDelayed
              .repeatLastArea .openHistory   (.label, .defaultSpec)

Settings() .afterCapture .playShutterSound .showCursorInCapture .copyOnClose
   .colourFormat .hotkeys .launchAtLogin .keepHistory .historyRetentionDays
   .enableOCR .defaultAnnotationColour .defaultLineWidth .blurBlockSize .conflicts
Settings.AfterCapture: .openEditor .copyToClipboard .saveToDownloads

SnaprVersion.marketing / .build / .displayString
```

## `SnaprMac/App` — already written, do not modify

```swift
Log.app / .capture / .overlay / .library / .ocr / .editor / .hotkey     // os.Logger
Redact.text(_:) -> "<n chars>"   Redact.bytes(_:)   Redact.ms(_:)

ImageBridge.pixelBuffer(from: CGImage) -> PixelBuffer?
ImageBridge.pngData(from: CGImage) -> Data?
ImageBridge.image(from: Data) -> CGImage?
ImageBridge.thumbnail(from: CGImage, maxEdge: Int = 320) -> CGImage?
ImageBridge.nsImage(from: CGImage) -> NSImage
ImageBridge.crop(_: CGImage, to: PixelRect) -> CGImage?

@MainActor SettingsStore.shared.settings          // Settings
@MainActor SettingsStore.shared.update { $0.x = y }
@MainActor SettingsStore.shared.observe { settings in ... } -> UUID

Paths.support / .indexDB / .blobs / .thumbs / .createIfNeeded()
```

---

## Contract 1 — Storage and OCR (`SnaprMac/Storage`, `SnaprMac/OCR`)

```swift
// KeyStore.swift
enum KeyStore {
    static let service = "com.hengkysandy.snapr.dbkey"
    /// 256-bit key, generated on first launch. Throws on any Keychain failure.
    /// It must NEVER silently generate a fresh key when one exists but cannot
    /// be read: that makes the whole library permanently unreadable.
    static func loadOrCreateKey() throws -> SymmetricKey
    static func deleteKey() throws            // used only by tests
}

// BlobCrypto.swift
enum BlobCrypto {
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data
    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data
}

// Library.swift
enum LibraryError: Error {
    case openFailed(String), sqlite(String, Int32), notFound(UUID)
    case blobMissing(UUID), decryptFailed(UUID), wrongKey
}

final class Library: @unchecked Sendable {
    init(directory: URL, key: SymmetricKey) throws
    func close()

    func insert(_ shot: Shot, png: Data, thumbnailPNG: Data) throws -> Shot
    func update(_ shot: Shot) throws
    func delete(id: UUID) throws
    func deleteAll() throws

    func setOCR(id: UUID, state: OCRState, text: String?, barcodes: [String]) throws
    func shot(id: UUID) throws -> Shot
    func recent(limit: Int, offset: Int) throws -> [Shot]
    func search(_ rawQuery: String, limit: Int) throws -> [Shot]
    func pendingOCR(limit: Int) throws -> [UUID]
    func counts() throws -> (total: Int, pending: Int, failed: Int)
    func diskBytes() throws -> Int

    func fullPNG(id: UUID) throws -> Data
    func thumbnailPNG(id: UUID) throws -> Data
}

// OCRService.swift
@MainActor
final class OCRService {
    init(library: Library)
    /// Starts the background worker. Picks up anything already `.pending`.
    func start()
    func stop()
    func enqueue(_ id: UUID)
    /// Called on the main actor after each shot finishes, for UI refresh.
    var onFinished: ((UUID, OCRState) -> Void)?
}
```

## Contract 2 — Capture and overlay (`SnaprMac/Capture`, `SnaprMac/Overlay`)

```swift
// CaptureEngine.swift
struct WindowInfo: Sendable, Identifiable {
    var id: CGWindowID
    var titleLength: Int          // NEVER the title itself, it is user content
    var appName: String
    var frame: PixelRect          // in global backing pixels, top-left origin
    var isOnScreen: Bool
}

enum CaptureError: Error {
    case noPermission           // detected from SCStreamErrorDomain -3801
    case noDisplay
    case failed(String)
    case blankFrame(String)     // secondary signal only, see design 4.4
}

@MainActor
final class CaptureEngine {
    init()
    /// One throwaway capture at launch. MEASURED: the cold first call is 49 ms
    /// against a 13.4 ms median, so warming once is worth it and a pre-warmed
    /// SCStream is not.
    func warmUp() async
    func hasPermission() -> Bool               // CGPreflightScreenCaptureAccess
    func requestPermission()                   // CGRequestScreenCaptureAccess
    func openScreenRecordingSettings()
    func captureFullScreen(_ screen: NSScreen) async throws -> CGImage
    func listWindows() async throws -> [WindowInfo]
    func captureWindow(id: CGWindowID) async throws -> CGImage
    func frontmostWindow() async throws -> WindowInfo?
}

// HotkeyManager.swift
@MainActor
final class HotkeyManager {
    init(onAction: @escaping (HotkeyAction) -> Void)
    /// Returns the OSStatus per action. `-9878` means the combination is taken
    /// by something else; report it, never swallow it.
    @discardableResult
    func register(_ hotkeys: [HotkeyAction: HotkeySpec]) -> [HotkeyAction: OSStatus]
    func unregisterAll()
}

// OverlayController.swift
enum OverlayOutcome: Sendable {
    case cancelled
    case region(PixelRect)      // in the frozen image's pixel coordinates
}

@MainActor
final class OverlayController {
    init()
    var onFinish: ((OverlayOutcome) -> Void)?
    /// `frozen` is the already-captured still. Capture-first, per design 4.3.
    func begin(frozen: CGImage, buffer: PixelBuffer, screen: NSScreen, settings: Settings)
    func cancel()
}
```

## Contract 3 — Editor (`SnaprMac/Editor`)

```swift
enum EditorResult: Sendable {
    case copied, saved(URL), closed, discarded
}

@MainActor
final class EditorWindowController: NSWindowController {
    /// `shotID` is nil when editing something that is not in the library.
    init(image: CGImage, shotID: UUID?, settings: Settings)
    var onResult: ((EditorResult) -> Void)?
    /// The flattened image with annotations drawn in. Used for copy and save.
    func renderFlattened() -> CGImage?
    func show()
}
```

## Contract 4 — History and settings UI (`SnaprMac/History`, `SnaprMac/Settings`)

```swift
@MainActor
final class HistoryWindowController: NSWindowController {
    init(library: Library)
    var onOpen: ((UUID) -> Void)?          // user double-clicked a shot
    func show()
    func refresh()
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: SettingsStore, capture: CaptureEngine)
    var onHotkeysChanged: (() -> Void)?
    func show()
}
```

## Owned by the integrator, do not write these

`SnaprMac/App/main.swift`, `AppDelegate.swift`, `StatusItemController.swift`,
`Tests/SnaprCoreTests/*`.
