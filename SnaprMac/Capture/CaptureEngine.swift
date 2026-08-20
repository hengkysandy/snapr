import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SnaprCore

/// One window, described without ever carrying its title.
///
/// MEASURED (probe A5): `SCShareableContent` returned 21 windows and all 21 had
/// a non-empty title. So the titles are there and they are readable. They are
/// still user content, so this app carries the LENGTH and nothing else. The
/// length is enough to tell a real title from a title that macOS redacted to
/// zero characters when the grant is missing, which is the only thing the app
/// needs to know.
struct WindowInfo: Sendable, Identifiable {
    var id: CGWindowID
    var titleLength: Int
    var appName: String
    /// Global backing pixels, top-left origin, matching `PixelRect` everywhere.
    var frame: PixelRect
    var isOnScreen: Bool
}

enum CaptureError: Error {
    /// Read from the error, not from the pixels. See `CaptureEngine.classify`.
    case noPermission
    case noDisplay
    case failed(String)
    /// Secondary signal only. It still covers a sleeping display or a filter
    /// that excluded everything, but it is no longer how the app learns it has
    /// no permission.
    case blankFrame(String)
}

/// The only path to screen pixels in this app.
///
/// MEASURED (probe A3): 50 consecutive `SCScreenshotManager.captureImage` calls
/// at 2940x1912 gave min 11.8 ms, median 13.4 ms, max 49.4 ms. Shottr advertises
/// 17 ms. A one-shot capture per hotkey press is already faster than the
/// reference app, so there is no pre-warmed `SCStream` anywhere in Snapr. That
/// removes a whole subsystem.
///
/// MEASURED while writing the probe: `CGDisplayCreateImage` is **unavailable**
/// in the macOS 26 SDK, not deprecated. There is no legacy capture path to fall
/// back to and no second API to cross-check against.
@MainActor
final class CaptureEngine {

    /// `SCStreamErrorDomain Code=-3801 "The user declined TCCs for application,
    /// window, display capture"`. MEASURED (probe A1).
    /// `nonisolated` so `classify` can read it off the main actor. Error
    /// mapping must work wherever a capture failed.
    nonisolated static let userDeclinedCode = -3801

    private var didWarmUp = false

    init() {}

    // MARK: - Warm up

    /// One throwaway capture at launch, and nothing more.
    ///
    /// MEASURED (probe A3): the 49.4 ms maximum in a 50-capture run was the
    /// cold first call, against a 13.4 ms median. So warming the ScreenCaptureKit
    /// stack once is worth 36 ms on the user's first hotkey press. A pre-warmed
    /// stream would buy nothing on top of that and cost a whole subsystem.
    func warmUp() async {
        guard !didWarmUp else { return }
        didWarmUp = true
        let started = CFAbsoluteTimeGetCurrent()
        do {
            guard let display = try await shareableDisplays().first else {
                Log.capture.notice("warmUp skipped, no display")
                return
            }
            // Tiny on purpose. The point is to load the framework, start the
            // capture daemon connection and pay the first-call cost, not to
            // produce a usable image.
            let cfg = Self.configuration(pixelWidth: 64, pixelHeight: 64, showsCursor: false)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            Log.capture.info("warmUp done in \(Redact.ms(CFAbsoluteTimeGetCurrent() - started), privacy: .public)")
        } catch {
            // A failure here is not fatal. It usually means the grant is
            // missing, and the app finds that out again on the first real
            // capture with a user-visible message attached.
            let kind = Self.classify(error)
            Log.capture.notice("warmUp failed, kind=\(String(describing: kind), privacy: .public)")
        }
    }

    // MARK: - Permission

