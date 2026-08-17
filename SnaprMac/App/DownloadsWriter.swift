import Foundation
import SnaprCore

/// Writes a plain PNG into the user's Downloads folder.
///
/// Shared by the "save to Downloads" capture action and by the editor's save
/// shortcut. Both name files by the same rule, so neither can overwrite what
/// the other just wrote. Neither of them asks the user for a name: the whole
/// point is that saving is one keystroke and then the window is gone.
///
/// The library is encrypted. What lands here is an ordinary PNG, because a file
/// the user asked for is not part of the library.
enum DownloadsWriter {

    /// Returns the URL actually written, which may not be the suggested name if
    /// that one was already taken.
    static func write(_ png: Data, suggested: String) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .downloadsDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
        let name = SaveName.deduplicated(suggested) {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        let url = dir.appendingPathComponent(name)
        // Atomic, because an interrupted write otherwise leaves a truncated PNG
        // that opens as a grey rectangle and looks like the app corrupted it.
        try png.write(to: url, options: .atomic)
        return url
    }
}
