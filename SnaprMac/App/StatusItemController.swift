import AppKit
import SnaprCore

/// The menu bar item. Snapr has no Dock icon (`LSUIElement` is true), so this
/// is the only way in when no window is open.
@MainActor
final class StatusItemController {

    private let item: NSStatusItem
    private let onAction: (HotkeyAction) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenAbout: () -> Void
    private let onQuit: () -> Void

    /// Set when Screen Recording is missing. The icon changes and the first
    /// menu entry becomes the fix, because an app that silently captures
    /// nothing is the failure this whole project is built to avoid.
    var permissionMissing: Bool = false {
        // Only rebuild when the value actually CHANGES. The permission poll
        // assigns every 5 seconds, and without this guard the whole menu was
        // being torn down and rebuilt on every tick. Found by reading the log
        // of the running app: the icon diagnostic repeated forever.
        didSet {
            guard permissionMissing != oldValue else { return }
            updateIcon()
            rebuildMenu()
        }
    }

    var onFixPermission: (() -> Void)?

    init(onAction: @escaping (HotkeyAction) -> Void,
         onOpenSettings: @escaping () -> Void,
         onOpenAbout: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onAction = onAction
        self.onOpenSettings = onOpenSettings
        self.onOpenAbout = onOpenAbout
        self.onQuit = onQuit
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        guard let button = item.button else {
            // A status item with no button is invisible, and an invisible menu
            // bar item is an app with no way in at all: Snapr has no Dock icon.
            // This has to be loud rather than a silent early return.
            Log.app.error("status item has no button, the menu bar icon will not appear")
            return
        }
        let name = permissionMissing ? "exclamationmark.triangle" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Snapr")
        if image == nil {
            // A nil image leaves a zero-width button, so the item is present
            // and completely invisible. Falling back to text is worse-looking
            // and infinitely better than nothing.
            Log.app.error("SF Symbol \(name, privacy: .public) did not resolve, falling back to a text title")
            button.title = "Snapr"
        }
        // Template mode, so the icon follows the menu bar's light or dark
        // appearance instead of staying one colour and looking wrong in one of
        // them.
        image?.isTemplate = true
        button.image = image
        button.toolTip = permissionMissing
            ? "Snapr cannot capture: Screen Recording is not granted"
            : "Snapr"
        Log.app.info("""
            status item icon=\(name, privacy: .public) \
            resolved=\(image != nil, privacy: .public) \
            visible=\(self.item.isVisible, privacy: .public) \
            buttonWidth=\(Int(button.frame.width), privacy: .public)
            """)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if permissionMissing {
            // Loud, first, and not dismissible. The banner the design calls for.
            let warning = NSMenuItem(title: "Screen Recording is not granted",
                                     action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            let fix = NSMenuItem(title: "Open Screen Recording settings...",
                                 action: #selector(fixPermission), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        let settings = SettingsStore.shared.settings
        for action in HotkeyAction.allCases {
            let entry = NSMenuItem(title: action.label,
                                   action: #selector(runAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action.rawValue
            // The shortcut is shown, not registered here. Registering it on the
            // menu item would make it work only while the menu is open, which
            // is a confusing half-working state.
            if let spec = settings.hotkeys[action] {
                entry.toolTip = spec.displayString
                let attr = NSMutableAttributedString(string: action.label)
                let shortcut = NSAttributedString(
                    string: "   \(spec.displayString)",
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                           weight: .regular),
                    ])
                attr.append(shortcut)
                entry.attributedTitle = attr
            }
            entry.isEnabled = !permissionMissing
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let about = NSMenuItem(title: "About Snapr", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Snapr", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    /// Called after the settings window changes a shortcut, so the menu shows
    /// the new one rather than the one from launch.
    func refresh() { rebuildMenu() }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = HotkeyAction(rawValue: raw) else { return }
        onAction(action)
    }

    @objc private func fixPermission() { onFixPermission?() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func openAbout() { onOpenAbout() }
    @objc private func quit() { onQuit() }
}
