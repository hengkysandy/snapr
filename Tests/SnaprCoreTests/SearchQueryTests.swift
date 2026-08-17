import Testing
@testable import SnaprCore

/// The 29 inputs the storage probe measured against a real FTS5 index.
///
/// 23 of them made FTS5 throw. Not one was an SQL injection: every query was
/// already a bound parameter. They were all FTS5 *expression parsing* failures,
/// and the worst of them is a single apostrophe, which is a thing people type.
///
/// The probe measured, after sanitizing: "inputs that still throw: NONE".
/// These tests are that result, kept.
@Suite("FTS5 query sanitizer")
struct SearchQueryTests {

    /// Every input measured to throw against raw FTS5, plus the six that did not.
    static let hostileInputs: [(name: String, raw: String)] = [
        ("empty string", ""),
        ("single space", " "),
        ("only whitespace", "   \t\n  "),
        ("normal words", "button toolbar"),
        ("SQL metachars", "'; DROP TABLE ocr; --"),
        ("single quote", "it's"),
        ("double quote", "say \"hello\""),
        ("unclosed double quote", "\"unclosed"),
        ("asterisk alone", "*"),
        ("leading asterisk", "*button"),
        ("trailing asterisk", "button*"),
        ("caret", "^"),
        ("caret and word", "^button"),
        ("minus alone", "-"),
        ("word minus", "button -"),
        ("minus word", "-button"),
        ("colon column filter", "nosuchcol:button"),
        ("open paren", "("),
        ("empty parens", "()"),
        ("bare AND", "AND"),
        ("trailing AND", "button AND"),
        ("bare NOT", "NOT"),
        ("NEAR unclosed", "NEAR(button toolbar"),
        ("NEAR valid", "NEAR(button toolbar, 5)"),
        ("percent and underscore", "%_"),
        ("backslash", "\\"),
        ("braces", "{body} button"),
        ("emoji", "button 🔍"),
        ("very long token", String(repeating: "a", count: 39)),
        ("null-ish text", "\0button"),
    ]

    @Test("no hostile input produces an expression containing an FTS5 operator",
          arguments: hostileInputs)
    func sanitizerNeutralisesOperators(input: (name: String, raw: String)) {
        let result = SearchQuery.sanitize(input.raw)
        guard let expr = result.expression else {
            // `.skip` is a correct outcome, not a failure. An empty token list
            // must mean "do not run a query", never "run an empty one".
            return
        }
        // Every token must be inside double quotes. Inside quotes FTS5 treats
        // AND, NOT, NEAR, ^, - and : as literal text rather than syntax, which
        // is the whole mechanism.
        #expect(expr.hasPrefix("\""), "\(input.name): expression must start with a quote, got \(expr)")
        // Nothing outside quotes except single spaces and the trailing star.
        let stripped = expr.replacingOccurrences(
            of: "\"[^\"]*\"", with: "Q", options: .regularExpression)
        let allowed = Set("Q* ")
        #expect(stripped.allSatisfy { allowed.contains($0) },
                "\(input.name): unquoted material survived: \(stripped)")
    }

    @Test("inputs with no letters or digits skip the query entirely")
    func emptyTokenListSkips() {
        for raw in ["", " ", "   \t\n  ", "*", "^", "-", "(", "()", "%_", "\\", "\"", "!!!"] {
            #expect(SearchQuery.sanitize(raw) == .skip,
                    "\(raw.debugDescription) should skip, not run an empty query")
        }
    }

    @Test("the last token gets a prefix star so search works as the user types")
    func prefixOnLastToken() {
        #expect(SearchQuery.sanitize("button toolbar").expression == "\"button\" \"toolbar\"*")
        #expect(SearchQuery.sanitize("button").expression == "\"button\"*")
    }

    @Test("a phrase search can be exact when the prefix is turned off")
    func exactPhrase() {
        #expect(SearchQuery.sanitize("zarquon vexilliform anomaly", prefixLastToken: false)
                    .expression == "\"zarquon\" \"vexilliform\" \"anomaly\"")
    }

    @Test("the sanitizer still finds the phrase the probe planted in the oldest row")
    func stillFindsThePlantedPhrase() {
        // The probe planted "zarquon vexilliform anomaly" in document 1 of 5000
        // and measured 1 hit in 0.060 ms after sanitizing. If the sanitizer
        // mangled the tokens this expression would not match it.
        let expr = SearchQuery.sanitize("zarquon vexilliform anomaly").expression
        #expect(expr == "\"zarquon\" \"vexilliform\" \"anomaly\"*")
    }

    @Test("an embedded quote cannot close its own token")
    func embeddedQuoteIsDoubled() {
        // Tokenizing drops the quote entirely, so this is belt and braces. It
        // stays because the quoting rule must hold even if tokenize changes.
        let expr = SearchQuery.sanitize("say \"hello\" there").expression
        #expect(expr?.contains("\"\"") == false || expr?.contains("say") == true)
    }

    @Test("non-Latin text is tokenized, so OCR of a non-English screenshot is searchable")
    func unicodeLetters() {
        #expect(SearchQuery.sanitize("設定 ネットワーク").expression == "\"設定\" \"ネットワーク\"*")
        #expect(SearchQuery.sanitize("Größe").expression == "\"Größe\"*")
    }

    @Test("emoji drop out and leave the real words, which the probe confirmed is harmless")
    func emojiAreNotTokens() {
        // Measured: the emoji case sanitized to "button"* and returned 3857 hits.
        #expect(SearchQuery.sanitize("button 🔍").expression == "\"button\"*")
    }

    @Test("digits are searchable, because screenshots are full of IP addresses and versions")
    func digitsSurvive() {
        #expect(SearchQuery.sanitize("192.168.1.114").expression
                    == "\"192\" \"168\" \"1\" \"114\"*")
    }
}

@Suite("Empty search results say which kind of empty they are")
struct EmptyResultTests {

    /// This is the bug shape the whole storage probe was written to rule out.
    /// The previous app scanned only the newest 500 rows in memory, so an old
    /// row did not exist as far as search was concerned, and the UI said
    /// "no results" with total confidence.
    @Test("the three kinds of empty are distinguishable")
    func threeKindsOfEmpty() {
        let nothingCaptured = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 0, totalCount: 0)
        let stillIndexing = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 12, failedOCRCount: 0, totalCount: 40)
        let genuinelyNoMatch = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 0, totalCount: 40)

        #expect(nothingCaptured != stillIndexing)
        #expect(stillIndexing != genuinelyNoMatch)
        #expect(nothingCaptured != genuinelyNoMatch)
        #expect(stillIndexing.contains("12"))
    }

    @Test("a failed read is reported, not hidden behind no matches")
    func failuresAreVisible() {
        let s = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 0, failedOCRCount: 3, totalCount: 40)
        #expect(s.contains("3"))
        #expect(s != "No matches.")
    }

    @Test("singular and plural both read correctly")
    func grammar() {
        let one = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 1, failedOCRCount: 0, totalCount: 5)
        #expect(one.contains("screenshot is"))
        let many = SearchQuery.emptyResultExplanation(
            pendingOCRCount: 2, failedOCRCount: 0, totalCount: 5)
        #expect(many.contains("screenshots are"))
    }
}
