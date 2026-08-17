import AppKit
import CoreGraphics
import Foundation
import SnaprCore

// MARK: - The one coordinate conversion in the whole overlay

/// The single boundary between AppKit points and `PixelRect` backing pixels.
///
/// This exists as its own testable type because it is the exact place
/// off-by-one selection bugs come from, and because there are three coordinate
/// systems in play at once:
///
/// - `PixelRect` is TOP-LEFT origin, whole backing pixels. The frozen `CGImage`
///   uses the same orientation, so a `PixelRect` indexes the image directly.
/// - `NSView` is BOTTOM-UP, in points. y grows upward.
/// - `NSScreen.frame` is global Cocoa points, bottom-left origin, and a
///   secondary display can sit at a non-zero or negative origin.
///
/// The overlay window is placed exactly on `screenFrame`, so a view point and a
/// global point differ only by that origin. Every conversion happens here and
/// nowhere else.
struct OverlayGeometry: Equatable, Sendable {
    /// Global Cocoa points, bottom-left origin.
    let screenFrame: CGRect
    /// `NSScreen.backingScaleFactor`. 1.0 or 2.0 on real hardware.
    let scale: CGFloat

    init(screenFrame: CGRect, scale: CGFloat) {
        self.screenFrame = screenFrame
        // A zero or negative scale would divide by zero further down and turn
        // every coordinate into NaN, which reads as "the selection does not
        // work" rather than as a bad input.
        self.scale = scale > 0 ? scale : 1
    }

    var pixelWidth: Int { Int((screenFrame.width * scale).rounded()) }
    var pixelHeight: Int { Int((screenFrame.height * scale).rounded()) }
    var pixelBounds: PixelRect { PixelRect.xywh(0, 0, pixelWidth, pixelHeight) }
    /// The view is the same size as the screen, in points.
    var viewSize: CGSize { screenFrame.size }

    // MARK: points -> pixels

    /// A point in the overlay view's own coordinates, bottom-left origin.
    ///
    /// `floor` and not `round`: a point anywhere inside pixel column 7 must
    /// name pixel 7. Rounding would make the right half of column 7 name
    /// column 8, so the loupe would show a different pixel than the cursor sits
    /// on, and only at half the positions.
    func pixel(fromViewPoint p: CGPoint) -> PixelPoint {
        let x = Int(floor(p.x * scale))
        // The y flip. This is the whole reason this type exists.
        let y = Int(floor((screenFrame.height - p.y) * scale))
        return PixelPoint(x: clamp(x, 0, pixelWidth - 1),
                          y: clamp(y, 0, pixelHeight - 1))
    }

    /// A point in global Cocoa coordinates, which is what `NSEvent` gives for
    /// a screen-wide drag and what a second display makes interesting.
    func pixel(fromGlobalPoint p: CGPoint) -> PixelPoint {
        pixel(fromViewPoint: CGPoint(x: p.x - screenFrame.minX,
                                     y: p.y - screenFrame.minY))
    }

    func pixelRect(fromViewRect r: CGRect) -> PixelRect {
        // Rounded, not floored, on the edges. A view rect built from two
        // already-converted pixel edges must land back on those same edges, and
        // floor plus floating point error would lose the far edge.
        let x0 = Int((r.minX * scale).rounded())
        let x1 = Int((r.maxX * scale).rounded())
        let y0 = Int(((screenFrame.height - r.maxY) * scale).rounded())
        let y1 = Int(((screenFrame.height - r.minY) * scale).rounded())
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    // MARK: pixels -> points

    /// The top-left corner of that pixel, in view points.
    func viewPoint(fromPixel p: PixelPoint) -> CGPoint {
        CGPoint(x: CGFloat(p.x) / scale,
                y: screenFrame.height - CGFloat(p.y) / scale)
    }

    func viewRect(fromPixelRect r: PixelRect) -> CGRect {
        CGRect(x: CGFloat(r.x0) / scale,
               y: screenFrame.height - CGFloat(r.y1) / scale,
               width: CGFloat(r.width) / scale,
               height: CGFloat(r.height) / scale)
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        hi < lo ? lo : min(max(v, lo), hi)
    }
}

// MARK: - The overlay itself

/// The selection surface, drawn over a frozen still.
///
/// **Capture-first.** This view never captures anything. It receives an image
/// that was already taken and a `PixelBuffer` read from it.
///
/// MEASURED (probe A4), sampling one known pixel:
///
/// | approach                             | centre pixel      |
/// |--------------------------------------|-------------------|
/// | no exclusion                         | `rgb(140,140,140)` — the overlay leaked in |
/// | `SCContentFilter(excludingWindows:)` | `rgb(255,255,255)` — clean |
/// | capture first, show a frozen image   | `rgb(12,13,17)` — the real desktop |
///
/// Both of the last two work. Capture-first is chosen because it is correct by
/// construction rather than by remembering to pass a filter, and because it is
/// the only one under which zoom, pixel measurement and colour picking can
/// exist at all: they read a still image, not a moving screen.
@MainActor
final class OverlayView: NSView {

