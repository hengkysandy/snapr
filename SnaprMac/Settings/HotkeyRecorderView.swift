import AppKit
import Carbon.HIToolbox
import SnaprCore

/// A one-line control that records a key combination.
///
/// It records Carbon virtual key codes and Carbon modifier bits, because that
/// is what `RegisterEventHotKey` takes and what `HotkeySpec` stores. An
/// `NSEvent.keyCode` is already a Carbon virtual key code, so no translation
/// table is needed. The modifier flags do need translating.
@MainActor
final class HotkeyRecorderView: NSView {

    /// The user recorded a new, valid combination.
    var onChange: ((HotkeySpec) -> Void)?
    /// The last key press was refused, and this says why in plain words.
    var onRejected: ((String) -> Void)?

    private(set) var spec: HotkeySpec?
    private var isRecording = false
    private var hasWarning = false

    init(spec: HotkeySpec?) {
        self.spec = spec
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HotkeyRecorderView is built in code only") }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

    func setSpec(_ newSpec: HotkeySpec?) {
        spec = newSpec
        needsDisplay = true
    }

    /// Mark this shortcut as a problem. Two different problems land here:
    /// a collision inside our own set, found by `Settings.conflicts`, and a
    /// collision with something else on the Mac, which cannot be detected at
    /// all until `RegisterEventHotKey` fails with OSStatus `-9878`. The text
    /// itself is shown by the row beside this control.
    func setWarning(_ on: Bool) {
        hasWarning = on
        needsDisplay = true
    }

    // MARK: - Recording

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)

        // A global hotkey with no modifier would swallow that key everywhere on
        // the Mac, including inside other people's text fields.
        guard modifiers != 0 else {
            onRejected?("Hold \u{2318}, \u{2325}, \u{2303} or \u{21E7} as well.")
            return
        }
        // `HotkeySpec.keyName` only names the keys the core knows about, and a
        // shortcut that displays as "?" is worse than no shortcut at all.
        guard HotkeySpec.keyName(keyCode) != "?" else {
            onRejected?("That key is not supported yet. Try 1 to 6, H, R or W.")
            return
        }
        // Cmd Shift 3, 4 and 5 belong to the macOS screenshot service. They can
        // be recorded and then simply never fire, so refuse them here.
        let cmdShift = HotkeySpec.cmdKey | HotkeySpec.shiftKey
        let screenshotKeys: [UInt32] = [HotkeySpec.Key.three, HotkeySpec.Key.four, HotkeySpec.Key.five]
        if modifiers == cmdShift && screenshotKeys.contains(keyCode) {
            onRejected?("macOS uses that for its own screenshots.")
            return
        }

        let recorded = HotkeySpec(keyCode: keyCode, modifiers: modifiers)
        spec = recorded
        hasWarning = false
        stopRecording()
        onChange?(recorded)
    }

    /// Modifier-only presses must not end recording, they just redraw.
    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    /// `NSEvent.ModifierFlags` and the Carbon bits are different numbers for the
    /// same four keys. Getting this mapping wrong produces a shortcut that
    /// displays correctly and registers something else.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= HotkeySpec.cmdKey }
        if flags.contains(.shift) { out |= HotkeySpec.shiftKey }
        if flags.contains(.option) { out |= HotkeySpec.optionKey }
        if flags.contains(.control) { out |= HotkeySpec.controlKey }
        return out
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()

        if isRecording {
            NSColor.controlAccentColor.setStroke()
        } else if hasWarning {
            NSColor.systemRed.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let title: String
        if isRecording {
            title = "Type a shortcut"
        } else if let spec {
            title = spec.displayString
        } else {
            title = "None"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = title.size(withAttributes: attributes)
        let origin = NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
        title.draw(at: origin, withAttributes: attributes)
    }
}
