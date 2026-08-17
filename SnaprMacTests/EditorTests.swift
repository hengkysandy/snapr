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
        XCTAssertEqual(EditorTool.forKey("c"), .crop)
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
}
