import AppKit
import XCTest
@testable import SnaprMac
import SnaprCore

/// Tests for the receipt shown after a save.
///
/// The save panel used to be the thing that told the user where a file went.
/// Removing it made this the only signal, so "it silently shows nothing" and
/// "it silently reveals the wrong file" are both real failures now, and neither
/// is visible in a screenshot taken a second later.
@MainActor
final class ToastTests: XCTestCase {

    private var toast: Toast { Toast.shared }

    override func tearDown() {
        toast.dismiss(animated: false)
        toast.reveal = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        super.tearDown()
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/someone/Downloads").appendingPathComponent(name)
    }

    func testShowingPutsAPanelUp() {
        XCTAssertFalse(toast.isShowing)
        toast.showSaved(fileAt: url("Snapr a.png"))
        XCTAssertTrue(toast.isShowing)
    }

    func testClickingRevealsTheFileThatWasActuallySaved() {
        var revealed: [URL] = []
        toast.reveal = { revealed.append($0) }

        let target = url("Snapr 2026-08-17 at 12.00.00.png")
        toast.showSaved(fileAt: target)
        toast.activate()

        XCTAssertEqual(revealed, [target])
        // And it puts itself away, because leaving a receipt on screen after
        // its own Finder window has opened is a panel the user has to chase.
        XCTAssertFalse(toast.isShowing)
    }

    func testASecondSaveReplacesTheFirstReceiptRatherThanStacking() {
        var revealed: [URL] = []
        toast.reveal = { revealed.append($0) }

        toast.showSaved(fileAt: url("first.png"))
        toast.showSaved(fileAt: url("second.png"))
        toast.activate()

        // Two overlapping receipts would leave neither readable, and clicking
        // would reveal whichever one happened to be on top.
        XCTAssertEqual(revealed, [url("second.png")],
                       "the receipt still pointed at the previous file")
    }

    func testClickingWithNothingShowingDoesNothing() {
        var revealed: [URL] = []
        toast.reveal = { revealed.append($0) }

        toast.activate()

        XCTAssertEqual(revealed, [], "a stale click opened a Finder window anyway")
    }

    // MARK: - The text receipt

    func testATextGrabReportsWhatWasCopied() {
        toast.showTextGrab(TextGrab.clipboard(text: "one\ntwo"))

        let labels = labelStrings(in: NSApp.windows.compactMap { $0.contentView })
        XCTAssertTrue(labels.contains { $0 == "Text copied" }, "got: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("2 lines") }, "got: \(labels)")
    }

    func testAMissStillGetsAReceipt() {
        toast.showTextGrab(nil)

        // Silence after a keystroke reads as a broken shortcut. The user needs
        // to know the clipboard was left alone rather than filled with nothing.
        XCTAssertTrue(toast.isShowing, "a failed text grab said nothing at all")
        let labels = labelStrings(in: NSApp.windows.compactMap { $0.contentView })
        XCTAssertTrue(labels.contains { $0 == "No text found" }, "got: \(labels)")
    }

    func testATextReceiptIsNotClickable() {
        var revealed: [URL] = []
        toast.reveal = { revealed.append($0) }

        toast.showTextGrab(TextGrab.clipboard(text: "words"))
        toast.activate()

        // There is nothing to reveal for a clipboard grab, so the panel must
        // not offer to. A receipt that looks clickable and is not is worse than
        // one that plainly is not.
        XCTAssertEqual(revealed, [])
        XCTAssertTrue(toast.isShowing, "a text receipt dismissed itself on a dead click")
    }

    func testTheTextReceiptNeverShowsTheTextItself() {
        toast.showTextGrab(TextGrab.clipboard(text: "the password is hunter2"))

        // The whole point of the encrypted library is that screen contents stay
        // put. Painting them back onto the screen in a floating panel, over
        // whatever the user switched to, would undo that.
        let labels = labelStrings(in: NSApp.windows.compactMap { $0.contentView })
        XCTAssertFalse(labels.contains { $0.contains("hunter2") },
                       "the receipt repeated the recognised text back: \(labels)")
    }

    func testDismissingLeavesNoWindowBehind() {
        toast.showSaved(fileAt: url("Snapr a.png"))
        toast.dismiss(animated: false)
        XCTAssertFalse(toast.isShowing)

        // The panel must be gone from the app's window list too. A leaked
        // borderless panel is invisible and keeps the app alive.
        let leaked = NSApp.windows.contains {
            $0.isVisible && $0 is NSPanel && $0.title.isEmpty && $0.level == .floating
        }
        XCTAssertFalse(leaked, "the receipt panel outlived its dismissal")
    }

    func testTheReceiptSitsAtTheTopOfTheScreenAndClearOfTheMenuBar() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        toast.showSaved(fileAt: url("Snapr a.png"))
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible })

        let visible = screen.visibleFrame
        XCTAssertGreaterThan(panel.frame.midY, visible.midY,
                             "the receipt drifted out of the top half of the screen")
        // `visibleFrame` stops below the menu bar and the notch, so staying
        // inside it is what keeps the receipt readable on a notched Mac.
        XCTAssertLessThanOrEqual(panel.frame.maxY, visible.maxY,
                                 "the receipt ran up under the menu bar")
        XCTAssertEqual(panel.frame.midX, visible.midX, accuracy: 1,
                       "the receipt is not centred")
    }

    func testTheReceiptNamesTheFolderAndTheFile() {
        toast.showSaved(fileAt: url("Snapr 2026-08-17 at 12.00.00.png"))

        // Whatever is on screen has to contain both, or the receipt tells the
        // user a file was saved without telling them which or where.
        let labels = labelStrings(in: NSApp.windows.compactMap { $0.contentView })
        XCTAssertTrue(labels.contains { $0.contains("Downloads") },
                      "the receipt did not say which folder, got: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Snapr 2026-08-17 at 12.00.00.png") },
                      "the receipt did not name the file, got: \(labels)")
    }

    private func labelStrings(in views: [NSView]) -> [String] {
        var found: [String] = []
        for view in views {
            if let field = view as? NSTextField { found.append(field.stringValue) }
            found += labelStrings(in: view.subviews)
        }
        return found
    }
}
