import AppKit
import ServiceManagement
import SnaprCore

/// The settings window: General, Shortcuts and Library.
///
/// Every change goes through `SettingsStore.update { }`. That is the only path
/// that persists, so a direct write to a local copy is a setting that appears
/// to save and does not.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Called after any shortcut change, so the integrator can re-register and
    /// report back what the system said.
    var onHotkeysChanged: (() -> Void)?

    /// The library, set by the integrator after construction.
    ///
    /// The contract hands this window a `SettingsStore` and a `CaptureEngine`
    /// and no library, but the Library tab has to show the real size on disk
    /// and be able to empty it. Without this the size falls back to measuring
    /// the support directory and the delete button stays disabled, which is
    /// honest but not useful.
    var library: ShotSource? {
        didSet { refreshLibraryTab() }
    }

    private let store: SettingsStore
    private let capture: CaptureEngine

    // General
    private let afterCapturePopUp = NSPopUpButton()
    private let shutterCheck = NSButton(checkboxWithTitle: "Play a shutter sound", target: nil, action: nil)
    private let cursorCheck = NSButton(checkboxWithTitle: "Include the pointer in captures", target: nil, action: nil)
    private let copyOnCloseCheck = NSButton(checkboxWithTitle: "Copy to the clipboard when the editor closes", target: nil, action: nil)
    private let colourFormatPopUp = NSPopUpButton()
    private let launchCheck = NSButton(checkboxWithTitle: "Open Snapr at login", target: nil, action: nil)
    private let launchNote = NSTextField(labelWithString: "")
    private let colourWell = NSColorWell()
    private let lineWidthStepper = NSStepper()
    private let lineWidthLabel = NSTextField(labelWithString: "")
    private let blurStepper = NSStepper()
    private let blurLabel = NSTextField(labelWithString: "")

    // Shortcuts
    private var recorders: [HotkeyAction: HotkeyRecorderView] = [:]
    private var warningLabels: [HotkeyAction: NSTextField] = [:]

    // Library
    private let keepHistoryCheck = NSButton(checkboxWithTitle: "Keep every capture in the encrypted library", target: nil, action: nil)
    private let retentionPopUp = NSPopUpButton()
    private let ocrCheck = NSButton(checkboxWithTitle: "Read text from captures in the background", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let deleteAllButton = NSButton(title: "Delete All Screenshots...", target: nil, action: nil)

    private let retentionChoices: [(label: String, days: Int)] = [
        ("Keep everything", 0), ("7 days", 7), ("30 days", 30),
        ("90 days", 90), ("365 days", 365)
    ]

    init(store: SettingsStore, capture: CaptureEngine) {
        self.store = store
        self.capture = capture

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Snapr Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SnaprSettingsWindow")
        super.init(window: window)
        window.delegate = self

        buildUI()
        loadFromSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsWindowController is built in code only") }

    func show() {
        loadFromSettings()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The system's answer to a registration attempt, handed back by whoever
    /// owns the `HotkeyManager`. A collision with another app cannot be found
    /// any other way: it only exists as OSStatus `-9878` at registration time.
    func showRegistrationFailures(_ failures: [HotkeyAction: OSStatus]) {
        for action in HotkeyAction.allCases {
            guard let status = failures[action] else { continue }
            recorders[action]?.setWarning(true)
            warningLabels[action]?.stringValue = status == -9878
                ? "Already used by another app"
                : "Could not register (\(status))"
            warningLabels[action]?.isHidden = false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The user may have granted Screen Recording in System Settings and
        // come straight back, so the state is re-read rather than remembered.
        refreshPermissionState()
        refreshLaunchAtLogin()
        refreshLibraryTab()
    }

    // MARK: - Building

    private func buildUI() {
        guard let window else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        for (label, view) in [("General", buildGeneralTab()),
                              ("Shortcuts", buildShortcutsTab()),
                              ("Library", buildLibraryTab())] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }

        let content = NSView()
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window.contentView = content
    }

    private func buildGeneralTab() -> NSView {
        afterCapturePopUp.addItems(withTitles: Settings.AfterCapture.allCases.map(\.label))
        afterCapturePopUp.target = self
        afterCapturePopUp.action = #selector(afterCaptureChanged)

        colourFormatPopUp.addItems(withTitles: ColourFormat.allCases.map(\.rawValue))
        colourFormatPopUp.target = self
        colourFormatPopUp.action = #selector(colourFormatChanged)

        for (check, action) in [(shutterCheck, #selector(shutterChanged)),
                                (cursorCheck, #selector(cursorChanged)),
                                (copyOnCloseCheck, #selector(copyOnCloseChanged)),
                                (launchCheck, #selector(launchAtLoginChanged))] {
            check.target = self
            check.action = action
        }

        colourWell.target = self
        colourWell.action = #selector(annotationColourChanged)

        configure(stepper: lineWidthStepper, min: 1, max: 20, action: #selector(lineWidthChanged))
        configure(stepper: blurStepper, min: 4, max: 48, action: #selector(blurChanged))

        launchNote.font = .systemFont(ofSize: 11)
        launchNote.textColor = .secondaryLabelColor
        launchNote.isHidden = true

        let grid = NSGridView(views: [
            [label("After a capture:"), afterCapturePopUp],
            [NSGridCell.emptyContentView, shutterCheck],
            [NSGridCell.emptyContentView, cursorCheck],
            [NSGridCell.emptyContentView, copyOnCloseCheck],
            [label("Colour format:"), colourFormatPopUp],
            [NSGridCell.emptyContentView, launchCheck],
            [NSGridCell.emptyContentView, launchNote],
            [label("Annotation colour:"), colourWell],
            [label("Line width:"), stepperRow(lineWidthStepper, lineWidthLabel)],
            [label("Blur block size:"), stepperRow(blurStepper, blurLabel)]
        ])
        return wrap(grid)
    }

    private func buildShortcutsTab() -> NSView {
        var rows: [[NSView]] = []
        for action in HotkeyAction.allCases {
            let recorder = HotkeyRecorderView(spec: store.settings.hotkeys[action])
            recorder.onChange = { [weak self] spec in self?.hotkeyRecorded(action, spec) }
            recorder.onRejected = { [weak self] reason in self?.showRejection(action, reason) }
            recorders[action] = recorder

            let warning = NSTextField(labelWithString: "")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = .systemRed
            warning.isHidden = true
            warningLabels[action] = warning

            rows.append([label(action.label + ":"), recorder, warning])
        }
        let note = NSTextField(labelWithString: "Click a shortcut, then type the keys you want.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        rows.append([NSGridCell.emptyContentView, note, NSGridCell.emptyContentView])
        return wrap(NSGridView(views: rows))
    }

    private func buildLibraryTab() -> NSView {
        keepHistoryCheck.target = self
        keepHistoryCheck.action = #selector(keepHistoryChanged)
        ocrCheck.target = self
        ocrCheck.action = #selector(ocrChanged)

        retentionPopUp.addItems(withTitles: retentionChoices.map(\.label))
        retentionPopUp.target = self
        retentionPopUp.action = #selector(retentionChanged)

        permissionLabel.font = .systemFont(ofSize: 11)
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor

        let permissionButton = NSButton(title: "Open Screen Recording Settings",
                                        target: self,
                                        action: #selector(openScreenRecordingSettings))

        deleteAllButton.target = self
        deleteAllButton.action = #selector(deleteAllPressed)
        deleteAllButton.bezelColor = .systemRed

        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, keepHistoryCheck],
            [label("Keep for:"), retentionPopUp],
            [NSGridCell.emptyContentView, ocrCheck],
            [label("Screen Recording:"), permissionLabel],
            [NSGridCell.emptyContentView, permissionButton],
            [label("On disk:"), sizeLabel],
            [NSGridCell.emptyContentView, deleteAllButton]
        ])
        return wrap(grid)
    }

    // MARK: - Small builders

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func configure(stepper: NSStepper, min: Double, max: Double, action: Selector) {
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
    }

    private func stepperRow(_ stepper: NSStepper, _ valueLabel: NSTextField) -> NSView {
        let row = NSStackView(views: [valueLabel, stepper])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func wrap(_ grid: NSGridView) -> NSView {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18)
        ])
        return container
    }

    // MARK: - Loading

    private func loadFromSettings() {
        let settings = store.settings

        if let index = Settings.AfterCapture.allCases.firstIndex(of: settings.afterCapture) {
            afterCapturePopUp.selectItem(at: index)
        }
        shutterCheck.state = settings.playShutterSound ? .on : .off
        cursorCheck.state = settings.showCursorInCapture ? .on : .off
        copyOnCloseCheck.state = settings.copyOnClose ? .on : .off
        if let index = ColourFormat.allCases.firstIndex(of: settings.colourFormat) {
            colourFormatPopUp.selectItem(at: index)
        }
        let colour = settings.defaultAnnotationColour
        colourWell.color = NSColor(srgbRed: CGFloat(colour.r) / 255,
                                   green: CGFloat(colour.g) / 255,
                                   blue: CGFloat(colour.b) / 255,
                                   alpha: 1)
        lineWidthStepper.integerValue = settings.defaultLineWidth
        lineWidthLabel.stringValue = "\(settings.defaultLineWidth) px"
        blurStepper.integerValue = settings.blurBlockSize
        blurLabel.stringValue = "\(settings.blurBlockSize) px"

        for (action, recorder) in recorders {
            recorder.setSpec(settings.hotkeys[action])
        }
        refreshConflicts()

        keepHistoryCheck.state = settings.keepHistory ? .on : .off
        ocrCheck.state = settings.enableOCR ? .on : .off
        let retentionIndex = retentionChoices.firstIndex { $0.days == settings.historyRetentionDays }
        retentionPopUp.selectItem(at: retentionIndex ?? 0)
        retentionPopUp.isEnabled = settings.keepHistory

        refreshLaunchAtLogin()
        refreshPermissionState()
        refreshLibraryTab()
    }

    /// The real state, not the stored wish. `SMAppService` can refuse, and can
    /// sit in "waiting for the user to approve it", and a checkbox that shows
    /// what we asked for rather than what happened is a lie.
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchCheck.state = status == .enabled ? .on : .off
        switch status {
        case .requiresApproval:
            launchNote.stringValue = "Waiting for approval in System Settings, Login Items."
            launchNote.isHidden = false
        case .notFound:
            launchNote.stringValue = "macOS cannot see this copy of Snapr yet. Move it to Applications."
            launchNote.isHidden = false
        default:
            launchNote.isHidden = true
        }
    }

    private func refreshPermissionState() {
        // Say what is true. A generic "grant permissions" line shown to someone
        // who already granted it is how a working app looks broken.
        if capture.hasPermission() {
            permissionLabel.stringValue = "Granted. Snapr can capture the screen."
            permissionLabel.textColor = .secondaryLabelColor
        } else {
            permissionLabel.stringValue = "Not granted. Captures will fail until it is."
            permissionLabel.textColor = .systemRed
        }
    }

    private func refreshLibraryTab() {
        deleteAllButton.isEnabled = library != nil
        do {
            let bytes = try library?.diskBytes() ?? Self.measureSupportDirectory()
            sizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } catch {
            sizeLabel.stringValue = "Unavailable"
            Log.library.error("settings could not read the library size: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Fallback when no library has been handed over. It adds up the same files
    /// the library would: the index and both sealed blob directories.
    private static func measureSupportDirectory() -> Int {
        let manager = FileManager.default
        var total = 0
        for directory in [Paths.blobs, Paths.thumbs] {
            let contents = (try? manager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in contents {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        total += (try? Paths.indexDB.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return total
    }

    // MARK: - General actions

    @objc private func afterCaptureChanged() {
        let index = afterCapturePopUp.indexOfSelectedItem
        guard index >= 0, index < Settings.AfterCapture.allCases.count else { return }
        let choice = Settings.AfterCapture.allCases[index]
        store.update { $0.afterCapture = choice }
    }

    @objc private func shutterChanged() {
        let on = shutterCheck.state == .on
        store.update { $0.playShutterSound = on }
    }

    @objc private func cursorChanged() {
        let on = cursorCheck.state == .on
        store.update { $0.showCursorInCapture = on }
    }

    @objc private func copyOnCloseChanged() {
        let on = copyOnCloseCheck.state == .on
        store.update { $0.copyOnClose = on }
    }

    @objc private func colourFormatChanged() {
        let index = colourFormatPopUp.indexOfSelectedItem
        guard index >= 0, index < ColourFormat.allCases.count else { return }
        let format = ColourFormat.allCases[index]
        store.update { $0.colourFormat = format }
    }

    @objc private func annotationColourChanged() {
        // The well can hand back a colour in any space. Converting to sRGB is
        // what keeps the stored value the same colour the user picked.
        guard let converted = colourWell.color.usingColorSpace(.sRGB) else { return }
        let colour = SRGB(r: Int((converted.redComponent * 255).rounded()),
                          g: Int((converted.greenComponent * 255).rounded()),
                          b: Int((converted.blueComponent * 255).rounded()))
        store.update { $0.defaultAnnotationColour = colour }
    }

    @objc private func lineWidthChanged() {
        let width = lineWidthStepper.integerValue
        lineWidthLabel.stringValue = "\(width) px"
        store.update { $0.defaultLineWidth = width }
    }

    @objc private func blurChanged() {
        let size = blurStepper.integerValue
        blurLabel.stringValue = "\(size) px"
        store.update { $0.blurBlockSize = size }
    }

    @objc private func launchAtLoginChanged() {
        let wanted = launchCheck.state == .on
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            store.update { $0.launchAtLogin = wanted }
        } catch {
            Log.app.error("launch at login change failed: \(String(describing: type(of: error)), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Could not change the login item."
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
        // Whether it worked or not, the checkbox now shows the real state.
        refreshLaunchAtLogin()
    }

    // MARK: - Shortcut actions

    private func hotkeyRecorded(_ action: HotkeyAction, _ spec: HotkeySpec) {
        store.update { $0.hotkeys[action] = spec }
        refreshConflicts()
        // The integrator re-registers and can hand back a `-9878`, which is the
        // only way a collision with another app can ever be known.
        onHotkeysChanged?()
    }

    private func showRejection(_ action: HotkeyAction, _ reason: String) {
        warningLabels[action]?.stringValue = reason
        warningLabels[action]?.isHidden = false
    }

    /// Collisions inside our own set. Anything owned by another app on this Mac
    /// is invisible here and only appears as a registration failure.
    private func refreshConflicts() {
        let conflicts = store.settings.conflicts
        let clashing = Set(conflicts.values.flatMap { $0 })
        for action in HotkeyAction.allCases {
            let isClashing = clashing.contains(action)
            recorders[action]?.setWarning(isClashing)
            if isClashing {
                warningLabels[action]?.stringValue = "Used by another Snapr shortcut"
                warningLabels[action]?.isHidden = false
            } else {
                warningLabels[action]?.isHidden = true
            }
        }
    }

    // MARK: - Library actions

    @objc private func keepHistoryChanged() {
        let on = keepHistoryCheck.state == .on
        store.update { $0.keepHistory = on }
        retentionPopUp.isEnabled = on
    }

    @objc private func ocrChanged() {
        let on = ocrCheck.state == .on
        store.update { $0.enableOCR = on }
    }

    @objc private func retentionChanged() {
        let index = retentionPopUp.indexOfSelectedItem
        guard index >= 0, index < retentionChoices.count else { return }
        let days = retentionChoices[index].days
        store.update { $0.historyRetentionDays = days }
    }

    @objc private func openScreenRecordingSettings() {
        capture.openScreenRecordingSettings()
    }

    @objc private func deleteAllPressed() {
        guard let library, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete every screenshot?"
        alert.informativeText = "The whole library is erased. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Everything")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try library.deleteAll()
                Log.library.info("library emptied by the user")
            } catch {
                Log.library.error("delete all failed: \(String(describing: type(of: error)), privacy: .public)")
                let failure = NSAlert()
                failure.messageText = "The library could not be emptied."
                failure.informativeText = String(describing: error)
                failure.alertStyle = .warning
                failure.runModal()
            }
            self.refreshLibraryTab()
        }
    }
}
