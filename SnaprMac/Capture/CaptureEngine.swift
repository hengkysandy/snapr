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
        let displays = try await shareableDisplays()
        guard let display = Self.match(screen, in: displays) ?? displays.first else {
            throw CaptureError.noDisplay
        }
        let scale = Int(screen.backingScaleFactor.rounded())
        let cfg = Self.configuration(pixelWidth: display.width * scale,
                                     pixelHeight: display.height * scale,
                                     showsCursor: SettingsStore.shared.settings.showCursorInCapture)
        let filter = SCContentFilter(display: display, excludingWindows: [])

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
            fullScreen \(image.width, privacy: .public)x\(image.height, privacy: .public) \
            in \(Redact.ms(CFAbsoluteTimeGetCurrent() - started), privacy: .public)
            """)
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