    // MARK: Inputs

    private let frozen: CGImage
    private let buffer: PixelBuffer
    private let geometry: OverlayGeometry
    private let settings: Settings

    /// Called exactly once. The controller tears the window down after it.
    var onOutcome: ((OverlayOutcome) -> Void)?

    // MARK: State, all in pixels

    private var selection: Selection?
    private var dragAnchor: PixelPoint?
    private var didDrag = false
    private var cursor = PixelPoint(x: 0, y: 0)
    private var trackingArea: NSTrackingArea?

    /// The current snap suggestions, smallest first, or empty for "show
    /// nothing". Built by `SnapLadder` from the pixel snap plus the real window
    /// frames, so pressing again grows outward through both.
    private var snapLadder: [PixelRect] = []
    private var snapRung = 0

    /// Exact window frames for this screen, in image pixels. Empty when
    /// enumeration failed, which degrades snapping to pixels only rather than
    /// breaking the overlay.
    var windowFrames: [PixelRect] = []

    /// What the last colour pick copied, so the user gets confirmation. The
    /// string is drawn on screen and NEVER logged: a picked colour is content
    /// off the user's screen.
    private var pickNote: String?
    private var pickSwatch: SRGB?

    // MARK: Look

    private static let loupePixels = 17          // 17x17, the size probe A15.2 timed
    private static let loupeZoom: CGFloat = 12   // points per pixel in the loupe
    private static let dimAlpha: CGFloat = 0.45  // the wash probe A4 used

