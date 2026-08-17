import Foundation
import Testing
@testable import SnaprCore

@Suite("Annotation stack")
struct AnnotationStackTests {

    func arrow(_ from: (Int, Int), _ to: (Int, Int)) -> Annotation {
        Annotation(kind: .arrow,
                   from: PixelPoint(x: from.0, y: from.1),
                   to: PixelPoint(x: to.0, y: to.1))
    }

    @Test("undo and redo walk the whole history")
    func undoRedo() {
        var s = AnnotationStack()
        #expect(!s.canUndo)
        s.add(arrow((0, 0), (10, 10)))
        s.add(arrow((20, 20), (30, 30)))
        #expect(s.annotations.count == 2)
        s.undo()
        #expect(s.annotations.count == 1)
        s.undo()
        #expect(s.annotations.isEmpty)
        #expect(!s.canUndo)
        s.redo(); s.redo()
        #expect(s.annotations.count == 2)
        #expect(!s.canRedo)
    }

    /// A drag fires a mouse-dragged event on every frame. Without an explicit
    /// interactive mode, a two-second drag becomes a hundred undo steps and the
    /// undo key stops being useful.
    @Test("a drag with 200 intermediate updates is ONE undo step")
    func dragIsOneUndoStep() {
        var s = AnnotationStack()
        s.add(arrow((0, 0), (10, 10)))
        let id = s.annotations[0].id

        s.beginInteractive()
        for i in 1...200 {
            var a = s.annotations[0]
            a.to = PixelPoint(x: 10 + i, y: 10 + i)
            s.updateInteractive(a)
        }
        #expect(s.annotations[0].to == PixelPoint(x: 210, y: 210))

        s.undo()
        #expect(s.annotations.count == 1)
        #expect(s.annotations[0].id == id)
        #expect(s.annotations[0].to == PixelPoint(x: 10, y: 10),
                "one undo must reverse the whole drag")
    }

    @Test("a new action after an undo clears the redo stack")
    func newActionClearsRedo() {
        var s = AnnotationStack()
        s.add(arrow((0, 0), (10, 10)))
        s.add(arrow((20, 20), (30, 30)))
        s.undo()
        #expect(s.canRedo)
        s.add(arrow((40, 40), (50, 50)))
        #expect(!s.canRedo, "redoing into a branch that no longer exists would be a data loss bug")
    }

    @Test("step counters number themselves and renumber after a delete")
    func counters() {
        var s = AnnotationStack()
        for _ in 0..<3 {
            s.add(Annotation(kind: .counter, from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 30, y: 30)))
        }
        #expect(s.annotations.map(\.counterValue) == [1, 2, 3])
        let second = s.annotations[1].id
        s.remove(id: second)
        #expect(s.annotations.map(\.counterValue) == [1, 2],
                "deleting step 2 of 3 must renumber, not leave a gap")
    }

    @Test("the topmost annotation wins a hit test, because that is what is visible")
    func topmostWins() {
        var s = AnnotationStack()
        s.add(Annotation(kind: .box, from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 100, y: 100)))
        s.add(Annotation(kind: .box, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 50)))
        let top = s.annotations[1].id
        #expect(s.hitTest(PixelPoint(x: 30, y: 30))?.id == top)
    }

    @Test("undo history is capped, so a long session does not grow without limit")
    func undoIsCapped() {
        var s = AnnotationStack()
        for i in 0..<200 { s.add(arrow((i, i), (i + 5, i + 5))) }
        var undos = 0
        while s.canUndo { s.undo(); undos += 1 }
        #expect(undos <= 64)
    }
}

@Suite("Annotation hit testing")
struct AnnotationHitTests {

    @Test("a thin arrow is still clickable, because a 4 px line is not a target")
    func arrowSlop() {
        let a = Annotation(kind: .arrow,
                           from: PixelPoint(x: 0, y: 0),
                           to: PixelPoint(x: 100, y: 0),
                           lineWidth: 4)
        #expect(a.hitTest(PixelPoint(x: 50, y: 0)))
        #expect(a.hitTest(PixelPoint(x: 50, y: 8)))
        #expect(!a.hitTest(PixelPoint(x: 50, y: 40)))
        // Past the end of the segment, not just off the infinite line.
        #expect(!a.hitTest(PixelPoint(x: 200, y: 0)))
    }

    @Test("a zero-length arrow does not divide by zero")
    func degenerateArrow() {
        let a = Annotation(kind: .arrow, from: PixelPoint(x: 50, y: 50), to: PixelPoint(x: 50, y: 50))
        #expect(a.hitTest(PixelPoint(x: 50, y: 50)))
        #expect(!a.hitTest(PixelPoint(x: 500, y: 500)))
    }

    @Test("translation moves both ends together")
    func translate() {
        var a = Annotation(kind: .arrow, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 20, y: 30))
        a.translate(dx: 5, dy: -5)
        #expect(a.from == PixelPoint(x: 15, y: 5))
        #expect(a.to == PixelPoint(x: 25, y: 25))
    }

    @Test("the bounding box is half-open like every other rect in the app")
    func boundingBox() {
        let a = Annotation(kind: .box, from: PixelPoint(x: 10, y: 20), to: PixelPoint(x: 30, y: 50))
        #expect(a.boundingBox == PixelRect.xywh(10, 20, 21, 31))
    }
}

