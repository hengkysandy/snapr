import AppKit
import SnaprCore

/// The panel that stays on screen for the whole of a scroll capture.
///
/// It has to exist. The app cannot take the keyboard during a run, because the
/// window being scrolled needs it, so without something visible the user would
/// have no way to end the run and no sign that anything was being recorded.
///
/// It carries its own Done and Cancel buttons for the same reason: a click on a
/// non-activating panel works without the panel ever becoming key, so the app
/// underneath keeps the focus and stays scrollable throughout.
@MainActor
final class ScrollCaptureHUD {

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Asks to switch between scrolling by hand and letting the app do it.
    var onToggleDrive: (() -> Void)?

    private var panel: NSPanel?
    private let heightLabel = NSTextField(labelWithString: "0 px")
    private let hintLabel = NSTextField(labelWithString: "Scroll the window you want to capture")
    private let driveButton = NSButton()
    private var automatic = false

    func show(on screen: NSScreen) {
        let size = NSSize(width: 400, height: 92)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Above ordinary windows but below the menu bar, so it cannot hide a
        // menu the user opens while scrolling.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = makeContent(size: size)

        // Bottom centre, not top centre. The receipt panel lives at the top, and
        // more to the point a control that sits over the thing being captured
        // would be in the way for the whole run. The bottom of the screen is
        // usually below the window the user is scrolling.
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 60))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(height: Int, lost: Int) {
        heightLabel.stringValue = "\(height) px captured"
        // The skipped count is only mentioned when it happens. A permanent
        // "0 skipped" would make a healthy run look like it was going wrong.
        if lost > 0 {
            hintLabel.stringValue = automatic
                ? "\(lost) frame\(lost == 1 ? "" : "s") skipped"
                : "\(lost) frame\(lost == 1 ? "" : "s") skipped, keep scrolling slowly"
            hintLabel.textColor = .systemOrange
        } else {
            hintLabel.stringValue = automatic
                ? "Scrolling for you, stops at the end of the page"
                : "Scroll the window you want to capture"
            hintLabel.textColor = .secondaryLabelColor
        }
    }

    func setDrive(automatic: Bool) {
        self.automatic = automatic
        driveButton.title = automatic ? "I'll scroll" : "Auto scroll"
        driveButton.toolTip = automatic
            ? "Stop scrolling for me and let me scroll it myself"
            : "Let Snapr scroll the window (needs Accessibility permission)"
        update(height: currentHeight, lost: 0)
    }

    private var currentHeight: Int {
        Int(heightLabel.stringValue.split(separator: " ").first.flatMap { Int($0) } ?? 0)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makeContent(size: NSSize) -> NSView {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "record.circle",
                            accessibilityDescription: "Recording")
        dot.contentTintColor = .systemRed
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [heightLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let top = NSStackView(views: [dot, text])
        top.orientation = .horizontal
        top.spacing = 10

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.refusesFirstResponder = true

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.refusesFirstResponder = true
        // No `keyEquivalent` on either. The panel never becomes key, so a Return
        // set here would do nothing at all, and a button that looks like the
        // default and ignores Return is worse than one that plainly does not.

        driveButton.title = "Auto scroll"
        driveButton.bezelStyle = .rounded
        driveButton.refusesFirstResponder = true
        driveButton.target = self
        driveButton.action = #selector(driveTapped)

        let buttons = NSStackView(views: [driveButton, NSView(), cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let column = NSStackView(views: [top, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        return background
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func driveTapped() { onToggleDrive?() }
}
