import Foundation
import SnaprCore

/// `Settings` persisted as one JSON blob in `UserDefaults`.
///
/// One blob rather than a key per field, because the previous app's per-key
/// version drifted: adding a field meant remembering to add a read, a write and
/// a default in three places, and forgetting one produced a setting that
/// appeared to save and did not. `Codable` cannot forget.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let key = "settings.v1"
    private let defaults: UserDefaults

    private(set) var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            for observer in observers.values { observer(settings) }
        }
    }

    private var observers: [UUID: (Settings) -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           var decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            // A settings file written by an older build has no entry for an
            // action added since. Without this the new shortcut does nothing at
            // all for anyone who has run the app before.
            decoded.fillInMissingHotkeys()
            self.settings = decoded
        } else {
            self.settings = Settings()
        }
    }

    /// Mutate and persist in one call, so there is no way to change a setting
    /// and forget to save it.
    func update(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }

    @discardableResult
    func observe(_ block: @escaping (Settings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else {
            Log.app.error("settings failed to encode, change not persisted")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Where everything lives on disk.
///
/// The path is a locked decision. Changing it orphans the whole encrypted
/// library, because the AES-GCM blobs are found by name inside this directory
/// and nothing else points at them.
enum Paths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapr", isDirectory: true)
    }

    static var indexDB: URL { support.appendingPathComponent("index.db") }
    static var blobs: URL { support.appendingPathComponent("blobs", isDirectory: true) }
    static var thumbs: URL { support.appendingPathComponent("thumbs", isDirectory: true) }

    static func createIfNeeded() throws {
        for dir in [support, blobs, thumbs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
