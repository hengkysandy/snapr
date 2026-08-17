import Foundation

/// A global hotkey, as data.
///
/// MEASURED (probe A6) with `AXIsProcessTrusted() == false` confirmed in the
/// same run: `RegisterEventHotKey` returned noErr, a second registration of the
/// same combination was rejected with `-9878`, and the hotkey fired.
/// **Carbon global hotkeys need no Accessibility grant.** Snapr asks for Screen
/// Recording and nothing else.
///
/// The Carbon key codes are here rather than in the Mac shell because they are
/// pure data, and because a shortcut that displays as `Ctrl Shift 4` but
/// registers something else is a bug worth a unit test.
public struct HotkeySpec: Equatable, Hashable, Sendable, Codable {
    /// Carbon virtual key code (`kVK_ANSI_4` and friends).
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier bits, from <Carbon/Events.h>. Repeated here so SnaprCore
    // does not import Carbon and can still be tested with no AppKit present.
    public static let cmdKey: UInt32 = 0x0100
    public static let shiftKey: UInt32 = 0x0200
    public static let optionKey: UInt32 = 0x0800
    public static let controlKey: UInt32 = 0x1000

    /// Carbon virtual key codes for the keys Snapr binds by default.
    public enum Key {
        public static let one: UInt32 = 18
        public static let two: UInt32 = 19
        public static let three: UInt32 = 20
        public static let four: UInt32 = 21
        public static let five: UInt32 = 23
        public static let six: UInt32 = 22
        public static let h: UInt32 = 4
        public static let r: UInt32 = 15
        public static let t: UInt32 = 17
        public static let w: UInt32 = 13
    }

    /// The symbols macOS itself uses, in the order macOS uses them.
    /// Getting this order wrong is the kind of detail that makes an app feel
    /// foreign on the platform.
    public var displayString: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "\u{2303}" }   // ⌃
        if modifiers & Self.optionKey != 0 { s += "\u{2325}" }    // ⌥
        if modifiers & Self.shiftKey != 0 { s += "\u{21E7}" }     // ⇧
        if modifiers & Self.cmdKey != 0 { s += "\u{2318}" }       // ⌘
        s += Self.keyName(keyCode)
        return s
    }

    public static func keyName(_ code: UInt32) -> String {
        switch code {
        case Key.one: return "1"
        case Key.two: return "2"
        case Key.three: return "3"
        case Key.four: return "4"
        case Key.five: return "5"
        case Key.six: return "6"
        case Key.h: return "H"
        case Key.r: return "R"
        case Key.t: return "T"
        case Key.w: return "W"
        default: return "?"
        }
    }
}

/// Everything a hotkey can trigger.
public enum HotkeyAction: String, CaseIterable, Sendable, Codable {
    case captureArea
    case captureFullScreen
    case captureWindow
    case captureDelayed
    case captureText
    case captureScrolling
    case repeatLastArea
    case openHistory

    public var label: String {
        switch self {
        case .captureArea: return "Capture area"
        case .captureFullScreen: return "Capture full screen"
        case .captureWindow: return "Capture window"
        case .captureDelayed: return "Delayed capture (3s)"
        case .captureText: return "Copy text from area"
        // The same shortcut ends the run, because the app cannot hold the
        // keyboard while the user is scrolling another window.
        case .captureScrolling: return "Scrolling capture (press again to finish)"
        case .repeatLastArea: return "Repeat last area"
        case .openHistory: return "Open history"
        }
    }

    /// Defaults chosen not to collide.
    ///
    /// `Cmd Shift 3/4/5` belong to the macOS screenshot service and cannot be
    /// taken (registration would fail with `-9878`, the same error the probe
    /// measured for a double registration). Shottr's defaults use `Cmd Shift`
    /// too, and a user may well have both installed. `Ctrl Shift` is free on a
    /// stock system.
    public var defaultSpec: HotkeySpec {
        switch self {
        case .captureArea:
            return HotkeySpec(keyCode: HotkeySpec.Key.four,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .captureFullScreen:
            return HotkeySpec(keyCode: HotkeySpec.Key.three,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .captureWindow:
            return HotkeySpec(keyCode: HotkeySpec.Key.one,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .captureDelayed:
            return HotkeySpec(keyCode: HotkeySpec.Key.two,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .captureText:
            return HotkeySpec(keyCode: HotkeySpec.Key.t,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .captureScrolling:
            return HotkeySpec(keyCode: HotkeySpec.Key.five,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .repeatLastArea:
            return HotkeySpec(keyCode: HotkeySpec.Key.r,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        case .openHistory:
            return HotkeySpec(keyCode: HotkeySpec.Key.h,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        }
    }
}
