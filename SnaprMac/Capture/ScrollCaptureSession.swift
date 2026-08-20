import AppKit
import SnaprCore

/// A running scroll capture: grab the same region over and over while the user
/// scrolls the content underneath, and stitch the frames into one tall image.
///
/// **The user scrolls by default, not the app.** Driving the scroll means
/// posting synthetic scroll events, and macOS only lets a process post those if
/// it holds the Accessibility grant. So manual is the baseline, needs no
/// permission, and always works; `Drive.automatic` is offered on the panel and
/// asks for the grant the first time it is pressed.
///
/// Either way Snapr cannot hold the keyboard during a run, because the app being
/// scrolled needs the focus. So there is no Escape and no Return here. The run
/// is ended by pressing the same shortcut again, or by clicking the panel that
/// stays on screen throughout.
@MainActor
final class ScrollCaptureSession {

    /// Stop before memory becomes the problem. Thirty thousand rows of a
    /// 1200 pixel wide region is about 140 MB, which is already far longer than
    /// any page anyone reads in one picture.
    static let maxHeight = 30_000
    /// About sixteen frames a second.
    ///
    /// MEASURED: one frame costs roughly 20 ms in a Release build once the
    /// window list is no longer re-enumerated per frame (17.8 ms capture, 0.8 ms
    /// to build the luma plane, 2.0 ms to find the offset). At the old 0.12 s
    /// this left five sixths of the budget idle while the page was allowed to
    /// move twice as far between frames as it needed to.
    ///
    /// Halving the interval halves how far the content can travel between two
    /// frames, which is the whole reason a fast manual scroll gets refused. The
    /// `busy` guard below means this is an upper bound rather than a promise:
    /// on a slower machine, or in a Debug build, ticks are simply skipped.
    static let interval: TimeInterval = 0.06

    enum Ending {
        case finished(CGImage)
        /// Nothing usable, and why. The two reasons need opposite advice: a
        /// page nobody scrolled wants "scroll it", a page that ignored our own
        /// scrolls wants "point at the thing you meant".
        case nothing(hint: String)
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
    /// Worked out once and reused. See `CaptureEngine.FrameSource`.
    private var source: CaptureEngine.FrameSource?
    /// Ticks that arrived while the previous frame was still being processed.
    /// A high count is the honest signal that the machine, or the build, cannot
    /// keep up with the requested rate.
    private var skippedBusy = 0
    /// Milliseconds per frame, so "it dropped frames" comes with a number.
    private var frameMillis: [Double] = []
    /// Set when the run already knows why it produced nothing.
    private var nothingHint: String?

    private(set) var drive: Drive = .manual
    /// When the page was last seen to move. An automatic run watches this to
    /// know it has reached the bottom without being told.
    private var lastMovement = Date()
    /// A DURATION, not a count of frames.
    ///
    /// MEASURED, and this is the bug that made the fix worth writing: with a
    /// count of three frames, raising the capture rate from 8 to 16 a second
    /// halved how long the app waited before calling a page finished. A real
    /// run then ended after 280 ms and four frames, three of them unchanged,
    /// and reported "reached the end of the page" when the page had simply not
    /// started moving yet. Anything tuned in frames is silently retuned by the
    /// frame rate; six hundred milliseconds is six hundred milliseconds.
    private let stillTimeThatMeansTheEnd: TimeInterval = 0.6
    /// True once the page has actually moved at least once.
    ///
    /// The end of a page can only be recognised after the beginning of one. A
    /// page that has never moved has not been scrolled to the bottom, it is not
    /// receiving our scrolls at all, and those two deserve different answers.
    private var everMoved = false
    /// When the finished image last got taller.
    ///
    /// Movement and GROWTH are not the same thing, and the difference is a
    /// hang. A page being scrolled faster than the stitcher can follow moves on
    /// every frame, so it never looks still and the end-of-page test never
    /// fires, but no frame is ever accepted so the image never grows. An
    /// automatic run in that state would keep scrolling to the bottom of a very
    /// long page and then keep going, with the panel showing the same height
    /// the whole time, until somebody pressed Done.
    private var lastGrowth = Date()
    /// Longer than the still test, because a page that is being refused
    /// deserves a few seconds to recover on its own before the run is called
    /// off.
    private let noGrowthTimeout: TimeInterval = 3.0
    /// How long to keep trying before admitting the scrolls are not landing.
    ///
    /// Something is under the pointer that does not scroll: the desktop, a
    /// window that ignores synthetic events, or a region the user drew outside
    /// the thing they meant. Waiting forever is worse than saying so.
    private let unresponsiveTimeout: TimeInterval = 2.5

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
        lastMovement = Date()
        lastGrowth = Date()
        onDriveChanged?(drive)
        Log.capture.info("scroll capture drive is \(wanted == .automatic ? "automatic" : "manual", privacy: .public)")
        return true
    }