    func hasPermission() -> Bool {
        // Preflight does NOT prompt. Request does. They are kept apart because
        // an app that prompts on every check cannot report the quiet case.
        //
        // MEASURED (probe, terminal trap): running a binary straight from a
        // terminal makes TCC attribute this to the RESPONSIBLE process, so a
        // brand new app with no grant reported `true`. Any measurement of this
        // function has to come from a LaunchServices launch.
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        let granted = CGRequestScreenCaptureAccess()
        Log.capture.notice("requested screen recording, immediate result=\(granted, privacy: .public)")
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Capture

    func captureFullScreen(_ screen: NSScreen) async throws -> CGImage {
        let started = CFAbsoluteTimeGetCurrent()
        let image = try await grabScreen(
            screen, showsCursor: SettingsStore.shared.settings.showCursorInCapture)
        Log.capture.info("""
            fullScreen \(image.width, privacy: .public)x\(image.height, privacy: .public) \
            in \(Redact.ms(CFAbsoluteTimeGetCurrent() - started), privacy: .public)
            """)
        return image
    }

    /// One frame of a scroll run.
    ///
    /// Quiet, because this is called about eight times a second and a log line
    /// per frame would bury everything else in the log for the whole run. Never
    /// shows the cursor either, whatever the setting says: a pointer stitched
    /// into the middle of a long page is a mark the user cannot remove.
    ///
    /// It grabs the whole screen and the caller crops, rather than using
    /// `sourceRect`. That wastes a few milliseconds per frame and it is a
    /// deliberate trade: this is the exact code path that is already proven end
    /// to end, and a mis-specified source rectangle would silently capture the
    /// wrong part of the screen.
    func captureFrame(_ screen: NSScreen) async throws -> CGImage {
        try await grabScreen(screen, showsCursor: false)
    }

    /// Everything a repeated capture of the same screen needs, worked out once.
    ///
    /// MEASURED on this machine: `SCShareableContent.excludingDesktopWindows`
    /// costs a 7.4 ms median and `SCScreenshotManager.captureImage` costs 17.8
    /// ms. Enumerating on every frame of a scroll run therefore spent about a
    /// quarter of the frame budget re-answering a question whose answer cannot
    /// change during the run: which display this is, and which windows are
    /// ours.
    ///
    /// The window list is a snapshot on purpose. A scroll run lasts a few
    /// seconds with our own panel on screen the whole time, and re-reading it
    /// per frame to catch a window that will not appear is the trade that was
    /// costing the frame rate.
    ///
    /// Only for a run of frames. A one-shot capture still enumerates, because
    /// there the 7.4 ms is paid once and a stale window list would be a real
    /// bug.
    struct FrameSource {
        let filter: SCContentFilter
        let config: SCStreamConfiguration
    }

    func frameSource(for screen: NSScreen) async throws -> FrameSource {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw Self.classify(error)
        }
        guard let display = Self.match(screen, in: content.displays) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let scale = Int(screen.backingScaleFactor.rounded())
        return FrameSource(
            filter: SCContentFilter(display: display,
                                    excludingWindows: Self.ownWindows(in: content)),
            config: Self.configuration(pixelWidth: display.width * scale,
                                       pixelHeight: display.height * scale,
                                       showsCursor: false))
    }