@Suite("Settings")
struct SettingsTests {

    @Test("the defaults have no internal shortcut conflicts")
    func defaultsDoNotCollide() {
        #expect(Settings().conflicts.isEmpty)
    }

    @Test("a deliberate collision is detected")
    func collisionDetected() {
        var s = Settings()
        s.hotkeys[.openHistory] = s.hotkeys[.captureArea]
        let c = s.conflicts
        #expect(c.count == 1)
        #expect(c.values.first?.count == 2)
    }

    @Test("settings survive a JSON round trip, which is how they are persisted")
    func codableRoundTrip() throws {
        var s = Settings()
        s.afterCapture = .copyToClipboard
        s.blurBlockSize = 20
        s.colourFormat = .cssRGB
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        #expect(back == s)
    }

    @Test("every hotkey action has a default, so none can be unbound by accident")
    func everyActionBound() {
        let s = Settings()
        for a in HotkeyAction.allCases {
            #expect(s.hotkeys[a] != nil, "\(a.rawValue) has no default shortcut")
        }
    }

    /// The macOS screenshot service owns Cmd Shift 3, 4 and 5. Registering one
    /// of those fails with OSStatus -9878, the same error a double registration
    /// gives, and the failure is easy to miss.
    @Test("no default uses Command, which is where the collisions are")
    func defaultsAvoidCommand() {
        for a in HotkeyAction.allCases {
            #expect(a.defaultSpec.modifiers & HotkeySpec.cmdKey == 0,
                    "\(a.rawValue) uses Command, which collides with the system screenshot keys")
        }
    }

    @Test("shortcut display strings use the macOS modifier order")
    func displayOrder() {
        let spec = HotkeySpec(keyCode: HotkeySpec.Key.four,
                              modifiers: HotkeySpec.controlKey | HotkeySpec.shiftKey)
        #expect(spec.displayString == "\u{2303}\u{21E7}4")

        let all = HotkeySpec(keyCode: HotkeySpec.Key.h,
                             modifiers: HotkeySpec.cmdKey | HotkeySpec.shiftKey
                                      | HotkeySpec.optionKey | HotkeySpec.controlKey)
        #expect(all.displayString == "\u{2303}\u{2325}\u{21E7}\u{2318}H")
    }
}

@Suite("Shot records")
struct ShotTests {

    @Test("failed and noTextFound are distinguishable, because they mean different things")
    func failureStatesAreDistinct() {
        // One is a blank screenshot. The other is a bug to look at. Collapsing
        // them hides the bug behind a plausible explanation.
        #expect(OCRState.failed != OCRState.noTextFound)
        #expect(OCRState.failed.label != OCRState.noTextFound.label)
        #expect(OCRState.failed.isTerminal)
        #expect(OCRState.noTextFound.isTerminal)
        #expect(!OCRState.pending.isTerminal)
        #expect(!OCRState.running.isTerminal)
    }

    @Test("blob filenames are the UUID only, never derived from content")
    func filenamesLeakNothing() {
        // A filename built from OCR text would expose the screenshot's contents
        // to anything that can list the directory, which defeats the encryption.
        let shot = Shot(kind: .area, size: PixelSize(width: 100, height: 100),
                        ocrText: "sk-secret-token-value")
        #expect(shot.blobFilename == "\(shot.id.uuidString).snapr")
        #expect(!shot.blobFilename.contains("secret"))
    }

    @Test("a shot survives a JSON round trip")
    func codable() throws {
        let shot = Shot(kind: .window, size: PixelSize(width: 2940, height: 1912),
                        blobBytes: 1234, ocrState: .done, ocrText: "hello",
                        barcodePayloads: ["SNAPR"], sourceApp: "Finder")
        let back = try JSONDecoder().decode(Shot.self, from: JSONEncoder().encode(shot))
        #expect(back == shot)
    }

    @Test("the suggested save name is a sortable timestamp with no path separators")
    func saveName() {
        let shot = Shot(kind: .area, size: PixelSize(width: 10, height: 10))
        let name = SaveName.suggested(for: shot)
        #expect(name.hasPrefix("Snapr "))
        #expect(name.hasSuffix(".png"))
        #expect(!name.contains("/"), "a slash in a filename silently creates a directory path")
        #expect(!name.contains(":"), "a colon is a path separator in the Finder's eyes")
    }
}

@Suite("Version")
struct VersionTests {
    /// The version lives in three places. This test is what makes the suite
    /// fail when they drift, instead of the DMG filename quietly disagreeing
    /// with the About box.
    @Test("the core version matches project.yml")
    func versionsAgree() throws {
        let yml = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/SnaprCoreTests/AnnotationTests.swift", with: "project.yml"),
            encoding: .utf8)
        #expect(yml.contains("CFBundleShortVersionString: \"\(SnaprVersion.marketing)\""),
                "SnaprVersion.marketing is \(SnaprVersion.marketing) but project.yml disagrees")
        #expect(yml.contains("MARKETING_VERSION: \"\(SnaprVersion.marketing)\""))
    }
}
