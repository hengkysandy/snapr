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

    /// Who moves the page.
    enum Drive: Equatable {
        /// The user's own fingers. Needs no permission at all.
        case manual
        /// Snapr posts scroll events. Needs the Accessibility grant.
        case automatic
    }

    var onEnded: ((Ending) -> Void)?
    /// Fires on every accepted frame, for the readout on screen.
    var onProgress: ((_ height: Int, _ lost: Int) -> Void)?
    var onDriveChanged: ((Drive) -> Void)?

    private let capture: CaptureEngine
    private let screen: NSScreen
    private let region: PixelRect
    private var stitcher: ScrollStitcher?
    private var timer: Timer?
    private var busy = false
    private var lost = 0
    private var rebased = 0
    /// Frames that actually reached the stitcher. Logged because "nothing was
    /// captured" and "everything was captured and none of it moved" look
    /// identical from the outside and have completely different causes.
    private var captured = 0
    private var stopped = false
    private let startedAt = Date()

    private(set) var drive: Drive = .manual
    /// Frames that did not move since the last automatic scroll. Several in a
    /// row means the page has stopped, which is how an automatic run knows it
    /// has reached the bottom without being told.
    private var stillSinceScroll = 0
    /// Three, not one. A single unchanged frame usually means the app has not
    /// finished redrawing yet, and stopping on that would cut a page short.
    private let stillFramesThatMeanTheEnd = 3

    init(capture: CaptureEngine, screen: NSScreen, region: PixelRect) {
        self.capture = capture
        self.screen = screen
        self.region = region
    }

    var isRunning: Bool { timer != nil }
    var stitchedHeight: Int { stitcher?.height ?? 0 }

    /// Switch between scrolling by hand and letting the app do it.
    ///
    /// Returns false when automatic was asked for and macOS will not deliver
    /// synthetic events, so the caller can say why rather than running a
    /// capture that silently never moves.
    @discardableResult
    func setDrive(_ wanted: Drive) -> Bool {
        if wanted == .automatic && !AutoScroller.isTrusted { return false }
        drive = wanted
        stillSinceScroll = 0
        onDriveChanged?(drive)
        Log.capture.info("scroll capture drive is \(wanted == .automatic ? "automatic" : "manual", privacy: .public)")
        return true
    }

    /// How far to scroll per frame, in points.
    ///
    /// A third of the region. The stitcher refuses anything past two thirds,
    /// because a smaller overlap cannot be matched with confidence, so a third
    /// leaves room for an app that animates its scrolling and overshoots.
    private var scrollStep: Int {
        let points = Double(region.height) / screen.backingScaleFactor
        return max(40, Int(points / 3))
    }

    private func postScroll() {
        // The middle of the region, because a scroll goes to whatever is under
        // the pointer rather than to whatever has focus. That is also what lets
        // this work while Snapr stays in the background.
        let scale = screen.backingScaleFactor
        let midX = (Double(region.x0) + Double(region.width) / 2) / scale
        let midY = (Double(region.y0) + Double(region.height) / 2) / scale
        AutoScroller.scrollDown(points: scrollStep,
                                at: CGPoint(x: screen.frame.minX + midX,
                                            y: screen.frame.minY + midY))
    }

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
            Log.capture.info("""
                scroll capture ended with nothing, \(self.captured, privacy: .public) frames captured, \
                \(self.lost, privacy: .public) refused, \(self.rebased, privacy: .public) restarted, \
                \(self.stitcher?.dropped ?? 0, privacy: .public) unchanged
                """)
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
                captured += 1
                accept(buffer)
                // The next scroll is posted AFTER the frame it follows, so the
                // capture and the scroll take turns. Posting on a timer of its
                // own would let the page run ahead of the capture and lose a
                // screen of content between two frames.
                if drive == .automatic, !stopped { postScroll() }
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
            // The FIRST rebase is expected and silent: it is the frame taken
            // through the fading selection overlay. Every one after that means
            // the user is scrolling faster than the capture can follow, and
            // saying nothing there is what made a run look like it was working
            // while it captured one screen over and over.
            onProgress?(frame.height, lost + max(0, rebased - 1))
            return
        }

        stitcher = current
        if case .lost = step { lost += 1 }
        onProgress?(current.height, lost)

        // An automatic run ends itself at the bottom of the page. It is the one
        // thing automatic scrolling can know that a hand cannot be asked about:
        // it scrolled, and the page did not move, so there is nothing below.
        if drive == .automatic {
            if step == .still {
                stillSinceScroll += 1
                if stillSinceScroll >= stillFramesThatMeanTheEnd {
                    Log.capture.info("scroll capture reached the end of the page")
                    stop()
                    return
                }
            } else {
                stillSinceScroll = 0
            }
        }

        if current.height >= Self.maxHeight {
            Log.capture.info("scroll capture hit its height limit")
            stop()
        }
    }
}