    func captureFrame(using source: FrameSource) async throws -> CGImage {
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: source.filter, configuration: source.config)
        } catch {
            throw Self.classify(error)
        }
        if let reason = Self.blankFrameReason(image) {
            throw CaptureError.blankFrame(reason)
        }
        return image
    }

    private func grabScreen(_ screen: NSScreen, showsCursor: Bool) async throws -> CGImage {
        // ONE enumeration, used for both the display and our own windows.
        // Fetching it twice doubled the slowest part of a capture, and this
        // runs eight times a second during a scrolling capture.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw Self.classify(error)
        }
        guard let display = Self.match(screen, in: content.displays) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let scale = Int(screen.backingScaleFactor.rounded())
        let cfg = Self.configuration(pixelWidth: display.width * scale,
                                     pixelHeight: display.height * scale,
                                     showsCursor: showsCursor)
        let filter = SCContentFilter(display: display,
                                     excludingWindows: Self.ownWindows(in: content))

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw Self.classify(error)
        }
        if let reason = Self.blankFrameReason(image) {
            throw CaptureError.blankFrame(reason)
        }
        return image
    }

    func captureWindow(id: CGWindowID) async throws -> CGImage {
        let started = CFAbsoluteTimeGetCurrent()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.failed("window \(id) is gone")
        }
        // The scale of the screen the window sits on. UNPROVEN (gap A7): this
        // machine has one display, so a second display with a different backing
        // scale factor, or a negative origin, is unmeasured.
        let scale = Int(Self.screen(containing: window.frame).backingScaleFactor.rounded())
        let cfg = Self.configuration(pixelWidth: Int(window.frame.width) * scale,
                                     pixelHeight: Int(window.frame.height) * scale,
                                     showsCursor: false)
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw Self.classify(error)
        }
        if let reason = Self.blankFrameReason(image) {
            throw CaptureError.blankFrame(reason)
        }
        Log.capture.info("""
            window \(image.width, privacy: .public)x\(image.height, privacy: .public) \
            in \(Redact.ms(CFAbsoluteTimeGetCurrent() - started), privacy: .public)
            """)
        return image
    }

    // MARK: - Enumeration

    func listWindows() async throws -> [WindowInfo] {
        let content = try await shareableContent()
        let infos = content.windows.map { window -> WindowInfo in
            let scale = Self.screen(containing: window.frame).backingScaleFactor
            return WindowInfo(
                id: window.windowID,
                // The count, never the string. Window titles are user content.
                titleLength: (window.title ?? "").count,
                appName: window.owningApplication?.applicationName ?? "Unknown",
                frame: Self.pixelRect(window.frame, scale: scale),
                isOnScreen: window.isOnScreen)
        }
        // MEASURED (probe A5): 21 windows, 21 with a non-empty title. macOS
        // redacts titles to zero characters when the grant is missing and that
        // redaction is NOT an error, so the count of readable titles is the
        // only honest signal that enumeration really worked.
        let readable = infos.filter { $0.titleLength > 0 }.count
        Log.capture.info("windows=\(infos.count, privacy: .public) withReadableTitle=\(readable, privacy: .public)")
        return infos
    }

    /// Window frames for one screen, converted into that screen's IMAGE pixel
    /// space, ready to hand to the selection overlay.
    ///
    /// `listWindows()` reports frames in GLOBAL backing pixels. The overlay
    /// works in the captured image's own space, whose origin is the screen's
    /// top-left corner, so the screen origin has to come off. On a single
    /// display that offset is zero and the bug would be invisible, which is
    /// exactly why the subtraction is written out here rather than skipped.
    /// This is gap A7 in the design: unmeasured until there is a second display.
    ///
    /// Used for snapping. MEASURED (`probes/edges/REAL-RESULTS.md`): pixel
    /// element snapping finds the control 8 times in 18 on real windows, so
    /// more than half the time the snap key does nothing. These frames are
    /// EXACT and cost no extra permission, so they give the key something
    /// correct to do every time.
    func windowFrames(on screen: NSScreen) async -> [PixelRect] {
        guard let windows = try? await listWindows() else {
            // A snap suggestion is a nicety. Failing to enumerate must never
            // stop the user selecting a region by hand.
            Log.capture.info("window frames unavailable, snapping falls back to pixels only")
            return []
        }
        let scale = screen.backingScaleFactor
        let originX = Int((screen.frame.minX * scale).rounded())
        let originY = Int((screen.frame.minY * scale).rounded())
        return windows
            .filter { $0.isOnScreen }
            .map { $0.frame.offsetBy(dx: -originX, dy: -originY) }
    }

    func frontmostWindow() async throws -> WindowInfo? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        let content = try await shareableContent()
        // Layer 0 is the normal window layer. Menus, panels and the Dock sit
        // above it and are never what "capture the active window" means.
        // Largest by area, because a real window beats a tooltip owned by the
        // same process. SCShareableContent does not promise front-to-back
        // ordering, so it is not relied on.
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let scale = Self.screen(containing: window.frame).backingScaleFactor
        return WindowInfo(id: window.windowID,
                          titleLength: (window.title ?? "").count,
                          appName: window.owningApplication?.applicationName ?? "Unknown",
                          frame: Self.pixelRect(window.frame, scale: scale),
                          isOnScreen: window.isOnScreen)
    }

    // MARK: - Shared plumbing

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
        } catch {
            throw Self.classify(error)
        }
    }

    /// Snapr's own windows, so a capture never contains Snapr.
    ///
    /// MEASURED on a real scrolling capture: the panel that reports the height
    /// sits over the screen for the whole run, so it landed in every frame and
    /// was stitched into the result again and again. The finished image of a
    /// web page had "0 px", "1273 px captured" and "1507 px captured" stamped
    /// down the middle of it.
    ///
    /// Excluding the whole application rather than one panel, because the same
    /// would happen to any window this app puts on screen during a capture, and
    /// a capture of Snapr is never what anyone wants.
    nonisolated static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let mine = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == mine }
    }

    private func shareableDisplays() async throws -> [SCDisplay] {
        do {
            // Desktop windows included here, because a full-screen capture is
            // supposed to contain the wallpaper and the desktop icons.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return content.displays
        } catch {
            throw Self.classify(error)
        }
    }

    // MARK: - Configuration

    /// Every configuration in this app goes through here, so the sRGB line
    /// cannot be forgotten in one place and remembered in another.
    static func configuration(pixelWidth: Int, pixelHeight: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, pixelWidth)
        cfg.height = max(1, pixelHeight)
        cfg.captureResolution = .best
        cfg.showsCursor = showsCursor

        // DO NOT REMOVE. This line looks removable and it is the only thing
        // making the colour picker honest.
        //
        // MEASURED (probe A15.1), capturing swatches whose sRGB values the
        // probe chose:
        //
        //   drew 255,0,0  -> read back 234, 52, 36  with the DEFAULT config
        //   drew 0,255,0  -> read back 116,251, 76  with the DEFAULT config
        //
        // Worst channel error 116 on the default, 1 with sRGB pinned. The
        // captured image's colour space is `<none>` by default. This display is
        // wider than sRGB and the default capture hands back display-native
        // values. A picker built on the default reports #EA3424 for a pixel
        // that is really #FF0000, nothing errors, and the user pastes the wrong
        // hex into a design tool and never finds out.
        cfg.colorSpaceName = CGColorSpace.sRGB
        return cfg
    }

    // MARK: - Error classification

    /// Turn any capture failure into something the UI can act on.
    ///
    /// MEASURED (probe A1). The assumption list predicted a silent black frame.
    /// It was wrong, and the correction is a simplification: ScreenCaptureKit
    /// fails loudly with
    ///
    ///   `SCStreamErrorDomain Code=-3801 "The user declined TCCs for
    ///    application, window, display capture"`
    ///
    /// so a missing grant is read from the ERROR, never from the pixels. The
    /// match is on the code alone. The domain string is
    /// `com.apple.ScreenCaptureKit.SCStreamErrorDomain` today, and pinning a
    /// domain string that Apple can reshape between SDKs would turn a clear
    /// "grant us permission" banner back into a generic failure.
    nonisolated static func classify(_ error: Error) -> CaptureError {
        if let already = error as? CaptureError { return already }
        let ns = error as NSError
        if ns.code == userDeclinedCode { return .noPermission }
        return .failed("\(ns.domain) \(ns.code)")
    }

    // MARK: - The secondary blank-frame signal

    /// Returns a reason when the frame looks like nothing, or nil when it looks
    /// like real content.
    ///
    /// This is NOT how the app detects a missing permission any more, see
    /// `classify`. It stays because it still covers a display that went to
    /// sleep and a content filter that excluded everything, and because those
    /// two produce a perfectly valid image full of nothing.
    ///
    /// It samples a 32x32 grid rather than every pixel. 1,024 samples tell a
    /// black frame from a desktop, and it reads the provider bytes directly
    /// instead of going through `ImageBridge`, because building a full
    /// `PixelBuffer` for a 2940x1912 capture would cost more than the capture.
    nonisolated static func blankFrameReason(_ image: CGImage) -> String? {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return "image is \(w)x\(h)" }
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
            return nil   // cannot tell, so do not claim it is blank
        }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        let steps = 32
        var distinct = Set<UInt32>()
        var lumaSum = 0.0
        for iy in 0..<steps {
            for ix in 0..<steps {
                let x = ix * (w - 1) / (steps - 1)
                let y = iy * (h - 1) / (steps - 1)
                let o = y * bytesPerRow + x * bytesPerPixel
                let c0 = Double(ptr[o]), c1 = Double(ptr[o + 1]), c2 = Double(ptr[o + 2])
                // Channel order does not matter for "is this black", so no
                // assumption about RGBA versus BGRA is made here.
                lumaSum += (c0 + c1 + c2) / (3 * 255)
                distinct.insert(UInt32(ptr[o]) << 16 | UInt32(ptr[o + 1]) << 8 | UInt32(ptr[o + 2]))
            }
        }
        let mean = lumaSum / Double(steps * steps)
        if distinct.count <= 1 && mean < 0.02 { return "all black" }
        if distinct.count <= 1 { return "uniform colour" }
        return nil
    }

    // MARK: - Coordinates

    /// `SCWindow.frame` is in global points with a TOP-LEFT origin, which is
    /// already the orientation `PixelRect` uses. Only the scale changes.
    nonisolated static func pixelRect(_ frame: CGRect, scale: CGFloat) -> PixelRect {
        PixelRect(x0: Int((frame.minX * scale).rounded()),
                  y0: Int((frame.minY * scale).rounded()),
                  x1: Int((frame.maxX * scale).rounded()),
                  y1: Int((frame.maxY * scale).rounded()))
    }

    private static func match(_ screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        return displays.first { $0.displayID == id }
    }

    /// The screen a top-left-origin global rect sits on.
    ///
    /// UNPROVEN (gap A7): this machine has one display. Multi-display mapping,
    /// mixed backing scale factors and a display with a negative origin are all
    /// unmeasured, and the failure mode is a selection on the second display
    /// capturing the wrong region of the first.
    private static func screen(containing frame: CGRect) -> NSScreen {
        guard let main = NSScreen.screens.first else { return NSScreen.main ?? NSScreen.screens[0] }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return main }
        // Convert the top-left-origin point back into Cocoa's bottom-left
        // global space so it can be compared against `NSScreen.frame`.
        let flippedY = primary.frame.maxY - frame.midY
        let point = CGPoint(x: frame.midX, y: flippedY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? primary
    }
}
