import AppKit
import CoreGraphics
import XCTest
@testable import SnaprMac
import SnaprCore

/// Tests for the editor's rendering and its coordinate maths.
///
/// Everything here runs against synthetic images and asserts on real pixel
/// values. "It did not crash" is not a result: a flatten that silently exports
/// at the on-screen zoom, or a conversion that is off by one at 0.5x, both look
/// perfectly healthy right up to the moment someone opens the file.
@MainActor
final class EditorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a synthetic sRGB image from a closure over top-left pixel
    /// coordinates.
    private func makeImage(width: Int, height: Int,
                           _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                     | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func solidWhite(_ width: Int, _ height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { _, _ in (255, 255, 255) }
    }

    /// One-pixel checkerboard. Detail this fine cannot survive pixelation, which
    /// is what makes the blur test able to fail.
    private func checkerboard(_ width: Int, _ height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { x, y in
            (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
        }
    }

    private func colour(_ image: CGImage, _ x: Int, _ y: Int) throws -> SRGB {
        let buffer = try XCTUnwrap(ImageBridge.pixelBuffer(from: image))
        return try XCTUnwrap(buffer.colour(x: x, y: y))
    }

    private func settings() -> Settings {
        var s = Settings()
        s.defaultAnnotationColour = SRGB(r: 255, g: 0, b: 0)
        s.defaultLineWidth = 6
        s.blurBlockSize = 12
        return s
    }

    private func canvas(_ image: CGImage,
                        frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600))
    -> EditorCanvasView {
        let view = EditorCanvasView(image: image, settings: settings())
        view.frame = frame
        return view
    }

    // MARK: - Flatten

    func testFlattenKeepsFullPixelResolution() throws {
        let base = try solidWhite(200, 120)
        let box = Annotation(kind: .box,
                             from: PixelPoint(x: 50, y: 40),
                             to: PixelPoint(x: 150, y: 90),
                             colour: SRGB(r: 255, g: 0, b: 0),
                             lineWidth: 6)

        let flat = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                           annotations: [box],
                                                           blockSize: 12))

        // The export is at image resolution, never at the on-screen zoom.
        XCTAssertEqual(flat.width, 200)
        XCTAssertEqual(flat.height, 120)
    }

    func testFlattenAtZoomIsIndependentOfTheCanvasZoom() throws {
        let base = try solidWhite(200, 120)
        let view = canvas(base)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 50, y: 40))
        view.continueDrag(to: PixelPoint(x: 150, y: 90))
        view.endDrag(at: PixelPoint(x: 150, y: 90))

        view.setZoom(0.25)
        let small = try XCTUnwrap(view.flattened())
        view.setZoom(4)
        let large = try XCTUnwrap(view.flattened())

        XCTAssertEqual(small.width, 200)
        XCTAssertEqual(small.height, 120)
        XCTAssertEqual(large.width, 200)
        XCTAssertEqual(large.height, 120)
    }

    func testBoxChangesPixelsInsideAndLeavesTheRestAlone() throws {
        let base = try solidWhite(200, 120)
        let box = Annotation(kind: .box,
                             from: PixelPoint(x: 50, y: 40),
                             to: PixelPoint(x: 150, y: 90),
                             colour: SRGB(r: 255, g: 0, b: 0),
                             lineWidth: 6)
        let flat = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                           annotations: [box],
                                                           blockSize: 12))

        // On the left edge of the stroke, well away from the corners.
        let onStroke = try colour(flat, 52, 65)
        XCTAssertEqual(onStroke, SRGB(r: 255, g: 0, b: 0),
                       "the box stroke did not reach the pixels it covers")

        // The box is stroked, not filled, so the middle is untouched.
        XCTAssertEqual(try colour(flat, 100, 65), SRGB.white)

        // Everything outside the bounding box is exactly as it was. The stroke
        // is inset by half the line width for this reason.
        XCTAssertEqual(try colour(flat, 10, 10), SRGB.white)
        XCTAssertEqual(try colour(flat, 199, 119), SRGB.white)
        XCTAssertEqual(try colour(flat, 48, 65), SRGB.white)
        XCTAssertEqual(try colour(flat, 100, 38), SRGB.white)
    }

    // MARK: - Coordinates

    func testViewPointToImagePixelRoundTripsAtEveryZoom() throws {
        let base = try solidWhite(300, 200)
        let view = canvas(base)
        let samples = [
            PixelPoint(x: 0, y: 0),
            PixelPoint(x: 1, y: 1),
            PixelPoint(x: 7, y: 3),
            PixelPoint(x: 149, y: 99),
            PixelPoint(x: 299, y: 199)
        ]

        for zoom in [CGFloat(1.0), 0.5, 2.0] {
            view.setZoom(zoom)
            XCTAssertEqual(view.zoom, zoom, accuracy: 0.0001)
            for p in samples {
                let back = view.imagePixel(from: view.viewPoint(from: p))
                XCTAssertEqual(back, p, "round trip failed at zoom \(zoom) for \(p)")
            }
        }
    }

    func testImagePixelIsFlippedRelativeToTheView() throws {
        let base = try solidWhite(300, 200)
        let view = canvas(base)
        view.setZoom(1)
        let rect = view.imageRect

        // The top-left image pixel sits at the TOP of the view rect, because
        // NSView measures y upwards and the image measures it downwards.
        let topLeft = view.viewPoint(from: PixelPoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, rect.minX, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, rect.maxY, accuracy: 0.001)

        let bottomLeft = view.viewPoint(from: PixelPoint(x: 0, y: 200))
        XCTAssertEqual(bottomLeft.y, rect.minY, accuracy: 0.001)
    }

    // MARK: - Crop

    func testCropTranslatesEveryAnnotation() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 100, y: 100))
        view.continueDrag(to: PixelPoint(x: 120, y: 130))
        view.endDrag(at: PixelPoint(x: 120, y: 130))
        XCTAssertEqual(view.annotations.count, 1)

        view.applyCrop(PixelRect.xywh(50, 50, 200, 150))

        XCTAssertEqual(view.image.width, 200)
        XCTAssertEqual(view.image.height, 150)
        // An annotation at image (100, 100) inside a crop starting at (50, 50)
        // has to end up at (50, 50), or it jumps the moment the crop lands.
        XCTAssertEqual(view.annotations[0].from, PixelPoint(x: 50, y: 50))
        XCTAssertEqual(view.annotations[0].to, PixelPoint(x: 70, y: 80))
    }

    func testCropFlattensAtTheNewSize() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.applyCrop(PixelRect.xywh(50, 50, 200, 150))
        let flat = try XCTUnwrap(view.flattened())
        XCTAssertEqual(flat.width, 200)
        XCTAssertEqual(flat.height, 150)
    }

    // MARK: - Undo

    func testATwoHundredStepDragIsOneUndoStep() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.box)

        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        for i in 1...200 {
            view.continueDrag(to: PixelPoint(x: 10 + i, y: 10 + i))
        }
        view.endDrag(at: PixelPoint(x: 210, y: 210))

        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].to, PixelPoint(x: 210, y: 210))
        XCTAssertTrue(view.canUndo)

        view.undo()
        XCTAssertEqual(view.annotations.count, 0, "the drag was more than one undo step")
        XCTAssertFalse(view.canUndo, "the drag left extra undo steps behind")
    }

    func testATwoHundredStepMoveIsOneUndoStep() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.continueDrag(to: PixelPoint(x: 60, y: 60))
        view.endDrag(at: PixelPoint(x: 60, y: 60))

        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 30, y: 30))
        for i in 1...200 {
            view.continueDrag(to: PixelPoint(x: 30 + i, y: 30))
        }
        view.endDrag(at: PixelPoint(x: 230, y: 30))

        XCTAssertEqual(view.annotations[0].from, PixelPoint(x: 210, y: 10))

        view.undo()
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].from, PixelPoint(x: 10, y: 10),
                       "the move was more than one undo step")
    }

    func testAClickWithNoDragLeavesNothingBehind() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.endDrag(at: PixelPoint(x: 10, y: 10))

        XCTAssertEqual(view.annotations.count, 0)
        XCTAssertFalse(view.canUndo)
        // Nothing was ever created, so there is nothing to redo either. An
        // invisible one-pixel shape coming back on Cmd+Shift+Z is a real bug.
        XCTAssertFalse(view.canRedo)
    }

    func testSelectingWithoutMovingLeavesNoUndoStep() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.continueDrag(to: PixelPoint(x: 60, y: 60))
        view.endDrag(at: PixelPoint(x: 60, y: 60))

        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 30, y: 30))
        view.endDrag(at: PixelPoint(x: 30, y: 30))

        view.undo()
        XCTAssertEqual(view.annotations.count, 0,
                       "a plain selection left an empty undo step behind")
    }

    // MARK: - Blur

    func testPixelationActuallyChangesPixels() throws {
        let base = try checkerboard(64, 64)
        let pixelated = try XCTUnwrap(AnnotationRenderer.pixellate(base, blockSize: 12))
        XCTAssertEqual(pixelated.width, 64)
        XCTAssertEqual(pixelated.height, 64)

        // A one-pixel checkerboard cannot survive 12-pixel blocks. If any block
        // still alternates, the filter did nothing.
        var changed = 0
        for y in stride(from: 4, to: 60, by: 8) {
            for x in stride(from: 4, to: 60, by: 8) {
                if try colour(pixelated, x, y) != (try colour(base, x, y)) { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 0, "CIPixellate left every sampled pixel alone")
    }

    func testBlurLeavesEverythingOutsideItsRegionUntouched() throws {
        let base = try checkerboard(120, 120)
        let blur = Annotation(kind: .blur,
                              from: PixelPoint(x: 40, y: 40),
                              to: PixelPoint(x: 79, y: 79))
        let flat = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                           annotations: [blur],
                                                           blockSize: 12))

        XCTAssertEqual(flat.width, 120)
        XCTAssertEqual(flat.height, 120)

        // Outside the region the checkerboard is still a checkerboard, exactly.
        for (x, y) in [(0, 0), (10, 100), (100, 10), (119, 119), (39, 60), (81, 60)] {
            XCTAssertEqual(try colour(flat, x, y), try colour(base, x, y),
                           "the blur leaked outside its region at (\(x), \(y))")
        }

        // Inside it, at least one sampled pixel differs.
        var changed = 0
        for y in stride(from: 42, to: 78, by: 5) {
            for x in stride(from: 42, to: 78, by: 5) {
                if try colour(flat, x, y) != (try colour(base, x, y)) { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 0, "the blur region was not pixelated")
    }

    // MARK: - Tools

    func testToolShortcutsComeFromTheModel() {
        // The editor must never carry its own second list of shortcut letters.
        for kind in Annotation.Kind.allCases {
            XCTAssertEqual(EditorTool.forKey(kind.shortcut), .annotate(kind))
        }
        XCTAssertEqual(EditorTool.forKey("x"), .crop)
        XCTAssertEqual(EditorTool.forKey("v"), .select)
        XCTAssertNil(EditorTool.forKey("q"))
    }

    func testCounterGetsItsNumberFromTheStack() throws {
        let base = try solidWhite(400, 300)
        let view = canvas(base)
        view.tool = .annotate(.counter)
        view.beginDrag(at: PixelPoint(x: 50, y: 50))
        view.endDrag(at: PixelPoint(x: 50, y: 50))
        view.beginDrag(at: PixelPoint(x: 150, y: 50))
        view.endDrag(at: PixelPoint(x: 150, y: 50))

        XCTAssertEqual(view.annotations.map(\.counterValue), [1, 2])
    }

    func testHighlightDarkensWithoutErasing() throws {
        // Black text under a yellow wash has to stay black, which is the whole
        // reason the highlight multiplies instead of drawing over.
        let base = try makeImage(width: 40, height: 40) { x, _ in
            x < 20 ? (0, 0, 0) : (255, 255, 255)
        }
        let wash = Annotation(kind: .highlight,
                              from: PixelPoint(x: 0, y: 0),
                              to: PixelPoint(x: 39, y: 39),
                              colour: SRGB(r: 255, g: 230, b: 0))
        let flat = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                           annotations: [wash],
                                                           blockSize: 12))
        XCTAssertEqual(try colour(flat, 5, 20), SRGB.black,
                       "the highlight washed out the dark pixels under it")
        let lit = try colour(flat, 30, 20)
        XCTAssertLessThan(lit.b, 200, "the highlight did not tint the light pixels")
    }

    // MARK: - Editing an annotation that already exists
    //
    // Before this, the colour and width controls only affected the NEXT shape.
    // Drawing a box in the wrong colour meant undoing it and drawing it again.

    /// Draw a box and leave it selected, which is what a real drag does.
    private func drawSelectedBox(on view: EditorCanvasView,
                                 from: PixelPoint = PixelPoint(x: 20, y: 20),
                                 to: PixelPoint = PixelPoint(x: 120, y: 90)) {
        view.tool = .annotate(.box)
        view.beginDrag(at: from)
        view.continueDrag(to: to)
        view.endDrag(at: to)
    }

    func testColourAppliesToTheSelectedAnnotation() throws {
        let view = canvas(try solidWhite(200, 150))
        drawSelectedBox(on: view)
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].colour, SRGB(r: 255, g: 0, b: 0))

        view.applyColour(SRGB(r: 0, g: 0, b: 255))

        XCTAssertEqual(view.annotations[0].colour, SRGB(r: 0, g: 0, b: 255),
                       "the colour well did not reach the selected box")
        // And it became the default too, so the next box matches what the user
        // is looking at rather than reverting to the old colour.
        XCTAssertEqual(view.colour, SRGB(r: 0, g: 0, b: 255))
    }

    func testRecolouringIsOneUndoStepAndRestoresTheOldColour() throws {
        let view = canvas(try solidWhite(200, 150))
        drawSelectedBox(on: view)
        view.applyColour(SRGB(r: 0, g: 0, b: 255))

        view.undo()
        XCTAssertEqual(view.annotations.count, 1, "undo removed the box, not the recolour")
        XCTAssertEqual(view.annotations[0].colour, SRGB(r: 255, g: 0, b: 0))
    }

    func testStyleChangesWithNothingSelectedOnlySetTheDefault() throws {
        let view = canvas(try solidWhite(200, 150))
        view.applyColour(SRGB(r: 0, g: 200, b: 0))
        view.applySize(11, phase: .single)
        view.applyFillStyle(.filled)

        XCTAssertEqual(view.colour, SRGB(r: 0, g: 200, b: 0))
        XCTAssertEqual(view.lineWidth, 11)
        XCTAssertEqual(view.fillStyle, .filled)
        // Nothing changed on the canvas, so nothing may be undoable. An undo
        // step that removes nothing is a Cmd+Z that appears to do nothing.
        XCTAssertFalse(view.canUndo, "changing a default left an undo step behind")
    }

    func testAWholeSliderDragIsOneUndoStep() throws {
        let view = canvas(try solidWhite(400, 300))
        drawSelectedBox(on: view)

        // 1 to 40 the way the knob sends it: one mouse down, then a value per
        // mouse-moved event.
        view.applySize(1, phase: .dragBegan)
        for w in 2...40 {
            view.applySize(w, phase: .dragContinued)
        }
        XCTAssertEqual(view.annotations[0].lineWidth, 40)

        view.undo()
        XCTAssertEqual(view.annotations.count, 1, "the drag swallowed the box itself")
        XCTAssertEqual(view.annotations[0].lineWidth, 6,
                       "the 40-step drag was more than one undo step")
    }

    func testASliderDragThatChangesNothingLeavesNoUndoStep() throws {
        let view = canvas(try solidWhite(400, 300))
        drawSelectedBox(on: view)
        view.undo()          // remove the box, so the stack is empty and clean
        view.redo()          // and put it back, leaving one real step
        let stepsBefore = view.canUndo

        // The knob is grabbed and released on the value it already had.
        view.applySize(6, phase: .dragBegan)
        view.applySize(6, phase: .dragContinued)

        XCTAssertEqual(stepsBefore, view.canUndo)
        view.undo()
        XCTAssertEqual(view.annotations.count, 0,
                       "a no-op slider drag left an undo step in front of the box")
    }

    func testTwoSeparateSliderDragsAreTwoUndoSteps() throws {
        let view = canvas(try solidWhite(400, 300))
        drawSelectedBox(on: view)

        view.applySize(12, phase: .dragBegan)
        view.applySize(20, phase: .dragContinued)
        view.applySize(30, phase: .dragBegan)   // a second, separate grab
        view.applySize(36, phase: .dragContinued)
        XCTAssertEqual(view.annotations[0].lineWidth, 36)

        view.undo()
        XCTAssertEqual(view.annotations[0].lineWidth, 20,
                       "the second drag was folded into the first")
        view.undo()
        XCTAssertEqual(view.annotations[0].lineWidth, 6)
    }

    // MARK: - Rectangle fill

    func testAFilledRectangleFillsItsInteriorAndAStrokedOneDoesNot() throws {
        let base = try solidWhite(120, 120)
        let red = SRGB(r: 255, g: 0, b: 0)
        let corners = (PixelPoint(x: 20, y: 20), PixelPoint(x: 99, y: 99))

        let stroked = Annotation(kind: .box, from: corners.0, to: corners.1,
                                 colour: red, lineWidth: 4, fillStyle: .stroke)
        let filled = Annotation(kind: .box, from: corners.0, to: corners.1,
                                colour: red, lineWidth: 4, fillStyle: .filled)

        let a = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                        annotations: [stroked],
                                                        blockSize: 12))
        let b = try XCTUnwrap(AnnotationRenderer.flatten(base: base,
                                                        annotations: [filled],
                                                        blockSize: 12))

        // Dead centre, far from any border at this line width.
        XCTAssertEqual(try colour(a, 60, 60), SRGB.white,
                       "border only painted the middle of the rectangle")
        XCTAssertEqual(try colour(b, 60, 60), red,
                       "filled left the middle of the rectangle empty")
        // Both still draw the edge, and neither leaks outside it.
        XCTAssertEqual(try colour(a, 60, 20), red)
        XCTAssertEqual(try colour(b, 60, 20), red)
        XCTAssertEqual(try colour(a, 60, 5), SRGB.white)
        XCTAssertEqual(try colour(b, 60, 5), SRGB.white)
    }

    func testFillStyleReachesANewRectangleButNeverAnArrow() throws {
        let view = canvas(try solidWhite(400, 300))
        view.applyFillStyle(.filled)

        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.continueDrag(to: PixelPoint(x: 90, y: 90))
        view.endDrag(at: PixelPoint(x: 90, y: 90))

        view.tool = .annotate(.arrow)
        view.beginDrag(at: PixelPoint(x: 150, y: 10))
        view.continueDrag(to: PixelPoint(x: 250, y: 90))
        view.endDrag(at: PixelPoint(x: 250, y: 90))

        XCTAssertEqual(view.annotations[0].fillStyle, .filled)
        // An arrow has no interior, so storing "filled" on one would be a value
        // that never means anything and that every later reader has to check.
        XCTAssertEqual(view.annotations[1].fillStyle, .stroke,
                       "the rectangle fill setting leaked onto an arrow")
    }

    func testFillCanBeChangedOnARectangleThatAlreadyExists() throws {
        let view = canvas(try solidWhite(200, 150))
        drawSelectedBox(on: view)
        XCTAssertEqual(view.annotations[0].fillStyle, .stroke)

        view.applyFillStyle(.filled)
        XCTAssertEqual(view.annotations[0].fillStyle, .filled)

        view.undo()
        XCTAssertEqual(view.annotations[0].fillStyle, .stroke,
                       "undo did not put the fill back")
    }

    // MARK: - The toolbar follows the selection
    //
    // These go through the real controller rather than calling the toolbar
    // directly. A toolbar that stops following the selection is a wiring bug,
    // and a test that rebuilt the wiring itself could never catch it.

    private func controller(_ image: CGImage) -> EditorWindowController {
        EditorWindowController(image: image, shotID: nil, settings: settings())
    }

    func testSelectingAnAnnotationPointsTheToolbarAtIt() throws {
        let c = controller(try solidWhite(400, 300))
        let view = c.canvas

        // A blue box, thick, on the left.
        view.applyColour(SRGB(r: 0, g: 0, b: 255))
        view.applySize(14, phase: .single)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.continueDrag(to: PixelPoint(x: 100, y: 100))
        view.endDrag(at: PixelPoint(x: 100, y: 100))

        // Click away first. A shape stays selected after it is drawn, on
        // purpose, so changing the colour now would recolour the blue box
        // instead of setting the default for the next one.
        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 200, y: 250))
        view.endDrag(at: PixelPoint(x: 200, y: 250))
        XCTAssertNil(view.selectedAnnotation)

        // A green thin box on the right, which leaves green as the default.
        view.applyColour(SRGB(r: 0, g: 255, b: 0))
        view.applySize(2, phase: .single)
        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 200, y: 10))
        view.continueDrag(to: PixelPoint(x: 300, y: 100))
        view.endDrag(at: PixelPoint(x: 300, y: 100))

        // Click the blue one.
        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 55, y: 10))
        view.endDrag(at: PixelPoint(x: 55, y: 10))
        XCTAssertEqual(view.selectedAnnotation?.colour, SRGB(r: 0, g: 0, b: 255),
                       "the click did not select the blue box")

        XCTAssertEqual(AnnotationRenderer.srgb(c.toolbar.colourWell.color),
                       SRGB(r: 0, g: 0, b: 255),
                       "the colour well still showed the default, not the selection")
        XCTAssertEqual(Int(c.toolbar.widthSlider.doubleValue), 14,
                       "the width slider still showed the default, not the selection")
    }

    func testDeselectingPutsTheToolbarBackOnTheDefaults() throws {
        let c = controller(try solidWhite(400, 300))
        let view = c.canvas

        view.tool = .annotate(.box)
        view.beginDrag(at: PixelPoint(x: 10, y: 10))
        view.continueDrag(to: PixelPoint(x: 100, y: 100))
        view.endDrag(at: PixelPoint(x: 100, y: 100))
        view.applyColour(SRGB(r: 0, g: 0, b: 255))   // recolours the selection

        // Click far away from everything.
        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 350, y: 250))
        view.endDrag(at: PixelPoint(x: 350, y: 250))
        XCTAssertNil(view.selectedAnnotation)

        XCTAssertEqual(AnnotationRenderer.srgb(c.toolbar.colourWell.color),
                       view.colour,
                       "with nothing selected the toolbar must show the defaults")
    }

    func testTheWidthSliderCoversAHairlineAndAMarker() throws {
        let c = controller(try solidWhite(400, 300))
        // The old buttons were 2, 4 and 8. The complaint was that neither end
        // was reachable, so the range is asserted rather than left to drift.
        XCTAssertLessThanOrEqual(c.toolbar.widthSlider.minValue, 1)
        XCTAssertGreaterThanOrEqual(c.toolbar.widthSlider.maxValue, 40)
    }

    // MARK: - The one slider, two meanings
    //
    // Line width means nothing for text and font size means nothing for
    // everything else, so the slider switches. The risk is that the toolbar and
    // the canvas disagree about which it currently is, and a drag then writes a
    // type size into a line width.

    func testTheSliderMeansTextSizeForTextAndLineWidthForTheRest() throws {
        let view = canvas(try solidWhite(400, 300))
        XCTAssertEqual(view.sizeControl, .lineWidth, "with no tool it is a width")

        view.tool = .annotate(.text)
        XCTAssertEqual(view.sizeControl, .fontSize)
        view.tool = .annotate(.box)
        XCTAssertEqual(view.sizeControl, .lineWidth)

        // A selection wins over the tool, because the controls act on what is
        // selected. Otherwise picking the box tool while a label is selected
        // would turn the slider back into a width and edit the wrong number.
        view.tool = .annotate(.text)
        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))
        view.textView?.string = "hi"
        view.beginDrag(at: PixelPoint(x: 300, y: 250))   // commit, goes idle
        view.endDrag(at: PixelPoint(x: 300, y: 250))
        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 45, y: 50))     // click the label
        view.endDrag(at: PixelPoint(x: 45, y: 50))
        XCTAssertEqual(view.selectedAnnotation?.kind, .text)
        XCTAssertEqual(view.sizeControl, .fontSize)

        view.tool = .annotate(.box)
        XCTAssertEqual(view.sizeControl, .fontSize,
                       "the selected label must keep the slider on text size")
    }

    func testTheSliderResizesTheTextAndNotItsLineWidth() throws {
        let view = canvas(try solidWhite(400, 300))
        view.tool = .annotate(.text)
        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))
        view.textView?.string = "big"
        view.beginDrag(at: PixelPoint(x: 300, y: 250))
        view.endDrag(at: PixelPoint(x: 300, y: 250))

        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 45, y: 50))
        view.endDrag(at: PixelPoint(x: 45, y: 50))
        let before = try XCTUnwrap(view.selectedAnnotation)
        XCTAssertEqual(before.fontSize, 28)

        view.applySize(96, phase: .single)

        let after = try XCTUnwrap(view.selectedAnnotation)
        XCTAssertEqual(after.fontSize, 96)
        XCTAssertEqual(after.lineWidth, before.lineWidth,
                       "the slider wrote a type size into the line width")
        // The box has to follow the type. A selection outline and a hit test
        // that describe a rectangle no longer under the glyphs is the same bug
        // as drawing them in the wrong place.
        XCTAssertGreaterThan(after.boundingBox.height, before.boundingBox.height,
                             "the box did not grow with the text")
        XCTAssertGreaterThan(after.boundingBox.width, before.boundingBox.width)
    }

    func testTheSliderStillMeansLineWidthForAShape() throws {
        let view = canvas(try solidWhite(400, 300))
        drawSelectedBox(on: view)
        let fontBefore = try XCTUnwrap(view.selectedAnnotation).fontSize

        view.applySize(22, phase: .single)

        let after = try XCTUnwrap(view.selectedAnnotation)
        XCTAssertEqual(after.lineWidth, 22)
        XCTAssertEqual(after.fontSize, fontBefore,
                       "a line width change moved the font size")
    }

    func testAValueOutsideTheRangeIsClampedRatherThanStored() throws {
        let view = canvas(try solidWhite(400, 300))
        drawSelectedBox(on: view)

        // 200 is inside the text range and far outside the width range. Storing
        // it would draw a border wider than the screenshot, and the slider could
        // never get back to it.
        view.applySize(200, phase: .single)
        XCTAssertEqual(view.selectedAnnotation?.lineWidth,
                       Annotation.SizeControl.lineWidth.range.upperBound)

        view.applySize(0, phase: .single)
        XCTAssertEqual(view.selectedAnnotation?.lineWidth,
                       Annotation.SizeControl.lineWidth.range.lowerBound)
    }

    func testResizingTextIsOneUndoStepPerDrag() throws {
        let view = canvas(try solidWhite(400, 300))
        view.tool = .annotate(.text)
        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))
        view.textView?.string = "label"
        view.beginDrag(at: PixelPoint(x: 300, y: 250))
        view.endDrag(at: PixelPoint(x: 300, y: 250))
        view.tool = .select
        view.beginDrag(at: PixelPoint(x: 45, y: 50))
        view.endDrag(at: PixelPoint(x: 45, y: 50))

        view.applySize(30, phase: .dragBegan)
        for size in 31...120 {
            view.applySize(size, phase: .dragContinued)
        }
        XCTAssertEqual(view.selectedAnnotation?.fontSize, 120)

        view.undo()
        XCTAssertEqual(view.selectedAnnotation?.fontSize, 28,
                       "the 90-step resize was more than one undo step")
        XCTAssertEqual(view.annotations.first?.text, "label",
                       "undo went back past the label instead of past the resize")
    }

    func testTheToolbarSliderFollowsWhatItIsAbout() throws {
        let c = controller(try solidWhite(400, 300))

        // Picking the text tool has to move the slider onto the text range. A
        // 1 to 40 slider in front of a 28 pixel type size would clamp every
        // value the user picked down to 40.
        c.canvas.tool = .annotate(.text)
        XCTAssertEqual(c.toolbar.sizeControl, .fontSize)
        XCTAssertEqual(Int(c.toolbar.widthSlider.maxValue),
                       Annotation.SizeControl.fontSize.range.upperBound)
        XCTAssertEqual(Int(c.toolbar.widthSlider.doubleValue), c.canvas.fontSize)

        c.canvas.tool = .annotate(.box)
        XCTAssertEqual(c.toolbar.sizeControl, .lineWidth)
        XCTAssertEqual(Int(c.toolbar.widthSlider.maxValue),
                       Annotation.SizeControl.lineWidth.range.upperBound)
        XCTAssertEqual(Int(c.toolbar.widthSlider.doubleValue), c.canvas.lineWidth)
    }

    func testTheToolbarNeverTakesTheKeyboardOffTheCanvas() throws {
        let c = controller(try solidWhite(400, 300))
        // A slider or a segmented control that accepts first responder swallows
        // every later single-key tool shortcut. The keyboard flow then dies
        // silently the first time the user touches the width, and nothing about
        // a screenshot of the window shows it.
        XCTAssertTrue(c.toolbar.widthSlider.refusesFirstResponder,
                      "the width slider would steal the keyboard from the canvas")
        XCTAssertTrue(c.toolbar.fillControl.refusesFirstResponder,
                      "the fill control would steal the keyboard from the canvas")
    }

    func testFillIsOfferedForARectangleAndNotForTheRest() throws {
        let c = controller(try solidWhite(400, 300))

        c.toolbar.setTool(.annotate(.box))
        XCTAssertTrue(c.toolbar.fillControl.isEnabled)

        c.toolbar.setTool(.annotate(.arrow))
        XCTAssertFalse(c.toolbar.fillControl.isEnabled,
                       "an arrow offered a fill setting that does nothing")

        // And with a selection it follows what is selected, not the tool.
        c.toolbar.showAttributes(colour: .black, lineWidth: 4, fontSize: 28,
                                 fillStyle: .stroke, selectedKind: .box)
        XCTAssertTrue(c.toolbar.fillControl.isEnabled)
        c.toolbar.showAttributes(colour: .black, lineWidth: 4, fontSize: 28,
                                 fillStyle: .stroke, selectedKind: .text)
        XCTAssertFalse(c.toolbar.fillControl.isEnabled)
    }

    // MARK: - Escape, and finishing a text label

    /// A real key-down event, because `keyDown` is the thing under test and a
    /// hand-rolled substitute would only test the substitute.
    private func keyEvent(_ code: UInt16, _ chars: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil,
                                       characters: chars,
                                       charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code))
    }

    private let escape: UInt16 = 53

    func testEscapeCopiesAndCloses() throws {
        let view = canvas(try solidWhite(200, 150))
        var seen: [EditorCanvasView.Command] = []
        view.onCommand = { seen.append($0); return true }

        view.keyDown(with: try keyEvent(escape, "\u{1B}"))

        XCTAssertEqual(seen, [.copyAndClose],
                       "Escape must copy and close in one press")
    }

    func testEscapeCancelsAPendingCropBeforeItClosesAnything() throws {
        let view = canvas(try solidWhite(400, 300))
        var seen: [EditorCanvasView.Command] = []
        view.onCommand = { seen.append($0); return true }

        view.tool = .crop
        view.beginDrag(at: PixelPoint(x: 20, y: 20))
        view.continueDrag(to: PixelPoint(x: 200, y: 150))
        view.endDrag(at: PixelPoint(x: 200, y: 150))
        XCTAssertNotNil(view.cropRect)

        // A crop rectangle is drawn but not applied. Without a way to abandon
        // it, the only exits would be destroying pixels or losing the window.
        view.keyDown(with: try keyEvent(escape, "\u{1B}"))
        XCTAssertNil(view.cropRect)
        XCTAssertEqual(seen, [], "Escape closed the window with a crop pending")

        // The second press has nothing left to back out of, so it closes.
        view.keyDown(with: try keyEvent(escape, "\u{1B}"))
        XCTAssertEqual(seen, [.copyAndClose])
    }

    func testEscapeStillClosesWithSomethingSelected() throws {
        let view = canvas(try solidWhite(400, 300))
        var seen: [EditorCanvasView.Command] = []
        view.onCommand = { seen.append($0); return true }
        drawSelectedBox(on: view)
        XCTAssertNotNil(view.selectedAnnotation)

        // Every shape stays selected after it is drawn. If Escape only cleared
        // the selection, the key would appear to do nothing straight after the
        // most common action in the whole editor.
        view.keyDown(with: try keyEvent(escape, "\u{1B}"))
        XCTAssertEqual(seen, [.copyAndClose])
    }

    func testFinishingALabelGoesIdleInsteadOfStartingAnother() throws {
        let view = canvas(try solidWhite(400, 300))
        view.tool = .annotate(.text)

        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))
        XCTAssertTrue(view.isEditingText, "the text tool did not open an editor")
        view.textView?.string = "hello"

        // Click somewhere else, which is how anyone finishes a floating field.
        view.beginDrag(at: PixelPoint(x: 300, y: 250))
        view.endDrag(at: PixelPoint(x: 300, y: 250))

        XCTAssertFalse(view.isEditingText)
        XCTAssertEqual(view.tool, .select,
                       "the editor stayed on the text tool after finishing a label")
        XCTAssertEqual(view.annotations.count, 1,
                       "the click that ended one label started a second one")
        XCTAssertEqual(view.annotations[0].text, "hello")
    }

    func testEscapeInsideALabelCommitsItAndGoesIdleWithoutClosing() throws {
        let view = canvas(try solidWhite(400, 300))
        var seen: [EditorCanvasView.Command] = []
        view.onCommand = { seen.append($0); return true }
        view.tool = .annotate(.text)
        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))
        let tv = try XCTUnwrap(view.textView)
        tv.string = "typed"

        // Escape reaches the text view, not `keyDown`. It must keep what was
        // typed: losing it is worse than keeping something unwanted, which one
        // more Escape then discards.
        _ = view.textView(tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertFalse(view.isEditingText)
        XCTAssertEqual(view.tool, .select)
        XCTAssertEqual(view.annotations.first?.text, "typed")
        XCTAssertEqual(seen, [], "Escape closed the window instead of ending the label")
    }

    func testAnEmptyLabelLeavesNothingBehind() throws {
        let view = canvas(try solidWhite(400, 300))
        view.tool = .annotate(.text)
        view.beginDrag(at: PixelPoint(x: 40, y: 40))
        view.endDrag(at: PixelPoint(x: 40, y: 40))

        // Clicked the text tool by mistake and clicked away. An invisible empty
        // annotation that still hit-tests would be worse than nothing.
        view.beginDrag(at: PixelPoint(x: 300, y: 250))
        view.endDrag(at: PixelPoint(x: 300, y: 250))

        XCTAssertEqual(view.annotations.count, 0)
        XCTAssertEqual(view.tool, .select)
    }

    func testTheSliderPhaseMachineSeesOneDragAsOneDrag() {
        let toolbar = EditorToolbar(colour: .black, lineWidth: 4)

        // A grab on the knob: down, then moves, then up.
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseDown), .dragBegan)
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseDragged), .dragContinued)
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseDragged), .dragContinued)
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseUp), .dragContinued)

        // A click on the track, where AppKit can send the first action only once
        // the mouse has already moved. That is still the start of a drag.
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseDragged), .dragBegan)
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseDragged), .dragContinued)
        XCTAssertEqual(toolbar.sliderPhase(for: .leftMouseUp), .dragContinued)

        // The keyboard and accessibility are complete changes on their own.
        XCTAssertEqual(toolbar.sliderPhase(for: .keyDown), .single)
        XCTAssertEqual(toolbar.sliderPhase(for: nil), .single)
    }
}
