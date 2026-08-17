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

@Suite("Annotation kinds and shortcuts")
struct AnnotationKindTests {

    /// The editor picks tools by single keypress, so a duplicate letter means
    /// one of the two tools is simply unreachable, and nothing would report it.
    @Test("every kind has a distinct shortcut")
    func shortcutsAreUnique() {
        let shortcuts = Annotation.Kind.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count,
                "duplicate shortcut in \(shortcuts)")
    }

    /// `x` is crop and `v` is select, both defined in the Mac target. The core
    /// cannot see them, so this test states the reservation instead. Counter
    /// took `c` from crop, which is exactly the kind of move that quietly
    /// steals a key from another tool.
    @Test("no kind uses a letter reserved by the editor's own tools")
    func reservedLettersAreFree() {
        let reserved: Set<String> = ["x", "v"]
        for kind in Annotation.Kind.allCases {
            #expect(!reserved.contains(kind.shortcut),
                    "\(kind.rawValue) uses \(kind.shortcut), which crop or select owns")
        }
    }

    @Test("the renamed tools keep the labels and keys the user asked for")
    func renames() {
        #expect(Annotation.Kind.box.label == "Rectangle")
        #expect(Annotation.Kind.box.shortcut == "r")
        #expect(Annotation.Kind.counter.label == "Counter")
        #expect(Annotation.Kind.counter.shortcut == "c")
    }

    @Test("a rectangle is border only unless it is asked to be filled")
    func fillStyleDefault() {
        let a = Annotation(kind: .box, from: PixelPoint(x: 0, y: 0),
                           to: PixelPoint(x: 10, y: 10))
        #expect(a.fillStyle == .stroke)
    }

    @Test("fill style survives the JSON round trip, so it is not lost on reload")
    func fillStyleCodable() throws {
        var a = Annotation(kind: .box, from: PixelPoint(x: 0, y: 0),
                           to: PixelPoint(x: 10, y: 10))
        a.fillStyle = .filled
        let back = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a))
        #expect(back.fillStyle == .filled)
        #expect(back == a)
    }

    @Test("both fill styles have a label a user can read")
    func fillStyleLabels() {
        #expect(Annotation.FillStyle.stroke.label == "Border only")
        #expect(Annotation.FillStyle.filled.label == "Filled")
        #expect(Annotation.FillStyle.allCases.count == 2)
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

    // Saving no longer asks for a name, so nothing else stands between two
    // saves in the same second and a file that quietly disappears.

    @Test("only text uses the size slider for a font size")
    func sizeControlPerKind() {
        for kind in Annotation.Kind.allCases {
            let expected: Annotation.SizeControl = kind == .text ? .fontSize : .lineWidth
            #expect(kind.sizeControl == expected,
                    "\(kind.rawValue) put the slider on the wrong number")
        }
    }

    @Test("the two size ranges do not overlap at the ends, so the labels differ")
    func sizeRangesAreDistinct() {
        let width = Annotation.SizeControl.lineWidth.range
        let font = Annotation.SizeControl.fontSize.range
        // A hairline and a marker for lines, and readable to headline for type.
        #expect(width.lowerBound == 1)
        #expect(width.upperBound >= 40)
        #expect(font.lowerBound >= 8, "type below 8 px is unreadable on a capture")
        #expect(font.upperBound > width.upperBound,
                "the text range has to reach further than the line range")
    }

    @Test("clamping keeps a value inside its own range")
    func sizeClamping() {
        #expect(Annotation.SizeControl.lineWidth.clamp(200) == 40)
        #expect(Annotation.SizeControl.lineWidth.clamp(0) == 1)
        #expect(Annotation.SizeControl.fontSize.clamp(200) == 160)
        #expect(Annotation.SizeControl.fontSize.clamp(1) == 10)
        // A value already inside comes back untouched.
        #expect(Annotation.SizeControl.fontSize.clamp(28) == 28)
    }

    @Test("a free name is used exactly as it is")
    func dedupLeavesAFreeNameAlone() {
        #expect(SaveName.deduplicated("Snapr a.png") { _ in false } == "Snapr a.png")
    }

    @Test("a taken name gets a number before the extension, not after it")
    func dedupNumbersBeforeTheExtension() {
        let taken: Set<String> = ["Snapr a.png"]
        let name = SaveName.deduplicated("Snapr a.png") { taken.contains($0) }
        #expect(name == "Snapr a 2.png")
        // The extension has to survive. "Snapr a.png 2" is not a PNG as far as
        // the Finder, Preview or any upload form is concerned.
        #expect(name.hasSuffix(".png"))
    }

    @Test("a run of taken names keeps counting rather than giving up")
    func dedupCountsPastTheFirstFreeNumber() {
        let taken: Set<String> = ["S.png", "S 2.png", "S 3.png", "S 4.png"]
        #expect(SaveName.deduplicated("S.png") { taken.contains($0) } == "S 5.png")
    }

    @Test("a name with no extension is still numbered")
    func dedupHandlesNoExtension() {
        let taken: Set<String> = ["Snapr"]
        #expect(SaveName.deduplicated("Snapr") { taken.contains($0) } == "Snapr 2")
    }

    @Test("a dotted folder name is not mistaken for an extension")
    func dedupUsesTheLastDot() {
        let taken: Set<String> = ["v1.2 shot.png"]
        #expect(SaveName.deduplicated("v1.2 shot.png") { taken.contains($0) }
                == "v1.2 shot 2.png")
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
