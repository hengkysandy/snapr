import Foundation

/// Everything the user can change. Plain values, so the whole preference model
/// is testable without `UserDefaults`.
public struct Settings: Equatable, Sendable, Codable {

    public enum AfterCapture: String, CaseIterable, Sendable, Codable {
        case openEditor
        case copyToClipboard
        case saveToDownloads

        public var label: String {
            switch self {
            case .openEditor: return "Open the editor"
            case .copyToClipboard: return "Copy to clipboard"
            case .saveToDownloads: return "Save to Downloads"
            }
        }
    }

    public var afterCapture: AfterCapture = .openEditor
    public var playShutterSound: Bool = true
    public var showCursorInCapture: Bool = false
    public var copyOnClose: Bool = false
    public var colourFormat: ColourFormat = .hexUppercase
    public var hotkeys: [HotkeyAction: HotkeySpec]
    public var launchAtLogin: Bool = false

    /// Keep captures in the encrypted library. Turning this off is a real
    /// choice, not a hidden one: the app then has no history and no search,
    /// which is most of what it is for.
    public var keepHistory: Bool = true
    /// 0 means keep everything.
    public var historyRetentionDays: Int = 0
    /// Run Vision OCR on every capture, in the background.
    public var enableOCR: Bool = true

    public var defaultAnnotationColour: SRGB = SRGB(r: 255, g: 59, b: 48)
    public var defaultLineWidth: Int = 4
    /// Starting size for a new text label, in image pixels. On a 2x capture
    /// this reads at about the size of body text in the window underneath.
    public var defaultFontSize: Int = 28
    /// Blur strength. Pixelation, not gaussian: MEASURED nowhere, but gaussian
    /// blur on text is reversible in principle and pixelation at a coarse block
    /// size is not, and this tool exists to hide things in screenshots.
    public var blurBlockSize: Int = 12

    public init() {
        var h: [HotkeyAction: HotkeySpec] = [:]
        for a in HotkeyAction.allCases { h[a] = a.defaultSpec }
        self.hotkeys = h
    }

    /// Give any action added since this file was written its default shortcut.
    ///
    /// `hotkeys` is a stored dictionary, so a settings file from an older build
    /// simply has no entry for a new action. Without this the new shortcut
    /// silently does nothing for everyone who has already run the app, which is
    /// exactly the people who would notice it was missing. A shortcut the user
    /// has already changed is never touched.
    public mutating func fillInMissingHotkeys() {
        for action in HotkeyAction.allCases where hotkeys[action] == nil {
            hotkeys[action] = action.defaultSpec
        }
    }

    /// Conflicts inside our own set. macOS conflicts cannot be detected here,
    /// they surface as a `-9878` registration failure, which the Mac shell
    /// reports to the user rather than swallowing.
    public var conflicts: [HotkeySpec: [HotkeyAction]] {
        var byspec: [HotkeySpec: [HotkeyAction]] = [:]
        for (action, spec) in hotkeys { byspec[spec, default: []].append(action) }
        return byspec.filter { $0.value.count > 1 }
    }
}
