import AppKit
import SnaprCore
import UniformTypeIdentifiers

/// The image, the annotations on it, and every gesture that changes them.
///
/// The view owns the `AnnotationStack`. The window controller owns the window,
/// the toolbar and the file system. Keeping the model here means the drag
/// machine and the coordinate conversion sit next to each other, which is where
/// the bugs would otherwise be.
@MainActor
final class EditorCanvasView: NSView, NSTextViewDelegate, NSDraggingSource {

    // MARK: - State

    private(set) var image: CGImage
    private var stack = AnnotationStack()

    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            commitTextEditing()
            if case .crop = tool {} else { cropRect = nil }
            onToolChanged?(tool)
            needsDisplay = true
        }
    }

    var colour: SRGB
    var lineWidth: Int
    var blockSize: Int

    private(set) var zoom: CGFloat = 1
    private(set) var selectedID: UUID?
    private(set) var cropRect: PixelRect?

    /// The command shortcuts the canvas cannot answer on its own, because they
    /// touch the pasteboard, the file system or the window.
    enum Command: Sendable { case copy, save, close }

    var onZoomChanged: ((CGFloat) -> Void)?
    var onToolChanged: ((EditorTool) -> Void)?
    var onImageChanged: ((PixelSize) -> Void)?
    var onUndoStateChanged: (() -> Void)?
    /// Returns true when the command was handled.
    var onCommand: ((Command) -> Bool)?
    /// Filename used for a drag out of the window. Set by the controller so the
    /// naming rule lives in one place.
    var dragFilename: String = "Snapr.png"

    /// Annotations, read only. Everything that changes them goes through this
    /// view so the undo stack cannot be bypassed.
    var annotations: [Annotation] { stack.annotations }
    var canUndo: Bool { stack.canUndo }
    var canRedo: Bool { stack.canRedo }

    private var imageBounds: PixelRect {
        PixelRect.xywh(0, 0, image.width, image.height)
    }

    // MARK: - Drag machine

    private enum DragState {
        case none
        /// Mouse is down with a drag tool, but nothing exists yet. The
        /// annotation is only created once the mouse actually moves, so a plain
        /// click adds nothing and leaves no undo or redo step behind.
        case creatingPending(Annotation.Kind, PixelPoint)
        /// A new annotation is being dragged out. The anchor is the mouse-down
        /// pixel, which stays fixed while the other corner follows the mouse.
        case creating(UUID, PixelPoint)
        /// An existing annotation is being moved. The pixel is the last one
        /// seen, so each step is a small delta rather than an absolute jump.
        case moving(UUID, PixelPoint)
        case cropping(PixelPoint)
        /// Mouse is down on empty image with no tool. If it moves far enough
        /// this becomes a drag of the flattened image out of the window.
        case maybeDragOut(CGPoint)
    }

    private var drag: DragState = .none
    /// `beginInteractive` must be called exactly once per drag, and only when
    /// the drag actually changes something, so a plain click does not leave an
    /// empty undo step behind.
    private var interactiveStarted = false

    private var textView: NSTextView?
    private var editingID: UUID?
    /// `NSFilePromiseProvider` holds its delegate weakly, so the drag would
    /// produce an empty file if nothing else kept this alive.
    ///
    /// It is deliberately NOT released when the drag session ends. The receiver
    /// fulfils the promise on its own schedule, which can be after the session
    /// has finished, and a released delegate at that moment writes a zero-byte
    /// file. One PNG stays in memory until the next drag replaces it, which is
    /// small next to the image the window already holds.
    private var dragProviderDelegate: FilePromiseDelegate?

    // MARK: - Init

    init(image: CGImage, settings: Settings) {
        self.image = image
        self.colour = settings.defaultAnnotationColour
        self.lineWidth = settings.defaultLineWidth
        self.blockSize = settings.blurBlockSize
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("EditorCanvasView is built in code, never from a nib")
    }

    // MARK: - Coordinates
    //
    // `Annotation` stores `PixelPoint` in the image's own pixel space: origin at
    // the top left, y growing downwards. `NSView` is bottom-up in points, and
    // the image is scaled by `zoom` and centred when it is smaller than the
    // view. These two functions are the ONLY place that arithmetic happens.
    // Every hit test, every drag and every piece of chrome routes through them,
    // because a second copy of this maths is how an off-by-one appears in one
    // gesture and not the others.

    /// Where the image sits on screen, in view points.
    var imageRect: CGRect {
        let w = CGFloat(image.width) * zoom
        let h = CGFloat(image.height) * zoom
        // Whole points, so the image is not resampled across a half pixel.
        let x = max(0, ((bounds.width - w) / 2).rounded(.down))
        let y = max(0, ((bounds.height - h) / 2).rounded(.down))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// View point (bottom-up points) to image pixel (top-left origin pixels).
    func imagePixel(from p: CGPoint) -> PixelPoint {
        let r = imageRect
        let px = (p.x - r.minX) / zoom
        // The y flip: a view point measures up from the bottom, an image pixel
        // measures down from the top edge of the image.
        let py = (r.maxY - p.y) / zoom
        return PixelPoint(x: Int(px.rounded(.down)), y: Int(py.rounded(.down)))
    }

    /// Image pixel to view point. Returns the pixel's top-left corner, which is
    /// what makes the round trip through `imagePixel(from:)` exact.
    func viewPoint(from p: PixelPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + CGFloat(p.x) * zoom,
                       y: r.maxY - CGFloat(p.y) * zoom)
    }

    /// A pixel rectangle as a view rectangle. Built from the same pair above.
    private func viewRect(from r: PixelRect) -> CGRect {
        let topLeft = viewPoint(from: PixelPoint(x: r.x0, y: r.y0))
        let bottomRight = viewPoint(from: PixelPoint(x: r.x1, y: r.y1))
        return CGRect(x: topLeft.x, y: bottomRight.y,
                      width: bottomRight.x - topLeft.x,
                      height: topLeft.y - bottomRight.y)
    }

    // MARK: - Drawing

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        let r = imageRect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        // Above 100% the user is looking for individual pixels, so smoothing
        // them together would defeat the reason the zoom exists.
        ctx.interpolationQuality = zoom > 1 ? .none : .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // Flip into the image's top-left pixel space. The renderer then works in
        // exactly the units the annotations are stored in, on screen and in the
        // export alike.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(stack.annotations, base: image, in: ctx, blockSize: blockSize)
        ctx.restoreGState()

        drawSelectionChrome(in: ctx)
        drawCropChrome(in: ctx)
    }

    private func drawSelectionChrome(in ctx: CGContext) {
        guard let id = selectedID, let a = annotation(id) else { return }
        // Drawn in view space so the dashes stay the same size at every zoom.
        let r = viewRect(from: a.boundingBox).insetBy(dx: -3, dy: -3)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func drawCropChrome(in ctx: CGContext) {
        guard tool == .crop, let c = cropRect, !c.isEmpty else { return }
        let r = viewRect(from: c)
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(imageRect)
        outside.addRect(r)
        ctx.addPath(outside)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        // Even-odd leaves the selection at full brightness and dims the rest.
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.stroke(r)
        ctx.restoreGState()
    }

    // MARK: - Zoom

    func setZoom(_ z: CGFloat) {
        let clamped = min(8, max(0.1, z))
        guard clamped != zoom else { return }
        commitTextEditing()
        zoom = clamped
        updateFrameForZoom()
        onZoomChanged?(zoom)
        needsDisplay = true
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Cmd+0. Fits the whole image, and never magnifies past 100%, because a
    /// small capture blown up to fill the window is not what "fit" means here.
    func zoomToFit() {
        guard let clip = enclosingScrollView?.contentView else { setZoom(1); return }
        let sx = clip.bounds.width / CGFloat(image.width)
        let sy = clip.bounds.height / CGFloat(image.height)
        setZoom(min(1, min(sx, sy)))
    }

    /// The document view must be at least as large as the visible area, so the
    /// centring in `imageRect` has room to work, and at least as large as the
    /// zoomed image, so scrolling reaches every part of it.
    func updateFrameForZoom() {
        let clipSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let w = max(clipSize.width, CGFloat(image.width) * zoom)
        let h = max(clipSize.height, CGFloat(image.height) * zoom)
        if frame.size != NSSize(width: w, height: h) {
            setFrameSize(NSSize(width: w, height: h))
        }
        needsDisplay = true
    }

    // MARK: - Undo

    func undo() {
        commitTextEditing()
        stack.undo()
        clearSelectionIfGone()
        finishedChange()
    }

    func redo() {
        commitTextEditing()
        stack.redo()
        clearSelectionIfGone()
        finishedChange()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        let kind = annotation(id)?.kind
        stack.remove(id: id)
        selectedID = nil
        Log.editor.debug("annotation removed, kind \(kind?.rawValue ?? "unknown", privacy: .public)")
        finishedChange()
    }

    private func clearSelectionIfGone() {
        if let id = selectedID, annotation(id) == nil { selectedID = nil }
    }

    private func finishedChange() {
        onUndoStateChanged?()
        needsDisplay = true
    }

    private func annotation(_ id: UUID) -> Annotation? {
        stack.annotations.first { $0.id == id }
    }

    // MARK: - Crop

    /// Apply a crop rectangle, in image pixels.
    ///
    /// Every annotation moves by the crop origin so nothing jumps. The undo
    /// history is rebuilt rather than kept: every snapshot in it holds positions
    /// in the old coordinate system, and replaying one of those onto a cropped
    /// image would put annotations where the user never placed them. So a crop
    /// is a point of no return, and that is stated rather than half-supported.
    func applyCrop(_ rect: PixelRect) {
        let clamped = rect.clamped(to: imageBounds)
        guard !clamped.isEmpty, clamped != imageBounds,
              let cropped = ImageBridge.crop(image, to: clamped) else { return }

        commitTextEditing()

        var rebuilt = AnnotationStack()
        for var a in stack.annotations {
            a.translate(dx: -clamped.x0, dy: -clamped.y0)
            rebuilt.add(a)
        }
        stack = rebuilt
        image = cropped
        cropRect = nil
        selectedID = nil
        tool = .select

        Log.editor.info("cropped to \(clamped.width, privacy: .public)x\(clamped.height, privacy: .public), \(rebuilt.annotations.count, privacy: .public) annotations moved")

        updateFrameForZoom()
        onImageChanged?(PixelSize(width: cropped.width, height: cropped.height))
        finishedChange()
    }

    private func applyPendingCrop() {
        guard tool == .crop, let c = cropRect else { return }
        applyCrop(c)
    }

    // MARK: - Flatten

    /// The base image plus every annotation, at full pixel resolution.
    func flattened() -> CGImage? {
        AnnotationRenderer.flatten(base: image,
                                   annotations: stack.annotations,
                                   blockSize: blockSize)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pixel = imagePixel(from: viewPoint)

        // A click anywhere else ends text editing, which is what people expect
        // from a floating text field.
        if textView != nil { commitTextEditing() }

        beginDrag(at: pixel, viewPoint: viewPoint, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if case .maybeDragOut(let origin) = drag {
            // A few points of slop, so a slightly shaky click does not turn into
            // a drag out of the window.
            if hypot(viewPoint.x - origin.x, viewPoint.y - origin.y) > 4 {
                drag = .none
                beginImageDragOut(with: event)
            }
            return
        }
        continueDrag(to: imagePixel(from: viewPoint))
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(at: imagePixel(from: convert(event.locationInWindow, from: nil)))
    }

    // MARK: - Drag machine, also the seam the tests drive
    //
    // The three functions below take image pixels, not events. That is what
    // lets a 200-step drag be exercised in a unit test with no window server.

    func beginDrag(at pixel: PixelPoint, viewPoint: CGPoint = .zero, clickCount: Int = 1) {
        interactiveStarted = false

        switch tool {
        case .crop:
            cropRect = PixelRect.xywh(pixel.x, pixel.y, 1, 1)
            drag = .cropping(pixel)

        case .annotate(let kind):
            switch kind {
            case .text:
                createText(at: pixel)
                drag = .none
            case .counter:
                createCounter(at: pixel)
                drag = .none
            case .arrow, .box, .blur, .highlight:
                selectedID = nil
                drag = .creatingPending(kind, pixel)
            }

        case .select:
            if let hit = stack.hitTest(pixel) {
                selectedID = hit.id
                if hit.kind == .text && clickCount >= 2 {
                    beginTextEditing(hit)
                    drag = .none
                } else {
                    drag = .moving(hit.id, pixel)
                }
            } else {
                selectedID = nil
                drag = .maybeDragOut(viewPoint)
            }
        }
        finishedChange()
    }

    func continueDrag(to pixel: PixelPoint) {
        switch drag {
        case .creatingPending(let kind, let anchor):
            guard pixel != anchor else { return }
            let a = Annotation(kind: kind, from: anchor, to: pixel,
                               colour: colour, lineWidth: lineWidth)
            // One `add` is one checkpoint. Every step after this is
            // interactive, so the whole drag is a single undo step.
            stack.add(a)
            selectedID = a.id
            drag = .creating(a.id, anchor)

        case .creating(let id, let anchor):
            guard var a = annotation(id) else { return }
            a.from = anchor
            a.to = pixel
            stack.updateInteractive(a)

        case .moving(let id, let last):
            let dx = pixel.x - last.x, dy = pixel.y - last.y
            guard dx != 0 || dy != 0 else { return }
            if !interactiveStarted {
                // Taken here rather than at mouse-down, so selecting something
                // without moving it does not leave an empty undo step.
                stack.beginInteractive()
                interactiveStarted = true
            }
            guard var a = annotation(id) else { return }
            a.translate(dx: dx, dy: dy)
            stack.updateInteractive(a)
            drag = .moving(id, pixel)

        case .cropping(let anchor):
            cropRect = Selection(from: anchor, to: pixel, bounds: imageBounds).rect

        case .maybeDragOut, .none:
            return
        }
        needsDisplay = true
    }

    func endDrag(at pixel: PixelPoint) {
        switch drag {
        case .creatingPending:
            // The mouse never moved, so nothing was ever created. No undo step,
            // no redo step, nothing to clean up.
            break

        case .creating(let id, _):
            if let a = annotation(id),
               a.boundingBox.width <= 2, a.boundingBox.height <= 2 {
                // A drag out and back leaves a shape too small to see. `add`
                // pushed exactly one checkpoint, so undo rolls it back.
                stack.undo()
                selectedID = nil
            } else if let a = annotation(id) {
                Log.editor.debug("annotation added, kind \(a.kind.rawValue, privacy: .public)")
            }

        case .cropping:
            // Nothing is applied yet. The crop needs Enter, because an
            // accidental drag must not destroy pixels.
            break

        case .moving, .maybeDragOut, .none:
            break
        }
        drag = .none
        interactiveStarted = false
        finishedChange()
    }

    private func createCounter(at pixel: PixelPoint) {
        // A counter is placed by a click, so its box is derived from the font
        // size. Storing it as a real box keeps hit testing and moving identical
        // to every other kind.
        let r = max(14, 28)
        let a = Annotation(kind: .counter,
                           from: PixelPoint(x: pixel.x - r, y: pixel.y - r),
                           to: PixelPoint(x: pixel.x + r, y: pixel.y + r),
                           colour: colour, lineWidth: lineWidth)
        stack.add(a)
        selectedID = a.id
        Log.editor.debug("counter added, value \(self.stack.nextCounterValue - 1, privacy: .public)")
    }

    private func createText(at pixel: PixelPoint) {
        let fontSize = 28
        let a = Annotation(kind: .text,
                           from: pixel,
                           to: PixelPoint(x: pixel.x + 240, y: pixel.y + fontSize * 2),
                           colour: colour, lineWidth: lineWidth,
                           fontSize: fontSize)
        stack.add(a)
        selectedID = a.id
        beginTextEditing(a)
    }

    // MARK: - Text editing
    //
    // A real `NSTextView`, not a hand-rolled caret. It is the only way the user
    // gets the system input methods, so Japanese, Chinese, emoji and dictation
    // all work without a line of code here. The string is baked into
    // `Annotation.text` when editing ends.

    private func beginTextEditing(_ a: Annotation) {
        commitTextEditing()

        let box = viewRect(from: a.boundingBox)
        let frame = NSRect(x: box.minX, y: box.minY,
                           width: max(80, box.width),
                           height: max(24, box.height))
        let tv = NSTextView(frame: frame)
        tv.string = a.text
        tv.font = NSFont.systemFont(ofSize: CGFloat(a.fontSize) * zoom, weight: .semibold)
        tv.textColor = AnnotationRenderer.nsColour(a.colour)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = self
        addSubview(tv)
        window?.makeFirstResponder(tv)

        textView = tv
        editingID = a.id
        needsDisplay = true
    }

    /// Bake the edited string into the annotation. Called on Escape, on a click
    /// elsewhere, and before anything that would move the text view out from
    /// under the user.
    func commitTextEditing() {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        let string = tv.string
        tv.removeFromSuperview()

        guard var a = annotation(id) else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stack.remove(id: id)
            if selectedID == id { selectedID = nil }
        } else {
            a.text = string
            // Fit the box to what will actually be drawn, so the selection
            // outline and the hit test agree with what is on screen. The slack
            // stops CoreText dropping the last line on a rounding boundary.
            let measured = AnnotationRenderer.textSize(string,
                                                       fontSize: a.fontSize,
                                                       maxWidth: 640)
            a.to = PixelPoint(x: a.from.x + measured.width + 8,
                              y: a.from.y + measured.height + 6)
            stack.update(a)
        }
        // The string itself is user content and is never logged.
        Log.editor.debug("text annotation committed, \(Redact.text(string), privacy: .public)")
        finishedChange()
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Escape commits rather than cancels, because losing what was typed is
        // worse than keeping it. Return inserts a newline, so a label can be
        // more than one line.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Command combinations are handled in `performKeyEquivalent`.
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 51, 117:                       // Backspace, Forward delete
            deleteSelected()
            return
        case 53:                            // Escape
            cropRect = nil
            selectedID = nil
            finishedChange()
            return
        case 36, 76:                        // Return, Enter
            applyPendingCrop()
            return
        default:
            break
        }

        if let key = event.charactersIgnoringModifiers?.lowercased(),
           let picked = EditorTool.forKey(key) {
            tool = picked
            return
        }
        super.keyDown(with: event)
    }

    /// Command shortcuts, handled here rather than in a menu.
    ///
    /// The app is `LSUIElement`, so it has no menu bar of its own to hang key
    /// equivalents on. A view in the key window still sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)

        // While the text view has focus the standard editing shortcuts must
        // reach it. The app has no menu bar, so nothing else would deliver them.
        if textView != nil {
            switch key {
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            default: break
            }
        }

        switch key {
        case "z":
            if shift { redo() } else { undo() }
            return true
        case "=", "+":
            zoomIn()
            return true
        case "-":
            zoomOut()
            return true
        case "0":
            zoomToFit()
            return true
        case "c":
            return onCommand?(.copy) ?? false
        case "s":
            return onCommand?(.save) ?? false
        case "w":
            return onCommand?(.close) ?? false
        default:
            return false
        }
    }

    // MARK: - Drag out of the window

    /// Drag the flattened image into any other app.
    ///
    /// A file promise rather than raw bytes, because the receiver decides the
    /// destination and Finder needs a real file. The PNG is rendered up front:
    /// a drag that lands and produces nothing is worse than no drag at all.
    private func beginImageDragOut(with event: NSEvent) {
        guard let flat = flattened(), let png = ImageBridge.pngData(from: flat) else {
            Log.editor.error("drag out cancelled, flatten produced no PNG")
            return
        }

        let delegate = FilePromiseDelegate(png: png, filename: dragFilename)
        dragProviderDelegate = delegate
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier,
                                             delegate: delegate)
        let item = NSDraggingItem(pasteboardWriter: provider)

        // A drag with no image under the cursor looks broken, so a thumbnail is
        // attached even though the promise carries the real thing.
        let preview = ImageBridge.thumbnail(from: flat, maxEdge: 192) ?? flat
        let size = NSSize(width: preview.width, height: preview.height)
        let origin = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - size.width / 2,
                                     y: origin.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: ImageBridge.nsImage(from: preview))

        beginDraggingSession(with: [item], event: event, source: self)
        Log.editor.info("drag out started, \(Redact.bytes(png.count), privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Writes the promised PNG when the receiver asks for it.
///
/// Separate from the view because `NSFilePromiseProvider` keeps only a weak
/// reference to its delegate, and because the bytes are already in memory, so
/// nothing here needs the view.
@MainActor
private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let png: Data
    private let filename: String

    init(png: Data, filename: String) {
        self.png = png
        self.filename = filename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        filename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try png.write(to: url)
            Log.editor.info("drag out written, \(Redact.bytes(self.png.count), privacy: .public)")
            completionHandler(nil)
        } catch {
            // The destination path is the user's choice, so only the reason is
            // logged, never the path.
            let ns = error as NSError
            Log.editor.error("drag out failed, \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            completionHandler(error)
        }
    }

    /// The bytes are already rendered, so the write is one call and the main
    /// queue is the simplest correct place for it.
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}
