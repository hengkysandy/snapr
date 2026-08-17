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

    private var panel: NSPanel?
    private let heightLabel = NSTextField(labelWithString: "0 px")
    private let hintLabel = NSTextField(labelWithString: "Scroll the window you want to capture")

    func show(on screen: NSScreen) {
        let size = NSSize(width: 320, height: 92)
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
        // Only mentioned when it happens. A permanent "0 skipped" would make a
        // healthy run look like it was going wrong.
        hintLabel.stringValue = lost == 0
            ? "Scroll the window you want to capture"
            : "\(lost) frame\(lost == 1 ? "" : "s") skipped, keep scrolling slowly"
        hintLabel.textColor = lost == 0 ? .secondaryLabelColor : .systemOrange
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

        let buttons = NSStackView(views: [NSView(), cancel, done])
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
}
