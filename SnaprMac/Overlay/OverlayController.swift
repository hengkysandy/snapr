import AppKit
import CoreGraphics
import Foundation
import SnaprCore

enum OverlayOutcome: Sendable {
    case cancelled
    /// In the frozen image's own pixel coordinates, top-left origin.
    case region(PixelRect)
}

/// A borderless panel that can actually become key.
///
/// This subclass exists for one line. A borderless `NSPanel` returns false from
/// `canBecomeKey` by default, so it appears on screen, accepts mouse events,
/// and then silently receives no key events at all. Escape does nothing, the
/// arrow keys do nothing, and there is no error anywhere. That failure looks
/// exactly like a broken key handler.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the overlay window and hands back one outcome.
///
/// **Capture-first, per design 4.3.** This type never captures. It is given a
/// still that was already taken and it shows it. Everything the overlay can do,
/// zoom, pixel measurement, colour picking, edge snap, is only possible because
/// it is reading a frozen image rather than a moving screen.
@MainActor
final class OverlayController {

    var onFinish: ((OverlayOutcome) -> Void)?

    private var panel: OverlayPanel?
    private var view: OverlayView?
    private var startedAt: CFAbsoluteTime = 0

    init() {}

    /// - Parameters:
    ///   - frozen: the already-captured still for this screen.
    ///   - buffer: the same image as RGBA8, built once by `ImageBridge`.
    ///   - screen: the screen the still came from. The panel covers it exactly,
    ///     which is what makes the point-to-pixel conversion a single flip.
    ///   - windows: exact window frames for this screen, in image pixels.
    ///     Defaults to empty so the contract signature still compiles, and an
    ///     empty list degrades snapping to pixels only rather than breaking it.
    func begin(frozen: CGImage, buffer: PixelBuffer, screen: NSScreen,
               settings: Settings, windows: [PixelRect] = []) {
        // A second `begin` while one is open would leak the first panel and
        // leave two overlays fighting for key. Cancel is the honest answer.
        if panel != nil { cancel() }

        startedAt = CFAbsoluteTimeGetCurrent()
        let geometry = OverlayGeometry(screenFrame: screen.frame, scale: screen.backingScaleFactor)

        // A frozen image that does not match the screen means the selection
        // rectangle would index the wrong pixels. Loud, not silent.
        if frozen.width != geometry.pixelWidth || frozen.height != geometry.pixelHeight {
            Log.overlay.error("""
                frozen image \(frozen.width, privacy: .public)x\(frozen.height, privacy: .public) \
                does not match screen \(geometry.pixelWidth, privacy: .public)x\
                \(geometry.pixelHeight, privacy: .public)
                """)
        }

        let panel = OverlayPanel(contentRect: screen.frame,
                                 styleMask: [.borderless],
                                 backing: .buffered,
                                 defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Without this, `mouseMoved` never arrives and the loupe stands still.
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(screen.frame, display: false)

        let view = OverlayView(frozen: frozen, buffer: buffer, geometry: geometry, settings: settings)
        view.windowFrames = windows
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        view.onOutcome = { [weak self] outcome in self?.complete(outcome) }
        panel.contentView = view

        self.panel = panel
        self.view = view

        // The app is LSUIElement, so it has no Dock icon and is often not the
        // active app when a global hotkey fires. Without an explicit activate,
        // the panel appears and never becomes key.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)

        // Activation is asynchronous. `isKeyWindow` is deliberately NOT read
        // here: in this same runloop turn it is still false, and a check here
        // would report a failure that has not happened yet. If key focus is
        // ever really lost, the symptom is dead keys, and that is what the
        // `canBecomeKey` override above exists to prevent.
        Log.overlay.info("""
            overlay began \(frozen.width, privacy: .public)x\(frozen.height, privacy: .public) \
            scale=\(String(format: "%.1f", screen.backingScaleFactor), privacy: .public)
            """)
    }

    /// Close with no result. Safe to call when nothing is open.
    func cancel() {
        guard panel != nil else { return }
        complete(.cancelled)
    }

    private func complete(_ outcome: OverlayOutcome) {
        guard let panel else { return }
        self.panel = nil
        self.view = nil
        panel.orderOut(nil)

        switch outcome {
        case .cancelled:
            Log.overlay.info("overlay cancelled after \(Redact.ms(CFAbsoluteTimeGetCurrent() - self.startedAt), privacy: .public)")
        case .region(let rect):
            // Size and duration only. The pixels themselves never reach a log.
            Log.overlay.info("""
                overlay region \(rect.describedSize, privacy: .public) \
                after \(Redact.ms(CFAbsoluteTimeGetCurrent() - self.startedAt), privacy: .public)
                """)
        }
        onFinish?(outcome)

        // Tear the window down on the NEXT runloop turn, holding the panel
        // strongly until then. `complete` is always reached from inside the
        // view's own `mouseUp` or `keyDown`, so dropping the last reference to
        // the view here could deallocate it while one of its methods is still
        // on the stack. That crash would be rare, would only happen on the
        // happy path, and would look like a random crash on capture.
        DispatchQueue.main.async {
            panel.contentView = nil
        }
    }
}
