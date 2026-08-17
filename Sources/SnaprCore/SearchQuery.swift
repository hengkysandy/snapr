import Foundation

/// Turns whatever the user typed into an FTS5 MATCH expression that cannot throw.
///
/// MEASURED (probe A13.6): **23 of 29 realistic inputs make FTS5 throw.** Every
/// query is already a bound parameter, so SQL injection was never the risk here.
/// FTS5 *expression parsing* is. A user typing a single apostrophe gets
/// `SQLITE_ERROR fts5: syntax error near "'"` and the search field breaks.
///
/// Inputs measured to throw: the empty string, a single space, `'`, `"`, an
/// unclosed quote, `*` alone, a leading `*`, `^`, `-` alone, `word -`, `- word`,
/// `col:`, `(`, `()`, bare `AND`, trailing `AND`, bare `NOT`, unclosed `NEAR`,
/// `%`, `_`, `\`, `{}`, and a null-ish string.
///
/// After sanitizing, the probe measured: **inputs that still throw: NONE**, and
/// the sanitizer still found the planted phrase in the oldest of 5000 rows.
///
/// This is not optional polish. It is the only thing between the search field
/// and a thrown error on an apostrophe.
public enum SearchQuery {

    /// The result of sanitizing. `.skip` is a real outcome, not a failure: an
    /// empty token list must mean "do not run a query", never "run an empty one".
    public enum Sanitized: Equatable, Sendable {
        case skip
        case match(String)

        public var expression: String? {
            if case .match(let s) = self { return s }
            return nil
        }
    }

    /// Split on non-alphanumerics, quote each token, and append `*` to the last
    /// token so search works as the user types.
    ///
    /// Quoting each token is what neutralises every operator: inside double
    /// quotes FTS5 treats `AND`, `NOT`, `NEAR`, `^`, `-` and `:` as literal
    /// text rather than syntax. Doubling any embedded quote is what stops a
    /// token from closing its own string.
    public static func sanitize(_ raw: String, prefixLastToken: Bool = true) -> Sanitized {
        let tokens = tokenize(raw)
        guard !tokens.isEmpty else { return .skip }

        var parts: [String] = []
        for (i, t) in tokens.enumerated() {
            let quoted = "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let isLast = i == tokens.count - 1
            // A prefix on a one-character token matches almost everything and
            // makes as-you-type feel broken rather than fast, but it is still
            // the correct behaviour: the user has only typed one character.
            parts.append(isLast && prefixLastToken ? quoted + "*" : quoted)
        }
        return .match(parts.joined(separator: " "))
    }

    /// Tokens are runs of letters, digits and marks. Everything else separates.
    ///
    /// Unicode-aware on purpose: `isLetter` covers non-Latin scripts, so OCR of
    /// a non-English screenshot is searchable. Emoji are not letters or digits,
    /// so they drop out, which the probe confirmed is harmless: the emoji case
    /// sanitized to `"button"*` and returned 3857 hits.
    public static func tokenize(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in raw {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        // A single very long token is not an error, it just matches nothing.
        // Measured: a 39-character nonsense token returned 0 hits, no throw.
        return out
    }

    /// A short, honest description of what a zero-result search means, given
    /// how much of the library has actually been indexed.
    ///
    /// This exists because of the bug shape A13 was written to rule out: a
    /// search that returns zero looks identical to a search over an index that
    /// is not built yet. The user has to be told which one happened.
    public static func emptyResultExplanation(pendingOCRCount: Int,
                                              failedOCRCount: Int,
                                              totalCount: Int) -> String {
        if totalCount == 0 {
            return "No screenshots yet."
        }
        if pendingOCRCount > 0 {
            let s = pendingOCRCount == 1 ? "screenshot is" : "screenshots are"
            return "No matches. \(pendingOCRCount) \(s) still being read for text."
        }
        if failedOCRCount > 0 {
            let s = failedOCRCount == 1 ? "screenshot" : "screenshots"
            return "No matches. Text could not be read from \(failedOCRCount) \(s)."
        }
        return "No matches."
    }
}