    /// How far to scroll per frame, in points.
    ///
    /// A SIXTH of the region, not the third it used to be.
    ///
    /// MEASURED on a live automatic capture of TextEdit with a 1561 pixel
    /// region and a step of 520 pixels, from the app's own log:
    ///
    ///     refused frame, bestDY=520   ...
    ///     refused frame, bestDY=1040  ...
    ///     refused frame, bestDY=1040  ...
    ///
    /// The page travelled 1040 pixels in one frame from a 520 pixel step,
    /// because a text view animates a scroll over about 150 ms and at this
    /// capture rate two or three impulses are in flight at once. 1040 is
    /// exactly two thirds of the region, which is the most the stitcher will
    /// accept, so every frame sat on the cliff edge.
    ///
    /// A sixth leaves the doubled-up case at a third of the region, which the
    /// stitcher matches with room to spare. It costs speed and nothing else:
    /// at sixteen frames a second this still scrolls about 2000 points every
    /// second, which is a long page in a couple of seconds.
    private var scrollStep: Int {
        let points = Double(region.height) / screen.backingScaleFactor
        return max(40, Int(points / 6))
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
                \(self.stitcher?.dropped ?? 0, privacy: .public) unchanged, \
                \(self.frameCostSummary, privacy: .public)
                """)
            onEnded?(.nothing(hint: nothingHint
                ?? (drive == .automatic
                    ? "Nothing under the middle of that region scrolled"
                    : "Scroll the window while the capture is running")))
            return
        }
        let result = stitcher.finish()
        guard let image = ImageBridge.cgImage(from: result) else {
            onEnded?(.nothing(hint: "The stitched image could not be built"))
            return
        }
        Log.capture.info("""
            scroll capture done, \(image.width, privacy: .public)\
            x\(image.height, privacy: .public), \(stitcher.accepted, privacy: .public) frames, \
            \(self.lost, privacy: .public) refused, \(self.rebased, privacy: .public) rebased, \
            \(Redact.ms(Date().timeIntervalSince(self.startedAt)), privacy: .public), \
            \(self.frameCostSummary, privacy: .public)
            """)
        onEnded?(.finished(image))
    }

    /// How long a frame actually took, and how many ticks had to be skipped
    /// because of it. Logged at the end of every run, because a run that
    /// refused most of its frames looks the same whether the user scrolled too
    /// fast or the machine could not keep up, and those have opposite fixes.
    private var frameCostSummary: String {
        guard !frameMillis.isEmpty else { return "no frame timings" }
        let sorted = frameMillis.sorted()
        let median = sorted[sorted.count / 2]
        return String(format: "%.0f ms per frame median, %.0f ms worst, %d ticks skipped",
                      median, sorted[sorted.count - 1], skippedBusy)
    }

    // MARK: - One frame

    private func tick() {
        // Frames are dropped rather than queued when a capture runs long. A
        // backlog would stitch stale frames in the wrong order, which is worse
        // than a slightly slower sample rate.
        guard !stopped else { return }
        guard !busy else { skippedBusy += 1; return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let began = CFAbsoluteTimeGetCurrent()
            do {
                // Established on the first frame rather than in `start`, which
                // is synchronous. Every later frame reuses it.
                // Written out rather than with `??`, because the right-hand
                // side is async and an autoclosure cannot await.
                let source: CaptureEngine.FrameSource
                if let existing = self.source {
                    source = existing
                } else {
                    source = try await capture.frameSource(for: screen)
                    self.source = source
                }
                let full = try await capture.captureFrame(using: source)
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
                frameMillis.append((CFAbsoluteTimeGetCurrent() - began) * 1000)
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
            lastMovement = Date()
            lastGrowth = Date()
            // The FIRST rebase is expected and silent: it is the frame taken
            // through the fading selection overlay. Every one after that means
            // the user is scrolling faster than the capture can follow, and
            // saying nothing there is what made a run look like it was working
            // while it captured one screen over and over.
            onProgress?(frame.height, lost + max(0, rebased - 1))
            return
        }

        if current.height > (stitcher?.height ?? 0) { lastGrowth = Date() }
        stitcher = current
        if case .lost = step {
            lost += 1
            // Numbers only, never pixels. A refused frame is almost always the
            // page having moved further than the stitcher will accept, and the
            // offset it settled on says whether that is what happened.
            // The first few only. A run that refuses everything says so in five
            // lines just as well as in three hundred.
            if lost <= 5, let d = ScrollStitch.lastDiagnosis {
                Log.capture.info("""
                    refused frame, bestDY=\(d.bestDY, privacy: .public) \
                    best=\(d.best, privacy: .public) second=\(d.second, privacy: .public) \
                    median=\(d.median, privacy: .public) verified=\(d.verified, privacy: .public)
                    """)
            }
        }
        onProgress?(current.height, lost)

        // A refused frame counts as movement, because that is exactly what it
        // is: the page moved further than the stitcher could follow. Only a
        // frame that is genuinely identical to the one before it is stillness,
        // and treating a burst of refusals as a still page would end a run in
        // the middle of a document.
        if step != .still {
            if case .scrolled = step { everMoved = true }
            lastMovement = Date()
        }

        // An automatic run ends itself at the bottom of the page. It is the one
        // thing automatic scrolling can know that a hand cannot be asked about:
        // it scrolled, and the page did not move, so there is nothing below.
        if drive == .automatic {
            let quietFor = Date().timeIntervalSince(lastMovement)
            if everMoved, quietFor >= stillTimeThatMeansTheEnd {
                Log.capture.info("scroll capture reached the end of the page")
                stop()
                return
            }
            if everMoved, Date().timeIntervalSince(lastGrowth) >= noGrowthTimeout {
                Log.capture.info("scroll capture stopped, nothing has been added for a while")
                stop()
                return
            }
            if !everMoved, quietFor >= unresponsiveTimeout {
                // Deliberately a different message from the one above. "The
                // page never moved" and "the page ran out" look identical in a
                // frame count and have completely different fixes.
                Log.capture.info("scroll capture gave up, the page never moved")
                nothingHint = "Nothing under the middle of that region scrolled"
                stop()
                return
            }
        }

        if current.height >= Self.maxHeight {
            Log.capture.info("scroll capture hit its height limit")
            stop()
        }
    }
}
