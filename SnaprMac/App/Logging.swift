import Foundation
import os

/// Logging, with the two rules that cost a debugging session on the previous app.
///
/// 1. **`NSLog` is useless on macOS 26.** It redacts its arguments as
///    `<private>` in unified logging even with `%{public}` specifiers, so every
///    diagnostic is unreadable and looks exactly like "nothing happened".
///    `os.Logger` with our own subsystem is the only thing that works.
/// 2. **Read it with `/usr/bin/log`, not `log`.** `log` is a zsh builtin, so
///    `log show ...` fails with "too many arguments", invisibly when stderr is
///    redirected. `./app logs` has the full path baked in.
enum Log {
    static let subsystem = "com.hengkysandy.snapr.mac"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}

/// The privacy rule, adopted from the previous app's learning docs and binding
/// from the first line of every file:
///
/// **Never log user content.** Not OCR text, not window titles, not clipboard
/// contents, not filenames the user chose. Log kinds, sizes, counts, durations
/// and error reasons. A diagnostic that prints what was on the user's screen is
/// a data leak with a helpful tone.
///
/// Use these helpers when the shape of a value is the useful part.
enum Redact {
    static func text(_ s: String?) -> String {
        guard let s else { return "nil" }
        return "<\(s.count) chars>"
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }

    static func ms(_ seconds: CFAbsoluteTime) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}
