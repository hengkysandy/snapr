import AppKit
import SnaprCore

/// A small panel that confirms something happened, and can be clicked to follow
/// up on it.
///
/// It exists because the app's two most useful actions now leave no window
/// behind. Saving closes the editor, and copying text opens nothing at all, so
/// without this both look exactly like a keystroke that did nothing.
///
/// It is a floating panel rather than a system notification on purpose. A system
/// notification needs a permission the user may never have granted, can be
/// silenced, and often appears seconds late. A confirmation that arrives after
/// the user has moved on is worse than none.
@MainActor
final class Toast {

    static let shared = Toast()

    /// How long it stays up. Long enough to read the detail and reach it with
    /// the mouse, short enough that it never feels like a dialogue to dismiss.
    static let duration: TimeInterval = 4

    struct Content {
        var title: String
        var detail: String
        var symbol: String
        var tint: NSColor
        /// Nil means there is nothing to follow up on, so the panel shows no
        /// arrow and no pointing hand. A receipt that looks clickable and is
        /// not is worse than one that plainly is not.
        var onClick: (() -> Void)?

        init(title: String, detail: String, symbol: String,
             tint: NSColor, onClick: (() -> Void)? = nil) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.tint = tint
            self.onClick = onClick
        }
    }

    /// Injected so a test can assert that a save receipt reveals the right file
    /// without opening a Finder window on the machine running the tests.
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private var panel: NSPanel?
    private var action: (() -> Void)?
    private var dismissal: DispatchWorkItem?

    var isShowing: Bool { panel != nil }

    // MARK: - The two receipts

    func showSaved(fileAt url: URL, on screen: NSScreen? = nil) {
        show(Content(title: "Saved to \(url.deletingLastPathComponent().lastPathComponent)",
                     // The folder, not the whole path. "Saved to
                     // /Users/someone/Downloads" is a mouthful that tells the
                     // user nothing they did not already know.
                     detail: url.lastPathComponent,
                     symbol: "checkmark.circle.fill",
                     tint: .systemGreen,
                     onClick: { [weak self] in self?.reveal(url) }),
             on: screen)
    }

    /// The result of a text grab, whether or not there was any text.
    ///
    /// A miss gets a receipt too. Silence after a keystroke reads as a broken
    /// shortcut, and the user needs to know the clipboard was left alone rather
    /// than filled with nothing.
    func showTextGrab(_ grab: TextGrab.Grab?, on screen: NSScreen? = nil) {
        let notice = TextGrab.notice(for: grab)
        show(Content(title: notice.title,
                     detail: notice.detail,
                     symbol: grab == nil ? "text.magnifyingglass" : "doc.on.clipboard.fill",
                     tint: grab == nil ? .systemOrange : .systemBlue),
             on: screen)
    }

    // MARK: - Showing

    func show(_ content: Content, on screen: NSScreen? = nil) {
        // A second receipt replaces the first rather than stacking. Two
        // overlapping panels would leave neither readable, and a click would
        // follow up on whichever happened to be on top.
        dismiss(animated: false)
        action = content.onClick

        let panel = makePanel(for: content)
        self.panel = panel
        position(panel, on: screen ?? NSScreen.main)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)

        // Paths and recognised text are the user's own business and never go
        // into a log, so only the fact of a receipt does.
        Log.app.info("receipt shown")
    }

    /// Follow up and put the receipt away. Internal rather than private so a
    /// test drives the same path the click does, instead of a copy of it.
    func activate() {
        guard let action else { return }
        action()
        dismiss(animated: false)
    }

    func dismiss(animated: Bool) {
        dismissal?.cancel()
        dismissal = nil
        guard let panel else { return }
        self.panel = nil
        self.action = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Building

    /// Wide enough for the sentence, capped so a long path cannot span the
    /// screen.
    ///
    /// MEASURED: at a fixed 340 points, "A Snapr window is covering that area.
    /// Close it and try again" came out as "A Snapr window is coveri...rea.
    /// Close it and try again". Middle truncation is right for a file path,
    /// where the two ends carry the meaning, and it is the worst possible
    /// choice for a sentence, where the middle does.
    private static func width(for content: Content) -> CGFloat {
        // The real labels, not an attributed-string estimate. MEASURED: the
        // estimate came out about 20 points short, because an `NSTextField`
        // carries padding of its own, and the toast still truncated.
        let detail = NSTextField(labelWithString: content.detail)
        detail.font = .systemFont(ofSize: 11)
        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        // The icon, the two 14 point insets, the 10 point gaps, and room for
        // the chevron when the receipt is clickable. Symbols are not square, so
        // the icon is allowed 30 rather than its 22 point size.
        let furniture: CGFloat = 14 + 30 + 10 + 14 + (content.onClick != nil ? 10 + 30 : 0)
        let text = max(detail.intrinsicContentSize.width, title.intrinsicContentSize.width)
        return min(max(340, ceil(text) + furniture), 560)
    }

    private func makePanel(for content: Content) -> NSPanel {
        let size = NSSize(width: Self.width(for: content), height: 60)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            // Non-activating, so the receipt never pulls focus
                            // away from whatever the user went back to.
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The app is a menu bar item with no windows of its own most of the
        // time, so without this the receipt would vanish the moment focus went
        // back to the app the user is actually working in.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = makeContent(content, size: size)
        return panel
    }

    private func makeContent(_ content: Content, size: NSSize) -> NSView {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: content.symbol,
                             accessibilityDescription: content.title)
        icon.contentTintColor = content.tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(labelWithString: content.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        // A filename is one long token, so without this it defines the panel's
        // width and pushes the whole thing off the screen.
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var views: [NSView] = [icon, text]
        if content.onClick != nil {
            let chevron = NSImageView()
            chevron.image = NSImage(systemSymbolName: "arrow.up.forward.app",
                                    accessibilityDescription: "Open")
            chevron.contentTintColor = .secondaryLabelColor
            views.append(chevron)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        guard content.onClick != nil else { return background }

        let click = ClickThroughView(frame: background.bounds)
        click.autoresizingMask = [.width, .height]
        click.onClick = { [weak self] in self?.activate() }
        click.toolTip = "Show in Finder"
        click.setAccessibilityRole(.button)
        click.setAccessibilityLabel("\(content.title). \(content.detail). Show in Finder")
        background.addSubview(click)
        return background
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // Top centre. Not the top RIGHT, which belongs to system notifications:
        // a receipt that lands under one is a receipt nobody reads.
        //
        // `visibleFrame` already excludes the menu bar and the notch, so this
        // sits below both rather than under them.
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.maxY - size.height - 20))
    }
}

/// A transparent lid that turns the whole panel into one button.
///
/// Sits above the labels, because an `NSTextField` swallows the click that
/// would otherwise reach the view behind it, and a receipt that only responds
/// on its margins feels broken.
@MainActor
private final class ClickThroughView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
