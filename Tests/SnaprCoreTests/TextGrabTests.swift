import Foundation
import Testing
@testable import SnaprCore

/// What the user actually gets when they ask for the text in a capture.
///
/// The dangerous case here is not a wrong string. It is an EMPTY one silently
/// replacing whatever was already on the clipboard, after a keystroke that
/// looked like it did nothing.
@Suite("Text grab")
struct TextGrabTests {

    @Test("plain text comes back with its own counts")
    func plainText() throws {
        let grab = try #require(TextGrab.clipboard(text: "one\ntwo\nthree"))
        #expect(grab.text == "one\ntwo\nthree")
        #expect(grab.lines == 3)
        #expect(grab.characters == 13)
        #expect(grab.fromBarcode == false)
    }

    @Test("nothing recognised means the clipboard is left alone")
    func nothingFound() {
        #expect(TextGrab.clipboard(text: nil) == nil)
        #expect(TextGrab.clipboard(text: "") == nil)
        // Recognition on a photograph or an empty desktop returns whitespace
        // often enough that this is the real case, not a theoretical one.
        #expect(TextGrab.clipboard(text: "   \n\n  \t ") == nil)
    }

    @Test("surrounding whitespace is trimmed but the shape of the text is kept")
    func trimming() throws {
        let grab = try #require(TextGrab.clipboard(text: "\n  hello\nworld  \n\n"))
        #expect(grab.text == "hello\nworld")
        #expect(grab.lines == 2)
    }

    @Test("a barcode is a fallback, never an addition")
    func barcodeIsAFallback() throws {
        // With text, the QR payload stays out of it. Otherwise copying a page
        // of prose would silently glue a URL onto the end of it.
        let withText = try #require(TextGrab.clipboard(text: "some prose",
                                                       barcodes: ["https://example.com"]))
        #expect(withText.text == "some prose")
        #expect(withText.fromBarcode == false)

        // With no text it is the only useful thing in the picture.
        let onlyCode = try #require(TextGrab.clipboard(text: nil,
                                                       barcodes: ["https://example.com"]))
        #expect(onlyCode.text == "https://example.com")
        #expect(onlyCode.fromBarcode == true)
        #expect(onlyCode.lines == 1)
    }

    @Test("several barcodes come back one per line")
    func manyBarcodes() throws {
        let grab = try #require(TextGrab.clipboard(text: "  ", barcodes: ["a", "b", "c"]))
        #expect(grab.text == "a\nb\nc")
        #expect(grab.lines == 3)
        #expect(grab.fromBarcode == true)
    }

    @Test("an empty barcode payload is not a result")
    func emptyBarcode() {
        #expect(TextGrab.clipboard(text: nil, barcodes: ["", "  "]) == nil)
    }

    @Test("the receipt counts correctly and says when it found nothing")
    func wording() {
        let miss = TextGrab.notice(for: nil)
        #expect(miss.title == "No text found")

        let one = TextGrab.notice(for: TextGrab.clipboard(text: "x"))
        // Singular, because "1 lines, 1 characters" is the kind of detail that
        // makes an app feel unfinished.
        #expect(one.detail == "1 line, 1 character")

        let many = TextGrab.notice(for: TextGrab.clipboard(text: "ab\ncd"))
        #expect(many.detail == "2 lines, 5 characters")

        let code = TextGrab.notice(for: TextGrab.clipboard(text: nil, barcodes: ["x"]))
        #expect(code.title == "Barcode copied",
                "a barcode announced as text sends the user looking for prose")
    }

    @Test("the receipt never repeats the recognised text back")
    func noticeCarriesNoContent() {
        let secret = "hunter2 the password is on screen"
        let notice = TextGrab.notice(for: TextGrab.clipboard(text: secret))
        #expect(!notice.title.contains("hunter2"))
        #expect(!notice.detail.contains("hunter2"))
    }
}

@Suite("Settings upgrade")
struct SettingsUpgradeTests {

    /// The shape of a settings file written before an action existed.
    @Test("an action added after the settings file was written gets its default")
    func missingHotkeyIsFilledIn() throws {
        var old = Settings()
        old.hotkeys.removeValue(forKey: .captureText)
        #expect(old.hotkeys[.captureText] == nil)

        // Round trip through JSON, because that is what actually happens: the
        // stored file simply has no key for the new action.
        let data = try JSONEncoder().encode(old)
        var loaded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(loaded.hotkeys[.captureText] == nil,
                "the decoder invented an entry, so this test proves nothing")

        loaded.fillInMissingHotkeys()

        #expect(loaded.hotkeys[.captureText] == HotkeyAction.captureText.defaultSpec)
        #expect(loaded.hotkeys.count == HotkeyAction.allCases.count)
    }

    @Test("a shortcut the user already changed is never overwritten")
    func customShortcutSurvives() {
        var settings = Settings()
        let mine = HotkeySpec(keyCode: HotkeySpec.Key.six,
                              modifiers: HotkeySpec.cmdKey | HotkeySpec.optionKey)
        settings.hotkeys[.captureArea] = mine

        settings.fillInMissingHotkeys()

        #expect(settings.hotkeys[.captureArea] == mine,
                "filling in the gaps reset a shortcut the user had chosen")
    }

    @Test("every action has a default, and no two share one out of the box")
    func defaultsAreUsable() {
        let settings = Settings()
        #expect(settings.hotkeys.count == HotkeyAction.allCases.count)
        // A stock install with two actions on one shortcut means one of them
        // fails to register with -9878 and appears broken.
        #expect(settings.conflicts.isEmpty,
                "the new default collides with an existing one: \(settings.conflicts)")
    }
}
