import Foundation

/// What goes on the clipboard when the user asks for the text in a capture.
///
/// The recognition itself lives in the Mac shell, because it is Vision. What
/// belongs here is the decision about what the user actually gets, which is
/// where the surprises are: an empty result that silently replaces the
/// clipboard, or a QR payload appearing at the end of a page of prose.
public enum TextGrab {

    public struct Grab: Equatable, Sendable {
        public var text: String
        public var lines: Int
        public var characters: Int
        /// True when there was no readable text and this is barcode payloads
        /// instead. The receipt says so, because "text copied" would be a lie
        /// and the user would go looking for prose they never had.
        public var fromBarcode: Bool

        public init(text: String, lines: Int, characters: Int, fromBarcode: Bool) {
            self.text = text
            self.lines = lines
            self.characters = characters
            self.fromBarcode = fromBarcode
        }
    }

    /// Nil means there is nothing worth copying, and the caller must leave the
    /// clipboard alone.
    ///
    /// That last part matters. Recognition on a photograph or an empty desktop
    /// returns nothing, and writing that nothing to the clipboard would wipe
    /// whatever the user had already copied. Losing a clipboard to a keystroke
    /// that appeared to do nothing is a bad way to find out a feature failed.
    ///
    /// Barcodes are a **fallback**, not an addition. A QR code in a screenshot
    /// of a page is worth copying when the page has no text, and is an
    /// unexpected URL glued to the end of your paragraph when it does.
    public static func clipboard(text: String?, barcodes: [String] = []) -> Grab? {
        if let body = tidy(text) {
            return Grab(text: body,
                        lines: body.split(separator: "\n", omittingEmptySubsequences: false).count,
                        characters: body.count,
                        fromBarcode: false)
        }
        let payloads = barcodes.compactMap { tidy($0) }
        guard !payloads.isEmpty else { return nil }
        let body = payloads.joined(separator: "\n")
        return Grab(text: body,
                    lines: payloads.count,
                    characters: body.count,
                    fromBarcode: true)
    }

    /// The wording of the receipt. No recognised text ever appears in it: the
    /// counts say the grab worked without putting the user's screenshot back on
    /// their screen a second time.
    public static func notice(for grab: Grab?) -> (title: String, detail: String) {
        guard let grab else {
            return ("No text found", "Nothing was recognised there")
        }
        if grab.fromBarcode {
            return ("Barcode copied", plural(grab.lines, "code"))
        }
        return ("Text copied",
                "\(plural(grab.lines, "line")), \(plural(grab.characters, "character"))")
    }

    private static func tidy(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
