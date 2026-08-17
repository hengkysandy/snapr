import AppKit
import SnaprCore
import UniformTypeIdentifiers

/// How the editor ended. Reported once, through `onResult`.
enum EditorResult: Sendable {
    case copied
    case saved(URL)
    case closed
    case discarded
}

/// The window the user sees after a capture.
///
/// It owns the window, the toolbar and everything that touches the file system
/// or the pasteboard. The canvas owns the image and the annotations. That split
/// is what keeps the coordinate maths in one file and the AppKit plumbing in
/// this one.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    var onResult: ((EditorResult) -> Void)?

    private let canvas: EditorCanvasView
    private let toolbar: EditorToolbar
    private let scrollView = NSScrollView()
    private let shotID: UUID?
    private let settings: Settings
    private let openedAt = Date()

    /// `shotID` is nil when editing something that is not in the library.
    init(image: CGImage, shotID: UUID?, settings: Settings) {
        self.shotID = shotID
        self.settings = settings
        self.canvas = EditorCanvasView(image: image, settings: settings)
        self.toolbar = EditorToolbar(colour: settings.defaultAnnotationColour,
                                     lineWidth: settings.defaultLineWidth)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed

        super.init(window: window)

        window.delegate = self
        buildContentView()
        wireToolbar()
        wireCanvas()

        canvas.dragFilename = suggestedFilename()
        updateTitle(PixelSize(width: image.width, height: image.height))
        Log.editor.info("editor opened, \(image.width, privacy: .public)x\(image.height, privacy: .public), in library: \(shotID != nil, privacy: .public)")
    }

    required init?(coder: NSCoder) {
        fatalError("EditorWindowController is built in code, never from a nib")
    }

    // MARK: - Contract surface

    /// The flattened image with annotations drawn in, at full pixel resolution.
    func renderFlattened() -> CGImage? {
        canvas.commitTextEditing()
        return canvas.flattened()
    }

    func show() {
        guard let window else { return }
        window.center()
        // The app is a menu bar item, so the window has to ask for focus or it
        // opens behind whatever the user was looking at.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        canvas.updateFrameForZoom()
        canvas.zoomToFit()
        toolbar.setZoom(canvas.zoom)
    }

    // MARK: - Layout

    private func buildContentView() {
        guard let window else { return }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = canvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(toolbar)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        window.contentView = content
    }

    private func wireToolbar() {
        toolbar.onToolChanged = { [weak self] tool in
            self?.canvas.tool = tool
        }
        toolbar.onColourChanged = { [weak self] colour in
            self?.canvas.colour = colour
        }
        toolbar.onLineWidthChanged = { [weak self] width in
            self?.canvas.lineWidth = width
        }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        toolbar.onRedo = { [weak self] in self?.canvas.redo() }
        toolbar.onCopy = { [weak self] in self?.copyToPasteboard() }
        toolbar.onSave = { [weak self] in self?.saveAsPNG() }
        toolbar.onZoomIn = { [weak self] in self?.canvas.zoomIn() }
        toolbar.onZoomOut = { [weak self] in self?.canvas.zoomOut() }
        toolbar.onZoomFit = { [weak self] in self?.canvas.zoomToFit() }
    }

    private func wireCanvas() {
        canvas.onZoomChanged = { [weak self] zoom in
            self?.toolbar.setZoom(zoom)
        }
        canvas.onToolChanged = { [weak self] tool in
            self?.toolbar.setTool(tool)
        }
        canvas.onImageChanged = { [weak self] size in
            self?.updateTitle(size)
        }
        canvas.onUndoStateChanged = { [weak self] in
            guard let self else { return }
            self.toolbar.setUndoState(canUndo: self.canvas.canUndo,
                                      canRedo: self.canvas.canRedo)
        }
        // Cmd+C, Cmd+S and Cmd+W reach the canvas first as key equivalents. The
        // canvas handles the ones it owns and hands these three back up.
        canvas.onCommand = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .copy: self.copyToPasteboard(); return true
            case .save: self.saveAsPNG(); return true
            case .close: self.closeEditor(); return true
            }
        }
    }

    private func updateTitle(_ size: PixelSize) {
        // The pixel size in the title, because a screenshot's size is the first
        // thing anyone wants to know about it.
        window?.title = "Snapr  \(size.width) x \(size.height)"
    }

    // MARK: - Output

    private func copyToPasteboard() {
        guard let flat = renderFlattened(), let png = ImageBridge.pngData(from: flat) else {
            Log.editor.error("copy failed, flatten produced no PNG")
            NSSound.beep()
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        // PNG is what modern apps read. TIFF is written as well because some
        // older apps only ever ask for that, and pasting nothing into them
        // looks exactly like a broken copy.
        if let tiff = NSBitmapImageRep(cgImage: flat).representation(using: .tiff,
                                                                    properties: [:]) {
            board.setData(tiff, forType: .tiff)
        }
        Log.editor.info("copied to pasteboard, \(Redact.bytes(png.count), privacy: .public)")
        onResult?(.copied)
    }

    private func saveAsPNG() {
        guard let window else { return }
        guard let flat = renderFlattened(), let png = ImageBridge.pngData(from: flat) else {
            Log.editor.error("save failed, flatten produced no PNG")
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        // Design 6.4: the library is encrypted, but an explicit save writes an
        // ordinary PNG, because a file the user asked for is not the library.
        panel.nameFieldStringValue = suggestedFilename()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                // The path is the user's own choice, so only the size is logged.
                Log.editor.info("saved PNG, \(Redact.bytes(png.count), privacy: .public)")
                self?.onResult?(.saved(url))
            } catch {
                // A file system error message contains the path, which is user
                // content. Only the domain and code go into the log.
                let ns = error as NSError
                Log.editor.error("save failed, \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private func suggestedFilename() -> String {
        // `SaveName` takes a `Shot` because that is where the timestamp lives.
        // A shot that is not in the library still has a creation time, so a
        // throwaway value gives exactly the same filename rule everywhere.
        let shot = Shot(id: shotID ?? UUID(),
                        createdAt: openedAt,
                        kind: .area,
                        size: PixelSize(width: canvas.image.width,
                                        height: canvas.image.height))
        return SaveName.suggested(for: shot)
    }

    private func closeEditor() {
        if settings.copyOnClose {
            copyToPasteboard()
        }
        window?.performClose(nil)
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextEditing()
        Log.editor.info("editor closed, \(self.canvas.annotations.count, privacy: .public) annotations")
        onResult?(.closed)
        return true
    }

    func windowDidResize(_ notification: Notification) {
        // The canvas centres the image inside its own frame, so the frame has to
        // follow the clip view or the image drifts off centre on resize.
        canvas.updateFrameForZoom()
    }
}