    init(frozen: CGImage, buffer: PixelBuffer, geometry: OverlayGeometry, settings: Settings) {
        self.frozen = frozen
        self.buffer = buffer
        self.geometry = geometry
        self.settings = settings
        super.init(frame: CGRect(origin: .zero, size: geometry.viewSize))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: - Responder plumbing

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // stated, because everything below depends on it
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways` and not `.activeInKeyWindow`. Activation is
        // asynchronous, so for the first few runloop turns after the overlay
        // appears this window is not key yet, and with `.activeInKeyWindow` the
        // loupe would simply not move during exactly the moment the user is
        // looking for it.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        cursor = pixel(of: event)
        // NO throttling, NO caching, NO background queue.
        //
        // MEASURED (probe A15.2), reading from an already-captured image:
        // a whole 17x17 loupe frame costs 0.0451 ms median, a single pixel
        // 0.0000 ms and the forgiving 20x20 darkest pick 0.0700 ms. 371 loupe
        // frames fit inside one 16.7 ms frame at 60 Hz. A throttle here would
        // add lag and state for no measured gain.
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = pixel(of: event)
        dragAnchor = p
        didDrag = false
        cursor = p
        // A new drag replaces any snap suggestion. The snap is a suggestion the
        // user can ignore, and starting a fresh drag is how they ignore it.
        snapLadder = []
        snapRung = 0
        selection = Selection(from: p, to: p, bounds: buffer.bounds)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let p = pixel(of: event)
        cursor = p
        if abs(p.x - anchor.x) > 1 || abs(p.y - anchor.y) > 1 { didDrag = true }
        selection = Selection(from: anchor, to: p, bounds: buffer.bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil }
        guard didDrag, let selection, !selection.rect.isEmpty else {
            // A click without a drag is not a one-pixel capture request. It
            // clears the selection and leaves the overlay open, so a stray
            // click cannot silently produce a 1x1 screenshot.
            self.selection = nil
            needsDisplay = true
            return
        }
        finish(.region(selection.rect))
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        // Exact integers, always. This is the pixel-measurement feature, so a
        // step is 1 or 10 and never a float that rounds to either.
        let step = shift ? 10 : 1

        switch Int(event.keyCode) {
        case 53:                       // escape
            finish(.cancelled)
            return
        case 36, 76:                   // return, keypad enter
            if let selection, !selection.rect.isEmpty {
                finish(.region(selection.rect))
            } else {
                NSSound.beep()
            }
            return
        case 123: nudge(dx: -step, dy: 0, resize: option); return
        case 124: nudge(dx: step, dy: 0, resize: option); return
        case 125: nudge(dx: 0, dy: step, resize: option); return    // down arrow, +y is DOWN in pixels
        case 126: nudge(dx: 0, dy: -step, resize: option); return   // up arrow
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": pressSnap()
        case "c": pickColour(forgiving: shift)
        default: super.keyDown(with: event)
        }
    }

    /// Arrow-key nudging, through `Selection` so the maths is the same integer
    /// maths the core tests already cover.
    private func nudge(dx: Int, dy: Int, resize: Bool) {
        guard var s = selection else {
            // No selection yet: the first arrow press seeds a 1x1 at the
            // cursor, so the keyboard alone can build an exact rectangle.
            selection = Selection(from: cursor, to: cursor, bounds: buffer.bounds)
            needsDisplay = true
            return
        }
        if resize {
            // Option grows or shrinks the bottom-right corner, which is the
            // corner a drag naturally ends on.
            s.resize(.bottomRight, dx: dx, dy: dy)
        } else {
            s.move(dx: dx, dy: dy)
        }
        selection = s
        // A nudged selection is no longer the snapped one.
        snapLadder = []
        snapRung = 0
        needsDisplay = true
    }

    // MARK: - Edge snap

    /// MEASURED (probe A14). Flood fill scores 0.961 mean IoU at 0.20 ms, and
    /// `VNDetectRectanglesRequest` scores 0.533 and is not used. The part that
    /// matters here is the acceptance test: on three flat-desktop seeds it
    /// correctly refused, where a naive flood returned a confident
    /// 1.6-megapixel rectangle of empty desktop.
    ///
    /// So when `accepted` is false this shows NOTHING. No indicator, no
    /// "best guess", no selection change.
    private func pressSnap() {
        // Already showing a ladder: move out one rung.
        if !snapLadder.isEmpty {
            guard snapRung + 1 < snapLadder.count else { NSSound.beep(); return }
            snapRung += 1
            selection = Selection(rect: snapLadder[snapRung], bounds: buffer.bounds)
            needsDisplay = true
            return
        }

        let seed = selection.map { $0.rect.centre } ?? cursor
        let element = EdgeSnap.snap(in: buffer, at: seed, maxLevels: 3)

        // The window frames are the reason this key is worth pressing.
        // MEASURED: the pixel snap alone finds the control 8 times in 18 on
        // real windows, so on its own the key does nothing more than half the
        // time. Window frames are exact and always available.
        let ladder = SnapLadder.build(at: seed, element: element,
                                      windows: windowFrames, bounds: buffer.bounds)
        guard !ladder.isEmpty else {
            snapLadder = []
            snapRung = 0
            NSSound.beep()
            // The reason is a fixed string from the core, never user content.
            Log.overlay.info("""
                snap found nothing, element reason=\(element.reason, privacy: .public) \
                windows=\(self.windowFrames.count, privacy: .public)
                """)
            needsDisplay = true
            return
        }

        snapLadder = ladder
        snapRung = 0
        selection = Selection(rect: ladder[0], bounds: buffer.bounds)
        // The rung sizes, not just the count. A ladder that says "4" while
        // every rung is the same size is indistinguishable from a working one,
        // and sizes are our own geometry, never user content.
        let sizes = ladder.map { "\($0.width)x\($0.height)" }.joined(separator: " -> ")
        Log.overlay.info("""
            snap rungs=\(ladder.count, privacy: .public) \
            fromElement=\(element.accepted, privacy: .public) \
            windows=\(self.windowFrames.count, privacy: .public) \
            sizes=\(sizes, privacy: .public)
            """)
        needsDisplay = true
    }

    // MARK: - Colour picking

    /// Plain pick takes the exact pixel. Shift takes the darkest pixel in a
    /// 20x20 box, MEASURED at 0.0700 ms, because nobody can hit a one-pixel
    /// target with a mouse.
    private func pickColour(forgiving: Bool) {
        let colour = forgiving
            ? buffer.darkestColour(around: cursor, boxSize: 20)
            : buffer.colour(x: cursor.x, y: cursor.y)
        guard let colour else { NSSound.beep(); return }

        let text = settings.colourFormat.string(for: colour)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)

        pickNote = text
        pickSwatch = colour
        // The format NAME is ours, the value is the user's. Only the name and
        // the mode go to the log.
        Log.overlay.info("""
            colour copied format=\(self.settings.colourFormat.rawValue, privacy: .public) \
            mode=\(forgiving ? "darkest20" : "exact", privacy: .public)
            """)
        needsDisplay = true
    }

    // MARK: - Finishing

    private func finish(_ outcome: OverlayOutcome) {
        let handler = onOutcome
        onOutcome = nil          // exactly once, even if a key and a mouse-up race
        handler?(outcome)
    }

    private func pixel(of event: NSEvent) -> PixelPoint {
        geometry.pixel(fromViewPoint: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. The frozen still, at full size. This view exactly covers the
        //    screen, so the image maps one to one onto `bounds`.
        ctx.interpolationQuality = .none
        ctx.draw(frozen, in: bounds)

        // 2. Dim everything.
        ctx.setFillColor(NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor)
        ctx.fill(bounds)

        // 3. Cut the live selection back out at full brightness.
        if let rect = selection?.rect, !rect.isEmpty {
            let viewRect = geometry.viewRect(fromPixelRect: rect)
            ctx.saveGState()
            ctx.clip(to: viewRect)
            ctx.draw(frozen, in: bounds)
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(viewRect.insetBy(dx: 0.5, dy: 0.5))

            drawSizeReadout(for: rect, in: viewRect)
            drawContrastReadout(for: rect, in: viewRect)
        }

        // 4. The snap suggestion, only ever when it was accepted.
        if snapRung < snapLadder.count {
            let viewRect = geometry.viewRect(fromPixelRect: snapLadder[snapRung])
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(viewRect.insetBy(dx: 0.5, dy: 0.5))
            ctx.setLineDash(phase: 0, lengths: [])
            draw(text: "snap \(snapRung + 1)/\(snapLadder.count)",
                 at: CGPoint(x: viewRect.minX, y: viewRect.maxY + 4),
                 background: NSColor.systemYellow.withAlphaComponent(0.9),
                 foreground: .black)
        }

        drawLoupe(ctx)
        drawHintBar()
    }

    private func drawSizeReadout(for rect: PixelRect, in viewRect: CGRect) {
        // `describedSize` is the core's own wording, so the overlay and the
        // editor never disagree about what "1200 x 800" means.
        draw(text: rect.describedSize,
             at: CGPoint(x: viewRect.minX, y: viewRect.minY - 22),
             background: NSColor.black.withAlphaComponent(0.8),
             foreground: .white)
    }

    /// Live WCAG contrast across whatever is selected.
    ///
    /// It samples on a grid rather than reading every pixel. MEASURED (probe
    /// A15.2) covers a 20x20 box at 0.0700 ms; a full scan of a 1.6-megapixel
    /// selection on every mouse move is NOT in that measured budget. 128x128 is
    /// 16,384 samples, which is the same order as the loupe and finds the true
    /// extremes of any region large enough to read text in.
    private func drawContrastReadout(for rect: PixelRect, in viewRect: CGRect) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        let stepX = max(1, rect.width / 128)
        let stepY = max(1, rect.height / 128)
        var darkest = SRGB.white, lightest = SRGB.black
        var darkestLuma = Int.max, lightestLuma = Int.min
        var y = rect.y0
        while y < rect.y1 {
            var x = rect.x0
            while x < rect.x1 {
                let l = buffer.lumaAt(x: x, y: y)
                if l < darkestLuma, let c = buffer.colour(x: x, y: y) { darkestLuma = l; darkest = c }
                if l > lightestLuma, let c = buffer.colour(x: x, y: y) { lightestLuma = l; lightest = c }
                x += stepX
            }
            y += stepY
        }
        let ratio = Contrast.ratio(darkest, lightest)
        let grade = Contrast.grade(ratio)
        draw(text: "\(Contrast.formatted(ratio))  \(grade.rawValue)",
             at: CGPoint(x: viewRect.minX + 96, y: viewRect.minY - 22),
             background: NSColor.black.withAlphaComponent(0.8),
             foreground: grade == .fail ? .systemOrange : .white)
    }

    /// The magnified pixel grid that follows the cursor.
    private func drawLoupe(_ ctx: CGContext) {
        let n = Self.loupePixels
        let half = n / 2
        let zoom = Self.loupeZoom
        let side = CGFloat(n) * zoom

        var origin = geometry.viewPoint(fromPixel: cursor)
        origin.x += 24
        origin.y -= 24 + side
        // Flip near an edge so the loupe never falls off the screen, which is
        // exactly where a user zooms in to check a border pixel.
        if origin.x + side > bounds.maxX - 8 { origin.x = geometry.viewPoint(fromPixel: cursor).x - 24 - side }
        if origin.y < bounds.minY + 8 { origin.y = geometry.viewPoint(fromPixel: cursor).y + 24 }
        origin.x = max(bounds.minX + 8, min(origin.x, bounds.maxX - side - 8))
        origin.y = max(bounds.minY + 8, min(origin.y, bounds.maxY - side - 8))

        let frame = CGRect(x: origin.x, y: origin.y, width: side, height: side)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        ctx.fill(frame.insetBy(dx: -2, dy: -2))

        for row in 0..<n {
            for col in 0..<n {
                let px = cursor.x - half + col
                let py = cursor.y - half + row
                // Out of bounds draws as nothing rather than as a plausible
                // colour, matching `PixelBuffer.colour` returning nil.
                guard let c = buffer.colour(x: px, y: py) else { continue }
                ctx.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255,
                                         green: CGFloat(c.g) / 255,
                                         blue: CGFloat(c.b) / 255,
                                         alpha: 1))
                // The loupe grid is top-down in pixels, the view is bottom-up.
                ctx.fill(CGRect(x: frame.minX + CGFloat(col) * zoom,
                                y: frame.maxY - CGFloat(row + 1) * zoom,
                                width: zoom, height: zoom))
            }
        }

        // Mark the centre pixel, which is the one the readout is about.
        let centre = CGRect(x: frame.minX + CGFloat(half) * zoom,
                            y: frame.maxY - CGFloat(half + 1) * zoom,
                            width: zoom, height: zoom)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(centre.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.stroke(centre.insetBy(dx: 0.5, dy: 0.5))

        let under = buffer.colour(x: cursor.x, y: cursor.y)
        let hex = under?.hex ?? "--"
        draw(text: "\(hex)   \(cursor.x), \(cursor.y)",
             at: CGPoint(x: frame.minX, y: frame.minY - 20),
             background: NSColor.black.withAlphaComponent(0.9),
             foreground: .white)

        if let pickNote, let pickSwatch {
            let swatchRect = CGRect(x: frame.minX, y: frame.maxY + 6, width: 14, height: 14)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(pickSwatch.r) / 255,
                                     green: CGFloat(pickSwatch.g) / 255,
                                     blue: CGFloat(pickSwatch.b) / 255, alpha: 1))
            ctx.fill(swatchRect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.stroke(swatchRect.insetBy(dx: 0.5, dy: 0.5))
            draw(text: "copied \(pickNote)",
                 at: CGPoint(x: frame.minX + 20, y: frame.maxY + 4),
                 background: NSColor.black.withAlphaComponent(0.9),
                 foreground: .white)
        }
    }

    /// Shift-pick and the A key cannot be discovered any other way, so they are
    /// on screen the whole time rather than in a help window nobody opens.
    private func drawHintBar() {
        let hint = "drag select   \u{2190}\u{2191}\u{2193}\u{2192} nudge 1px "
            + "(\u{21E7} 10, \u{2325} resize)   A snap to edge   "
            + "C copy colour (\u{21E7} forgiving)   \u{21A9} capture   esc cancel"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let size = (hint as NSString).size(withAttributes: [.font: font])
        draw(text: hint,
             at: CGPoint(x: bounds.midX - size.width / 2 - 8, y: bounds.minY + 24),
             background: NSColor.black.withAlphaComponent(0.85),
             foreground: .white)
    }

    private func draw(text: String, at point: CGPoint, background: NSColor, foreground: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: point.x, y: point.y, width: size.width + 12, height: size.height + 6)
        background.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }
}
