import AppKit
import ApplicationServices

/// Scrolls a window on the user's behalf during a scrolling capture.
///
/// **This is the one feature in Snapr that needs the Accessibility grant.**
/// macOS only lets a process post synthetic scroll events if it is trusted for
/// Accessibility, and there is no way around that. Everything else in the app
/// works without it, including scrolling capture with the user's own fingers,
/// so this asks only when the user reaches for it and falls back rather than
/// nagging.
///
/// Nothing here reads the screen, reads other apps, or watches input. It posts
/// scroll events and nothing else. The grant allows far more than that, which
/// is exactly why it is opt in.
@MainActor
enum AutoScroller {

    /// Whether macOS will actually deliver our synthetic scrolls.
    ///
    /// Checked rather than assumed, because an untrusted process posts events
    /// that are silently dropped. The capture would then run, see a page that
    /// never moves, and stop with one screen and no explanation.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask for the grant. Shows the system dialogue the first time, and after
    /// that macOS stays silent, so the caller must not rely on this returning
    /// true to mean the user agreed.
    @discardableResult
    static func requestTrust() -> Bool {
        // The constant is spelled out rather than read from
        // `kAXTrustedCheckOptionPrompt`, which is a global `var` in the SDK and
        // so is not usable from concurrency-checked code. The string itself is
        // part of the public API and does not change.
        return AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Scroll down by a number of POINTS at a screen position.
    ///
    /// Pixel units rather than lines, because a line means a different distance
    /// in every app and the capture needs a distance it can predict. Negative
    /// moves the content up, which is what scrolling down does.
    static func scrollDown(points: Int, at position: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        // The pointer has to be over the window that should scroll. Scroll
        // events go to whatever is under the cursor, not to whatever has focus,
        // which is what lets this work while the app stays in the background.
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: position, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        let event = CGEvent(scrollWheelEvent2Source: source,
                            units: .pixel, wheelCount: 1,
                            wheel1: Int32(-points), wheel2: 0, wheel3: 0)
        event?.location = position
        event?.post(tap: .cghidEventTap)
    }
}
