import AppKit
import SnaprCore

/// A running scroll capture: grab the same region over and over while the user
/// scrolls the content underneath, and stitch the frames into one tall image.
///
/// **The user scrolls, not the app.** Driving the scroll from here would mean
/// posting synthetic scroll events, and macOS only lets a process post those if
/// it holds the Accessibility grant. Snapr does not need Accessibility and says
/// so in its README. Keeping that promise is worth asking the user to move two
/// fingers.
///
/// It follows from that choice that Snapr cannot hold the keyboard during a run:
/// the app being scrolled needs the focus. So there is no Escape and no Return
/// here. The run is ended by pressing the same shortcut again, or by clicking
/// the panel that stays on screen throughout.
@MainActor
final class ScrollCaptureSession {

    /// Stop before memory becomes the problem. Thirty thousand rows of a
    /// 1200 pixel wide region is about 140 MB, which is already far longer than
    /// any page anyone reads in one picture.
    static let maxHeight = 30_000
    /// Roughly eight frames a second. Fast enough to follow an ordinary
    /// trackpad scroll, slow enough that a 13 ms capture is a small fraction of
    /// the machine.
    static let interval: TimeInterval = 0.12

    enum Ending {
        case finished(CGImage)
        /// Nothing usable. The user never scrolled, or every frame was refused.
        case nothing
        case failed(Error)
    }

    var onEnded: ((Ending) -> Void)?
    /// Fires on every accepted frame, for the readout on screen.
    var onProgress: ((_ height: Int, _ lost: Int) -> Void)?

    private let capture: CaptureEngine
    private let screen: NSScreen
    private let region: PixelRect
    private var stitcher: ScrollStitcher?
    private var timer: Timer?
    private var busy = false
    private var lost = 0
    private var rebased = 0
    private var stopped = false
    private let startedAt = Date()

    init(capture: CaptureEngine, screen: NSScreen, region: PixelRect) {
        self.capture = capture
        self.screen = screen
        self.region = region
    }

    var isRunning: Bool { timer != nil }
    var stitchedHeight: Int { stitcher?.height ?? 0 }

    // MARK: - Running

    func start() {
        Log.capture.info("""
            scroll capture started, region \(self.region.width, privacy: .public)\
            x\(self.region.height, privacy: .public)
            """)
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // No frame straight away. The selection overlay is still on screen for a
        // moment after the drag ends, dimming everything, and a base frame taken
        // through it can never be matched by a clean one. The rebase in
        // `accept` recovers from that anyway, but waiting means the run does not
        // start by telling the user it skipped frames.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil

        guard var stitcher, stitcher.accepted > 1 else {
            Log.capture.info("scroll capture ended with nothing, \(self.lost, privacy: .public) frames refused")
            onEnded?(.nothing)
            return
        }
        let result = stitcher.finish()
        guard let image = ImageBridge.cgImage(from: result) else {
            onEnded?(.nothing)
            return
        }
        Log.capture.info("""
            scroll capture done, \(image.width, privacy: .public)\
            x\(image.height, privacy: .public), \(stitcher.accepted, privacy: .public) frames, \
            \(self.lost, privacy: .public) refused, \(self.rebased, privacy: .public) rebased, \
            \(Redact.ms(Date().timeIntervalSince(self.startedAt)), privacy: .public)
            """)
        onEnded?(.finished(image))
    }

    // MARK: - One frame

    private func tick() {
        // Frames are dropped rather than queued when a capture runs long. A
        // backlog would stitch stale frames in the wrong order, which is worse
        // than a slightly slower sample rate.
        guard !busy, !stopped else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let full = try await capture.captureFrame(screen)
                guard !stopped else { return }
                guard let cropped = ImageBridge.crop(full, to: region),
                      let buffer = ImageBridge.pixelBuffer(from: cropped) else { return }
                accept(buffer)
            } catch {
                // A single failed frame is not the end of a run. The display
                // configuration can change, or a capture can time out, and the
                // next frame usually works.
                lost += 1
                Log.capture.error("scroll frame failed, \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func accept(_ frame: PixelBuffer) {
        guard var current = stitcher else {
            stitcher = ScrollStitcher(first: frame)
            onProgress?(frame.height, 0)
            return
        }
        let step = current.add(frame)

        if case .lost = step, current.isEmpty {
            // Nothing has been stitched on yet, so it is the BASE that cannot be
            // matched, not this frame. MEASURED on the running app: the first
            // frame of a run is captured while the selection overlay is still
            // dimming the screen, and a dimmed frame never matches a clean one.
            // Every later frame was then refused and a whole run produced
            // nothing at all: 134 frames in, 133 refused, one frame out.
            //
            // Starting again from this frame costs nothing, because nothing has
            // been accumulated yet.
            stitcher = ScrollStitcher(first: frame)
            rebased += 1
            onProgress?(frame.height, lost)
            return
        }

        stitcher = current
        if case .lost = step { lost += 1 }
        onProgress?(current.height, lost)

        if current.height >= Self.maxHeight {
            Log.capture.info("scroll capture hit its height limit")
            stop()
        }
    }
}
