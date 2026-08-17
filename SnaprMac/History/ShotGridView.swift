import AppKit
import SnaprCore

/// The reads the history grid needs, as plain closures.
///
/// It exists for one reason: the 30x mistake below has to be provable in a test
/// without a real encrypted library on disk. A struct of closures gives that
/// seam with no protocol, no existential and no `any` type.
struct ShotSource {
    var recent: (_ limit: Int, _ offset: Int) throws -> [Shot]
    var search: (_ rawQuery: String, _ limit: Int) throws -> [Shot]
    var thumbnailPNG: (_ id: UUID) throws -> Data
    var fullPNG: (_ id: UUID) throws -> Data
    var counts: () throws -> (total: Int, pending: Int, failed: Int)
    var diskBytes: () throws -> Int
    var delete: (_ id: UUID) throws -> Void
    /// Used by the settings window, which by contract is handed no library.
    var deleteAll: () throws -> Void
}

extension ShotSource {
    /// The real library. Every call is passed straight through, so the grid
    /// never gets to invent a fallback that hides a failure.
    static func live(_ library: Library) -> ShotSource {
        ShotSource(recent: { try library.recent(limit: $0, offset: $1) },
                   search: { try library.search($0, limit: $1) },
                   thumbnailPNG: { try library.thumbnailPNG(id: $0) },
                   fullPNG: { try library.fullPNG(id: $0) },
                   counts: { try library.counts() },
                   diskBytes: { try library.diskBytes() },
                   delete: { try library.delete(id: $0) },
                   deleteAll: { try library.deleteAll() })
    }
}

