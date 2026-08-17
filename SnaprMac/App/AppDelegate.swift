import AppKit
import CryptoKit
import SnaprCore

/// Wires the pieces together and owns the capture flow. Everything it calls is
/// defined in `CONTRACTS.md`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let capture = CaptureEngine()
    private var hotkeys: HotkeyManager?
    private var statusItem: StatusItemController?
    private let overlay = OverlayController()

    private var library: Library?
    private var ocr: OCRService?

    private var editors: [ObjectIdentifier: EditorWindowController] = [:]
    private var historyWindow: HistoryWindowController?
    private var settingsWindow: SettingsWindowController?

    /// The last area the user selected, for "repeat last area". Stored per
    /// screen, because the same rectangle on another display is a different
    /// place. Only one display is testable on this machine, so this carries the
    /// same caveat as A7 in the design: the multi-display path is unproven.
    private var lastAreaRect: PixelRect?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launch \(SnaprVersion.displayString, privacy: .public)")

        statusItem = StatusItemController(
            onAction: { [weak self] action in self?.perform(action) },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenAbout: { [weak self] in self?.showAbout() },
            onQuit: { NSApp.terminate(nil) })
        statusItem?.onFixPermission = { [weak self] in
            self?.capture.openScreenRecordingSettings()
        }

        openLibrary()
        registerHotkeys()

        overlay.onFinish = { [weak self] outcome in
            self?.overlayFinished(outcome)
        }

        Task { @MainActor in
            // One throwaway capture. MEASURED: the cold first call is 49 ms
            // against a 13.4 ms median, so warming once is worth it and a
            // pre-warmed SCStream is not.
            await capture.warmUp()
            refreshPermissionState()
            requestPermissionOnFirstLaunch()
        }

        // TCC state can change while the app is running, and there is no
        // notification for it. Polling once every few seconds is cheap and it
        // is the only way the menu bar icon can be honest.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionState() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ocr?.stop()
        hotkeys?.unregisterAll()
        library?.close()
    }

    /// Menu bar apps have no windows to reopen, so this must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Library

    private func openLibrary() {
        do {
            try Paths.createIfNeeded()
            let key = try KeyStore.loadOrCreateKey()
            let lib = try Library(directory: Paths.support, key: key)
            library = lib
            let service = OCRService(library: lib)
            service.onFinished = { [weak self] _, _ in self?.historyWindow?.refresh() }
            if SettingsStore.shared.settings.enableOCR { service.start() }
            ocr = service
            let counts = try lib.counts()
            Log.library.info("library open, \(counts.total) shots, \(counts.pending) pending OCR")
        } catch {
            // A library that cannot open is not something to hide. Without it
            // there is no history and no search, which is most of the app.
            Log.library.error("library failed to open: \(String(describing: error), privacy: .public)")
            presentLibraryFailure(error)
        }
    }

    private func presentLibraryFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Snapr could not open its library"
        alert.informativeText = """
            Captures will still work, but nothing will be saved and search is \
            unavailable.

            \(String(describing: error))
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue without history")
        alert.runModal()
    }

    // MARK: - Permission

    /// Ask macOS for Screen Recording once, on the first launch that does not
    /// have it.
    ///
    /// Two reasons this is here rather than only on the first capture. An app
    /// that cannot do its one job should say so at launch, not when the user is
    /// already reaching for a shortcut. And macOS only puts an app in the
    /// Screen Recording list AFTER it has asked, so without this the user opens
    /// System Settings and finds nothing to switch on.
    ///
    /// Guarded by a flag, because asking on every launch is what makes people
    /// stop reading dialogs.
    private func requestPermissionOnFirstLaunch() {
        let key = "didRequestScreenRecording"
        guard !capture.hasPermission() else { return }
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Log.app.info("asking for Screen Recording for the first time")
        capture.requestPermission()
    }

    private func refreshPermissionState() {
        let granted = capture.hasPermission()
        if statusItem?.permissionMissing == granted {
            // `privacy: .public` is required even for a plain string literal.
            // MEASURED on the running app: without it this line logged
            // "permission is now <private>", which is the same redaction that
            // makes NSLog useless on macOS 26. A diagnostic that hides the one
            // word it exists to report is worse than no diagnostic.
            Log.app.info("screen recording permission is now \(granted ? "granted" : "missing", privacy: .public)")
        }
        statusItem?.permissionMissing = !granted
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let manager = hotkeys ?? HotkeyManager { [weak self] action in
            self?.perform(action)
        }
        hotkeys = manager
        manager.unregisterAll()
        let results = manager.register(SettingsStore.shared.settings.hotkeys)
        // A shortcut already taken by something else fails with -9878. Telling
        // the user is the whole point of returning the status: a shortcut that
        // silently does nothing is indistinguishable from a broken app.
        let failures = results.filter { $0.value != noErr }
        for (action, status) in failures {
            Log.hotkey.error("\(action.rawValue, privacy: .public) failed to register, OSStatus \(status)")
        }
        // Mark the offending rows red in the Shortcuts tab as well as alerting.
        // A collision with ANOTHER app cannot be detected any other way:
        // `Settings.conflicts` only sees collisions inside our own set, and the
        // system reports the rest as OSStatus -9878 at registration time.
        settingsWindow?.showRegistrationFailures(failures)
        if !failures.isEmpty {
            reportHotkeyFailures(failures)
        }
    }

    private func reportHotkeyFailures(_ failures: [HotkeyAction: OSStatus]) {
        let settings = SettingsStore.shared.settings
        let lines = failures.keys.sorted { $0.rawValue < $1.rawValue }.map { action in
            let shortcut = settings.hotkeys[action]?.displayString ?? "?"
            return "\(action.label): \(shortcut)"
        }
        let alert = NSAlert()
        alert.messageText = failures.count == 1
            ? "One shortcut could not be registered"
            : "\(failures.count) shortcuts could not be registered"
        alert.informativeText = """
            Something else on this Mac already owns these key combinations, so \
            they will do nothing. Pick different ones in Settings.

            \(lines.joined(separator: "\n"))
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    // MARK: - The capture flow

    private func perform(_ action: HotkeyAction) {
        Log.capture.info("action \(action.rawValue, privacy: .public)")
        guard capture.hasPermission() || action == .openHistory else {
            promptForPermission()
            return
        }
        switch action {
        case .captureArea:        beginAreaCapture(kind: .area)
        case .captureFullScreen:  captureWholeScreen()
        case .captureWindow:      captureFrontWindow()
        case .captureDelayed:     scheduleDelayedCapture()
        case .repeatLastArea:     repeatLastArea()
        case .openHistory:        showHistory()
        }
    }

    private func promptForPermission() {
        let alert = NSAlert()
        alert.messageText = "Snapr needs Screen Recording"
        alert.informativeText = """
            macOS will not let any app read the screen without this permission. \
            Snapr cannot capture anything until it is granted.

            After granting it, quit and reopen Snapr.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            capture.requestPermission()
            capture.openScreenRecordingSettings()
        }
    }

    /// Capture-first, then freeze.
    ///
    /// MEASURED (probe A4): capturing before the overlay appears gave the true
    /// desktop pixel rgb(12,13,17) with both our windows gone, where showing an
    /// overlay first and capturing through it leaked rgb(140,140,140). It was
    /// chosen over `SCContentFilter(excludingWindows:)` because it is correct
    /// by construction rather than by remembering a filter, and because it is
    /// the only way zoom, pixel measurement and colour picking can work at all.
    private func beginAreaCapture(kind: CaptureKind) {
        guard let screen = screenUnderCursor() else {
            Log.capture.error("no screen under the cursor")
            return
        }
        Task { @MainActor in
            do {
                let start = CFAbsoluteTimeGetCurrent()
                let frozen = try await capture.captureFullScreen(screen)
                guard let buffer = ImageBridge.pixelBuffer(from: frozen) else {
                    Log.capture.error("could not build a pixel buffer from the capture")
                    return
                }
                Log.capture.info("frozen frame \(frozen.width)x\(frozen.height) in \(Redact.ms(CFAbsoluteTimeGetCurrent() - start), privacy: .public)")
                pendingKind = kind
                pendingFrozen = frozen
                // Fetched AFTER the capture, so enumeration never delays the
                // freeze. The frame is already still by this point, so the
                // window list cannot drift out of step with what is on screen.
                let windows = await capture.windowFrames(on: screen)
                overlay.begin(frozen: frozen, buffer: buffer, screen: screen,
                              settings: SettingsStore.shared.settings,
                              windows: windows)
            } catch {
                report(captureError: error)
            }
        }
    }

    private var pendingFrozen: CGImage?
    private var pendingKind: CaptureKind = .area

    private func overlayFinished(_ outcome: OverlayOutcome) {
        guard let frozen = pendingFrozen else { return }
        pendingFrozen = nil
        switch outcome {
        case .cancelled:
            Log.overlay.info("selection cancelled")
        case .region(let rect):
            lastAreaRect = rect
            guard let cropped = ImageBridge.crop(frozen, to: rect) else {
                Log.overlay.error("crop produced nothing for a \(rect.width)x\(rect.height) region")
                return
            }
            finish(image: cropped, kind: pendingKind)
        }
    }

    private func captureWholeScreen() {
        guard let screen = screenUnderCursor() else { return }
        Task { @MainActor in
            do {
                let image = try await capture.captureFullScreen(screen)
                finish(image: image, kind: .fullScreen)
            } catch {
                report(captureError: error)
            }
        }
    }

    private func captureFrontWindow() {
        Task { @MainActor in
            do {
                guard let window = try await capture.frontmostWindow() else {
                    Log.capture.error("no frontmost window to capture")
                    return
                }
                let image = try await capture.captureWindow(id: window.id)
                finish(image: image, kind: .window, sourceApp: window.appName)
            } catch {
                report(captureError: error)
            }
        }
    }

    private func scheduleDelayedCapture() {
        // Three seconds, matching what the reference app offers. Long enough to
        // open a menu, short enough not to be forgotten about.
        Log.capture.info("delayed capture in 3 s")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginAreaCapture(kind: .delayed) }
        }
    }

    private func repeatLastArea() {
        guard let rect = lastAreaRect, let screen = screenUnderCursor() else {
            // No stored rectangle yet. Falling through to a normal area capture
            // is better than doing nothing, which reads as a broken shortcut.
            beginAreaCapture(kind: .area)
            return
        }
        Task { @MainActor in
            do {
                let full = try await capture.captureFullScreen(screen)
                guard let cropped = ImageBridge.crop(full, to: rect) else { return }
                finish(image: cropped, kind: .repeatArea)
            } catch {
                report(captureError: error)
            }
        }
    }

    // MARK: - What happens to a finished capture

    private func finish(image: CGImage, kind: CaptureKind, sourceApp: String? = nil) {
        let settings = SettingsStore.shared.settings
        if settings.playShutterSound { NSSound(named: "Grab")?.play() }

        let stored = store(image: image, kind: kind, sourceApp: sourceApp)

        switch settings.afterCapture {
        case .openEditor:
            openEditor(image: image, shotID: stored)
        case .copyToClipboard:
            copyToPasteboard(image)
        case .saveToDownloads:
            saveToDownloads(image)
        }
    }

    /// Insert into the encrypted library. Returns the shot id, or nil when the
    /// library is unavailable.
    @discardableResult
    private func store(image: CGImage, kind: CaptureKind, sourceApp: String?) -> UUID? {
        let settings = SettingsStore.shared.settings
        guard settings.keepHistory, let library else { return nil }
        guard let png = ImageBridge.pngData(from: image),
              let thumb = ImageBridge.thumbnail(from: image),
              let thumbPNG = ImageBridge.pngData(from: thumb) else {
            Log.library.error("could not encode a capture for storage")
            return nil
        }
        let shot = Shot(kind: kind,
                        size: PixelSize(width: image.width, height: image.height),
                        blobBytes: png.count,
                        ocrState: settings.enableOCR ? .pending : .noTextFound,
                        sourceApp: sourceApp)
        do {
            _ = try library.insert(shot, png: png, thumbnailPNG: thumbPNG)
            Log.library.info("stored \(image.width)x\(image.height), \(Redact.bytes(png.count), privacy: .public)")
            if settings.enableOCR { ocr?.enqueue(shot.id) }
            historyWindow?.refresh()
            return shot.id
        } catch {
            Log.library.error("insert failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func openEditor(image: CGImage, shotID: UUID?) {
        let controller = EditorWindowController(image: image, shotID: shotID,
                                                settings: SettingsStore.shared.settings)
        let key = ObjectIdentifier(controller)
        editors[key] = controller
        controller.onResult = { [weak self] result in
            switch result {
            case .copied: Log.editor.info("copied to pasteboard")
            case .saved: Log.editor.info("saved a plain PNG")
            case .closed, .discarded: self?.editors[key] = nil
            }
        }
        controller.show()
    }

    private func copyToPasteboard(_ image: CGImage) {
        guard let png = ImageBridge.pngData(from: image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // PNG first for anything modern, TIFF as well because a number of older
        // apps only look for TIFF and would otherwise paste nothing.
        pb.setData(png, forType: .png)
        pb.setData(ImageBridge.nsImage(from: image).tiffRepresentation, forType: .tiff)
        Log.app.info("copied \(Redact.bytes(png.count), privacy: .public) to the pasteboard")
    }

    private func saveToDownloads(_ image: CGImage) {
        guard let png = ImageBridge.pngData(from: image) else { return }
        let shot = Shot(kind: .area, size: PixelSize(width: image.width, height: image.height))
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(SaveName.suggested(for: shot))
        do {
            // A plain PNG on purpose. The library is encrypted, but a file the
            // user asked for is not the library.
            try png.write(to: url)
            Log.app.info("saved \(Redact.bytes(png.count), privacy: .public) to Downloads")
        } catch {
            Log.app.error("save failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Windows

    private func showHistory() {
        guard let library else {
            presentLibraryFailure(LibraryError.openFailed("the library is not open"))
            return
        }
        if historyWindow == nil {
            let controller = HistoryWindowController(library: library)
            controller.onOpen = { [weak self] id in self?.openStoredShot(id) }
            historyWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.show()
        historyWindow?.refresh()
    }

    private func openStoredShot(_ id: UUID) {
        guard let library else { return }
        do {
            let png = try library.fullPNG(id: id)
            guard let image = ImageBridge.image(from: png) else {
                Log.library.error("stored PNG for one shot did not decode")
                return
            }
            openEditor(image: image, shotID: id)
        } catch {
            // Never silently show nothing. AES-GCM turns a corrupted blob into
            // a thrown error precisely so it can be reported.
            Log.library.error("could not open a stored shot: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "That screenshot could not be opened"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(store: SettingsStore.shared, capture: capture)
            // The Library tab needs the real size on disk and a working
            // "delete everything" button. Without this the button stays
            // disabled, which reads as a broken control rather than as a
            // missing library.
            if let library { controller.library = .live(library) }
            controller.onHotkeysChanged = { [weak self] in
                self?.registerHotkeys()
                self?.statusItem?.refresh()
            }
            settingsWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.show()
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = SnaprVersion.displayString
        alert.informativeText = """
            A precision screenshot tool with a searchable, encrypted history.

            Captures never leave this Mac. Text recognition runs offline.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    /// The screen the pointer is on, which is the one the user means. Falls
    /// back to the main screen rather than returning nil, because a capture
    /// that does nothing is worse than a capture of the wrong display.
    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func report(captureError error: Error) {
        Log.capture.error("capture failed: \(String(describing: error), privacy: .public)")
        guard let captureError = error as? CaptureError else { return }
        switch captureError {
        case .noPermission:
            // MEASURED: ScreenCaptureKit fails loudly with SCStreamErrorDomain
            // -3801 rather than returning a silent black frame, so the app
            // always knows, and the user gets told rather than getting a black
            // rectangle.
            refreshPermissionState()
            promptForPermission()
        case .blankFrame(let reason):
            Log.capture.error("blank frame: \(reason, privacy: .public)")
        case .noDisplay, .failed:
            let alert = NSAlert()
            alert.messageText = "The capture failed"
            alert.informativeText = String(describing: captureError)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
