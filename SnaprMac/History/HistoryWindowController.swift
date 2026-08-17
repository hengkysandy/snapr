import AppKit
import SnaprCore

/// The searchable history window.
///
/// This window is the reason the app exists. The reference app has OCR and no
/// history, and its own public request list shows people keep asking for one.
///
/// Two measured numbers shape everything here:
///
/// - A stored thumbnail costs about 1 ms, decoding the full original costs 31
///   to 35 ms per tile (probe A12). The grid only ever reads thumbnails.
/// - The worst-case FTS5 query over 5000 documents is 2.0 ms (probe A13). So
///   search runs as the user types, with a light debounce and no spinner: at
///   2 ms a spinner would never be seen.
@MainActor
final class HistoryWindowController: NSWindowController, NSSearchFieldDelegate {

    /// The user double-clicked a shot, or pressed Return on it.
    var onOpen: ((UUID) -> Void)?

    private let source: ShotSource
    private let grid: ShotGridView
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let debouncer = SearchDebouncer()

    /// One page of results. Big enough that the window feels like the whole
    /// library, small enough that a first paint is not thousands of tiles.
    private let pageLimit = 500

    convenience init(library: Library) {
        self.init(source: .live(library))
    }

    init(source: ShotSource) {
        self.source = source
        self.grid = ShotGridView(source: source)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Snapr History"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SnaprHistoryWindow")
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)

        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HistoryWindowController is built in code only") }

    // MARK: - Public surface

    func show() {
        refresh()
        // A menu bar app (LSUIElement) is not frontmost when a hotkey fires, so
        // the window would open behind whatever the user was looking at.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    func refresh() {
        reloadDiskUsage()
        runQuery()
    }

    /// What is written over the grid right now, or nil when results are showing.
    /// Read by the tests, because "an error was shown" and "the grid went empty"
    /// have to be tellable apart from the outside as well as on screen.
    var visibleMessage: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }

        let content = HistoryContentView()
        content.onFindShortcut = { [weak self] in self?.focusSearchField() }
        content.onCancel = { [weak self] in self?.handleEscape() }

        searchField.placeholderString = "Search text in screenshots"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 4
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.onCommand = { [weak self] command, id in self?.perform(command, on: id) }

        content.addSubview(searchField)
        content.addSubview(statusLabel)
        content.addSubview(grid)
        content.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -12),

            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grid.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: grid.widthAnchor, constant: -80)
        ])

        window.contentView = content
    }

    private func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Escape clears the search first, and only closes once there is nothing
    /// left to clear. Closing straight away would throw away typing.
    private func handleEscape() {
        if searchField.stringValue.isEmpty {
            window?.performClose(nil)
        } else {
            searchField.stringValue = ""
            runQuery()
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        // MEASURED (probe A13): the worst query over 5000 documents is 2.0 ms,
        // so this debounce is not about speed. It only stops a fast typist from
        // queueing thirty queries for results nobody will read.
        debouncer.schedule { [weak self] in self?.runQuery() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            // Return or Down from the search field hands over to the grid, so
            // the keyboard path from typing to opening never needs the mouse.
            grid.focusGrid()
            return true
        default:
            return false
        }
    }

    private func runQuery() {
        let raw = searchField.stringValue
        do {
            let results: [Shot]
            // `Library.search` sanitizes for itself. This check only decides
            // which question to ask: text that sanitizes to nothing (say, a
            // lone apostrophe) is not a search, so the recent list is the
            // honest answer rather than "no matches".
            if case .skip = SearchQuery.sanitize(raw) {
                results = try source.recent(pageLimit, 0)
            } else {
                results = try source.search(raw, pageLimit)
            }
            grid.setShots(results)
            if results.isEmpty {
                showEmptyExplanation()
            } else {
                messageLabel.isHidden = true
            }
            Log.library.debug("history query: \(Redact.text(raw), privacy: .public), \(results.count, privacy: .public) results")
        } catch {
            // An empty grid where an error happened looks exactly like data
            // loss. The grid keeps whatever it had and the failure is stated.
            show(error: error, doing: "search the library")
        }
    }

    /// A zero-result search must never look like a library that is not indexed
    /// yet. That is the exact bug the previous app shipped: it searched only the
    /// newest 500 rows in memory, so an old row did not exist as far as search
    /// was concerned, and the UI said "no results" with total confidence.
    private func showEmptyExplanation() {
        do {
            let counts = try source.counts()
            messageLabel.stringValue = SearchQuery.emptyResultExplanation(
                pendingOCRCount: counts.pending,
                failedOCRCount: counts.failed,
                totalCount: counts.total)
            messageLabel.isHidden = false
        } catch {
            show(error: error, doing: "count the library")
        }
    }

    private func show(error: Error, doing what: String) {
        // The type name only. A library error can carry a query or a path, and
        // neither belongs in a log.
        Log.library.error("history failed to \(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
        messageLabel.stringValue = "Could not \(what).\n\(String(describing: error))"
        messageLabel.isHidden = false
    }

    private func reloadDiskUsage() {
        do {
            let counts = try source.counts()
            let bytes = try source.diskBytes()
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let noun = counts.total == 1 ? "screenshot" : "screenshots"
            statusLabel.stringValue = "\(counts.total) \(noun), \(size)"
        } catch {
            statusLabel.stringValue = "Library size unavailable"
            Log.library.error("disk usage failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Tile commands

    private func perform(_ command: ShotGridView.Command, on id: UUID) {
        switch command {
        case .open: onOpen?(id)
        case .copy: copyToPasteboard(id)
        case .saveCopy: saveCopy(id)
        case .delete: confirmDelete(id)
        }
    }

    private func copyToPasteboard(_ id: UUID) {
        do {
            let png = try source.fullPNG(id)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            Log.library.info("copied one shot, \(Redact.bytes(png.count), privacy: .public)")
        } catch {
            alert(error: error, doing: "copy that screenshot")
        }
    }

    /// An explicit save writes a plain PNG. The library is encrypted, but a file
    /// the user asked for is not the library.
    private func saveCopy(_ id: UUID) {
        guard let shot = grid.shots.first(where: { $0.id == id }), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = SaveName.suggested(for: shot)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let png = try self.source.fullPNG(id)
                try png.write(to: url)
                // The filename is the user's choice, so it is user content and
                // never appears in a log.
                Log.library.info("saved a copy, \(Redact.bytes(png.count), privacy: .public)")
            } catch {
                self.alert(error: error, doing: "save that screenshot")
            }
        }
    }

    private func confirmDelete(_ id: UUID) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this screenshot?"
        alert.informativeText = "It is removed from the library and cannot be recovered."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.source.delete(id)
                self.grid.forgetThumbnail(id: id)
                self.refresh()
                Log.library.info("deleted one shot")
            } catch {
                self.alert(error: error, doing: "delete that screenshot")
            }
        }
    }

    private func alert(error: Error, doing what: String) {
        Log.library.error("history failed to \(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Could not \(what)."
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// The window's content view, only so that two keys can be caught wherever the
/// focus happens to be.
@MainActor
final class HistoryContentView: NSView {

    var onFindShortcut: (() -> Void)?
    var onCancel: (() -> Void)?

    /// `performKeyEquivalent` walks the whole content view tree, so Cmd+F is
    /// caught even while the search field itself holds the focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFindShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape from anywhere below this view, including the grid.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Collapses a burst of keystrokes into one query.
///
/// MEASURED (probe A13): the worst-case query over 5000 documents is 2.0 ms, so
/// this is not a performance fix and there is deliberately no spinner. It only
/// stops a fast typist from queueing thirty queries whose results are thrown
/// away before anyone reads them.
@MainActor
final class SearchDebouncer {

    private var pending: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.12) {
        self.delay = delay
    }

    func schedule(_ block: @escaping @MainActor () -> Void) {
        pending?.cancel()
        // `asyncAfter` on the main queue always runs on the main thread, so the
        // isolation this assumes is real rather than assumed away.
        let item = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