/// A scrolling grid of capture thumbnails.
@MainActor
final class ShotGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    enum Command {
        case open
        case copy
        case saveCopy
        case delete
    }

    var onCommand: ((Command, UUID) -> Void)?

    private let source: ShotSource
    private let scrollView = NSScrollView()
    private let collectionView = ShotGridCollectionView()
    private(set) var shots: [Shot] = []

    /// A collection view asks for the same tile again on every scroll pass, and
    /// each miss costs a file read plus an AES-GCM open plus a PNG decode. One
    /// small cache turns that into one read per shot per session.
    private let thumbCache = NSCache<NSUUID, NSImage>()

    init(source: ShotSource) {
        self.source = source
        super.init(frame: .zero)
        thumbCache.countLimit = 400
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ShotGridView is built in code only") }

    // MARK: - Data

    func setShots(_ newShots: [Shot]) {
        shots = newShots
        collectionView.reloadData()
        if !newShots.isEmpty && collectionView.selectionIndexPaths.isEmpty {
            select(index: 0)
        }
    }

    /// Forget one cached thumbnail. Called after a delete so a reused UUID can
    /// never show the wrong picture.
    func forgetThumbnail(id: UUID) {
        thumbCache.removeObject(forKey: id as NSUUID)
    }

    var selectedShotID: UUID? {
        guard let path = collectionView.selectionIndexPaths.first,
              path.item < shots.count else { return nil }
        return shots[path.item].id
    }

    func focusGrid() {
        window?.makeFirstResponder(collectionView)
        if collectionView.selectionIndexPaths.isEmpty && !shots.isEmpty {
            select(index: 0)
        }
    }

    private func select(index: Int) {
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    /// Load one tile's picture.
    ///
    /// MEASURED (probe A12): a stored thumbnail costs about 1 ms, decoding the
    /// full original costs 31 to 35 ms per tile, a 32x to 37x difference. About
    /// 16 thumbnails fit in one 16.7 ms frame either way, so this stays on the
    /// main thread and stays simple. `fullPNG` must never be called from here.
    func thumbnailImage(for id: UUID) -> NSImage? {
        if let cached = thumbCache.object(forKey: id as NSUUID) { return cached }
        do {
            let png = try source.thumbnailPNG(id)
            guard let cg = ImageBridge.image(from: png) else {
                // Decoding failed on bytes that decrypted cleanly, so the stored
                // thumbnail itself is bad. Say nothing about its contents.
                Log.library.error("thumbnail decode failed, \(Redact.bytes(png.count), privacy: .public)")
                return nil
            }
            let image = ImageBridge.nsImage(from: cg)
            thumbCache.setObject(image, forKey: id as NSUUID)
            return image
        } catch {
            // One bad tile must not blank the grid. The tile says so instead.
            Log.library.error("thumbnail load failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    // MARK: - UI

    private func buildUI() {
        let layout = NSCollectionViewFlowLayout()
        // Stored thumbnails are about 320 px on the long edge, so a tile wider
        // than that would upscale and look soft.
        layout.itemSize = NSSize(width: 200, height: 164)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.underPageBackgroundColor]
        collectionView.register(ShotGridItem.self,
                                forItemWithIdentifier: ShotGridItem.identifier)

        collectionView.onActivate = { [weak self] in self?.activateSelection() }
        collectionView.onDeleteKey = { [weak self] in self?.deleteSelection() }
        collectionView.onContextMenu = { [weak self] path in
            guard let self, path.item < self.shots.count else { return nil }
            return self.contextMenu(for: self.shots[path.item].id)
        }

        // NSCollectionView has no double-click delegate call, so the gesture is
        // added by hand and mapped back to an index path.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: collectionView)
        guard let path = collectionView.indexPathForItem(at: point),
              path.item < shots.count else { return }
        collectionView.selectionIndexPaths = [path]
        onCommand?(.open, shots[path.item].id)
    }

    private func activateSelection() {
        guard let id = selectedShotID else { return }
        onCommand?(.open, id)
    }

    private func deleteSelection() {
        guard let id = selectedShotID else { return }
        onCommand?(.delete, id)
    }

    private func contextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        // Deliberately no "Show in Finder": the blobs on disk are AES-GCM
        // sealed, so revealing them shows a file nothing can open.
        for (title, command) in [("Open", Command.open),
                                 ("Copy", Command.copy),
                                 ("Save a Copy...", Command.saveCopy)] {
            let item = NSMenuItem(title: title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuPayload(command: command, id: id)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete", action: #selector(runMenuCommand(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = MenuPayload(command: .delete, id: id)
        menu.addItem(delete)
        return menu
    }

    private final class MenuPayload: NSObject {
        let command: Command
        let id: UUID
        init(command: Command, id: UUID) {
            self.command = command
            self.id = id
        }
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        onCommand?(payload.command, payload.id)
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shots.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ShotGridItem.identifier, for: indexPath)
        guard let tile = item as? ShotGridItem, indexPath.item < shots.count else { return item }
        let shot = shots[indexPath.item]
        let image = thumbnailImage(for: shot.id)
        // A tile still being read must look like it is still being read, and a
        // tile whose picture would not load must not look like an empty slot.
        let badge: String? = image == nil ? "Preview unavailable"
            : (shot.ocrState == .done ? nil : shot.ocrState.label)
        tile.configure(caption: ShotGridItem.caption(for: shot), image: image, badge: badge)
        return tile
    }
}

/// The collection view itself, only to carry keyboard and right-click back out.
///
/// Arrow keys are not handled here on purpose: `NSCollectionView` already moves
/// the selection with them while it is selectable and first responder.
@MainActor
final class ShotGridCollectionView: NSCollectionView {

    var onActivate: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onContextMenu: ((IndexPath) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Carbon virtual key codes: 36 Return, 76 keypad Enter, 51 Delete,
        // 117 forward Delete.
        switch event.keyCode {
        case 36, 76: onActivate?()
        case 51, 117: onDeleteKey?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        // Right-clicking an unselected tile should act on that tile, which is
        // what every other Mac grid does.
        selectionIndexPaths = [path]
        return onContextMenu?(path)
    }
}

/// One tile.
@MainActor
final class ShotGridItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ShotGridItem")

    // NOT named `imageView` or `textField`. `NSCollectionViewItem` already
    // declares both, and shadowing them by accident does not compile.
    private let thumbView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    private static let captionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func caption(for shot: Shot) -> String {
        "\(captionFormatter.string(from: shot.createdAt))  \(shot.kind.label)"
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        root.layer?.borderWidth = 2
        root.layer?.borderColor = NSColor.clear.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumbView.layer?.cornerRadius = 4

        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = .systemFont(ofSize: 10)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.isHidden = true

        for sub in [thumbView, captionLabel, badgeLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            thumbView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            thumbView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            thumbView.heightAnchor.constraint(equalToConstant: 116),

            badgeLabel.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor),
            badgeLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 3),

            captionLabel.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor),
            captionLabel.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: 1)
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(caption: String, image: NSImage?, badge: String?) {
        captionLabel.stringValue = caption
        thumbView.image = image
        badgeLabel.stringValue = badge ?? ""
        badgeLabel.isHidden = badge == nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbView.image = nil
        badgeLabel.isHidden = true
    }
}
