import CoreGraphics
import XCTest

import SnaprCore
@testable import SnaprMac

/// The seam between the core and the Mac shell.
///
/// **Nothing here needs a Screen Recording grant and nothing here needs a
/// display.** CI and a fresh machine have neither, and a test suite that is
/// skipped on those machines is a test suite that does not exist. So the parts
/// under test are the pure ones: coordinate conversion, key rendering, integer
/// nudging, edge-snap acceptance and error mapping.
final class CaptureTests: XCTestCase {

    // MARK: - Coordinate conversion
    //
    // `PixelRect` is top-left origin in backing pixels. `NSView` is bottom-up in
    // points. This is where off-by-one selection bugs come from, so both
    // directions are asserted at both scales, including a screen that does not
    // start at the origin.

    func testViewPointToPixelAtScaleOne() {
        let g = OverlayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)
        XCTAssertEqual(g.pixelWidth, 1000)
        XCTAssertEqual(g.pixelHeight, 800)

        // Bottom-left of the view is the BOTTOM row of pixels.
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 0, y: 0)), PixelPoint(x: 0, y: 799))
        // Top-left of the view is pixel 0,0.
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 0, y: 800)), PixelPoint(x: 0, y: 0))
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 10, y: 790)), PixelPoint(x: 10, y: 10))
    }

    func testViewPointToPixelAtScaleTwo() {
        let g = OverlayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), scale: 2)
        // The real machine the probes ran on: 1470x956 logical, 2940x1912 backing.
        XCTAssertEqual(g.pixelWidth, 2940)
        XCTAssertEqual(g.pixelHeight, 1912)

        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 10, y: 946)), PixelPoint(x: 20, y: 20))
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 0, y: 956)), PixelPoint(x: 0, y: 0))
        // Clamped, never past the last pixel.
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 1470, y: 0)),
                       PixelPoint(x: 2939, y: 1911))
    }

    func testHalfPixelFloorsRatherThanRounds() {
        // A point anywhere inside pixel column 7 must name column 7. Rounding
        // would make the right half of the column name column 8, so the loupe
        // would show a different pixel than the cursor sits on, at exactly half
        // the cursor positions.
        let g = OverlayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 3.5, y: 100)).x, 7)
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 3.9, y: 100)).x, 7)
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 4.0, y: 100)).x, 8)
    }

    func testGlobalPointOnAScreenWithANonZeroOrigin() {
        // A second display sitting to the right of and above the primary one.
        // UNPROVEN on hardware (gap A7, this machine has one display), so the
        // arithmetic is at least pinned here.
        let g = OverlayGeometry(screenFrame: CGRect(x: 1470, y: 200, width: 1000, height: 800), scale: 2)

        // The screen's own top-left corner in global Cocoa points.
        XCTAssertEqual(g.pixel(fromGlobalPoint: CGPoint(x: 1470, y: 1000)), PixelPoint(x: 0, y: 0))
        // Ten points in and ten points down from that corner.
        XCTAssertEqual(g.pixel(fromGlobalPoint: CGPoint(x: 1480, y: 990)), PixelPoint(x: 20, y: 20))
        // A screen with a negative origin, which is a display placed left of
        // the primary one.
        let left = OverlayGeometry(screenFrame: CGRect(x: -1000, y: 0, width: 1000, height: 800), scale: 1)
        XCTAssertEqual(left.pixel(fromGlobalPoint: CGPoint(x: -1000, y: 800)), PixelPoint(x: 0, y: 0))
        XCTAssertEqual(left.pixel(fromGlobalPoint: CGPoint(x: -990, y: 790)), PixelPoint(x: 10, y: 10))
    }

    func testPixelRectToViewRectAndBack() {
        for scale in [CGFloat(1), CGFloat(2)] {
            let g = OverlayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: scale)
            let rect = PixelRect.xywh(100, 50, 300, 200)
            let viewRect = g.viewRect(fromPixelRect: rect)

            XCTAssertEqual(viewRect.minX, 100 / scale, accuracy: 0.001)
            XCTAssertEqual(viewRect.width, 300 / scale, accuracy: 0.001)
            XCTAssertEqual(viewRect.height, 200 / scale, accuracy: 0.001)
            // y0 = 50 from the TOP, so the rect's top edge sits 50 pixels below
            // the top of the view, which is high up in bottom-up view points.
            XCTAssertEqual(viewRect.maxY, 800 - 50 / scale, accuracy: 0.001)

            // Round trip, exactly. This is the assertion that catches a flip
            // done twice or not at all.
            XCTAssertEqual(g.pixelRect(fromViewRect: viewRect), rect, "scale \(scale)")
        }
    }

    func testPixelRectToViewRectOnAScreenWithANonZeroOrigin() {
        // The overlay window is placed exactly on the screen frame, so the view
        // rect is relative to the window and the screen origin must NOT appear
        // in it. A screen origin leaking into a view rect draws the selection
        // in the wrong place on a second display.
        let g = OverlayGeometry(screenFrame: CGRect(x: 1470, y: 200, width: 1000, height: 800), scale: 2)
        let viewRect = g.viewRect(fromPixelRect: PixelRect.xywh(0, 0, 100, 100))
        XCTAssertEqual(viewRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewRect.maxY, 800, accuracy: 0.001)
    }

    func testDegenerateScaleDoesNotProduceNaN() {
        // A zero scale would divide by zero everywhere downstream and turn every
        // coordinate into NaN, which reads as "selection is broken" rather than
        // as a bad input.
        let g = OverlayGeometry(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 0)
        XCTAssertEqual(g.scale, 1)
        XCTAssertEqual(g.pixel(fromViewPoint: CGPoint(x: 10, y: 90)), PixelPoint(x: 10, y: 10))
    }

    // MARK: - Hotkey rendering

    func testDisplayStringUsesMacOSModifierOrder() {
        // macOS always renders control, option, shift, command in that order.
        // Getting it wrong is the kind of detail that makes an app feel foreign.
        let all = HotkeySpec(keyCode: HotkeySpec.Key.four,
                             modifiers: HotkeySpec.cmdKey | HotkeySpec.shiftKey
                                 | HotkeySpec.optionKey | HotkeySpec.controlKey)
        XCTAssertEqual(all.displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}4")

        // The shipped default for "capture area", chosen because macOS owns
        // Cmd Shift 4 and would reject it with -9878.
        XCTAssertEqual(HotkeyAction.captureArea.defaultSpec.displayString, "\u{2303}\u{21E7}4")
        XCTAssertEqual(HotkeyAction.openHistory.defaultSpec.displayString, "\u{2303}\u{21E7}H")
        XCTAssertEqual(HotkeyAction.repeatLastArea.defaultSpec.displayString, "\u{2303}\u{21E7}R")

        // No modifiers at all still renders the key.
        XCTAssertEqual(HotkeySpec(keyCode: HotkeySpec.Key.one, modifiers: 0).displayString, "1")
    }

    func testDefaultHotkeysDoNotConflictWithEachOther() {
        XCTAssertTrue(Settings().conflicts.isEmpty)
    }

    // MARK: - Arrow-key nudging
    //
    // This is the pixel-measurement feature. Every number here must be an exact
    // integer, because a selection that is 200.5 pixels wide is not a selection.

    func testArrowNudgeMovesExactlyOnePixel() {
        var s = Selection(rect: PixelRect.xywh(100, 100, 50, 40),
                          bounds: PixelRect.xywh(0, 0, 1000, 800))
        s.move(dx: 1, dy: 0)
        XCTAssertEqual(s.rect, PixelRect.xywh(101, 100, 50, 40))
        s.move(dx: 0, dy: 1)
        XCTAssertEqual(s.rect, PixelRect.xywh(101, 101, 50, 40))
        s.move(dx: -1, dy: -1)
        XCTAssertEqual(s.rect, PixelRect.xywh(100, 100, 50, 40))
    }

    func testShiftArrowNudgeMovesExactlyTenPixels() {
        var s = Selection(rect: PixelRect.xywh(100, 100, 50, 40),
                          bounds: PixelRect.xywh(0, 0, 1000, 800))
        s.move(dx: 10, dy: 10)
        XCTAssertEqual(s.rect, PixelRect.xywh(110, 110, 50, 40))
        // Size never changes when moving. A nudge that also resized would break
        // the whole point of measuring something.
        XCTAssertEqual(s.rect.width, 50)
        XCTAssertEqual(s.rect.height, 40)
    }

    func testNudgeStopsAtBoundsInsteadOfShrinking() {
        let bounds = PixelRect.xywh(0, 0, 1000, 800)
        var s = Selection(rect: PixelRect.xywh(2, 2, 50, 40), bounds: bounds)
        s.move(dx: -10, dy: -10)
        XCTAssertEqual(s.rect, PixelRect.xywh(0, 0, 50, 40), "must slide to the edge, not shrink")

        var far = Selection(rect: PixelRect.xywh(940, 750, 50, 40), bounds: bounds)
        far.move(dx: 100, dy: 100)
        XCTAssertEqual(far.rect, PixelRect.xywh(950, 760, 50, 40))
        XCTAssertEqual(far.rect.width, 50)
        XCTAssertEqual(far.rect.height, 40)
    }

    func testOptionArrowResizesTheBottomRightCornerByExactlyOnePixel() {
        var s = Selection(rect: PixelRect.xywh(100, 100, 50, 40),
                          bounds: PixelRect.xywh(0, 0, 1000, 800))
        s.resize(.bottomRight, dx: 1, dy: 0)
        XCTAssertEqual(s.rect, PixelRect.xywh(100, 100, 51, 40))
        s.resize(.bottomRight, dx: 0, dy: 10)
        XCTAssertEqual(s.rect, PixelRect.xywh(100, 100, 51, 50))
    }

    func testResizeNeverInvertsTheRectangle() {
        // Without the guard in the core, a fast shrink flips the rect and the
        // live readout shows a negative size.
        var s = Selection(rect: PixelRect.xywh(100, 100, 3, 3),
                          bounds: PixelRect.xywh(0, 0, 1000, 800))
        s.resize(.bottomRight, dx: -100, dy: -100)
        XCTAssertGreaterThanOrEqual(s.rect.width, 1)
        XCTAssertGreaterThanOrEqual(s.rect.height, 1)
    }

    func testASinglePixelDragSelectsOnePixel() {
        let p = PixelPoint(x: 40, y: 40)
        let s = Selection(from: p, to: p, bounds: PixelRect.xywh(0, 0, 100, 100))
        XCTAssertEqual(s.rect, PixelRect.xywh(40, 40, 1, 1))
    }

    // MARK: - Edge snap acceptance
    //
    // The rejection test is the important one. MEASURED (probe A14): on three
    // flat-desktop seeds the acceptance test correctly refused, where a naive
    // flood returned a confident 1.6-megapixel rectangle of empty desktop and
    // reported nothing wrong. That refusal is the entire value of the technique.

    func testSnapFindsAnObviousRectangle() {
        let f = Fixture()

        let result = EdgeSnap.snap(in: f.buffer, at: f.insideElement)

        XCTAssertTrue(result.accepted, "reason was: \(result.reason)")
        let iou = result.rect.iou(f.element)
        XCTAssertGreaterThan(iou, 0.9, "IoU \(iou), snapped to \(result.rect)")
        XCTAssertFalse(result.levels.isEmpty)
    }

    func testSnapIsRejectedOnAFlatBuffer() {
        // The one that matters. A flat desktop has no element in it, so the
        // only correct answer is no answer. The naive flood the probe compared
        // against returned a confident 1.6-megapixel rectangle here.
        let flat = Self.flatBuffer(width: 640, height: 480, value: 27)

        let result = EdgeSnap.snap(in: flat, at: PixelPoint(x: 320, y: 240))

        XCTAssertFalse(result.accepted,
                       "a flat buffer must produce NO snap, got \(result.rect.describedSize)")
        XCTAssertFalse(result.reason.isEmpty,
                       "a rejection with no reason is indistinguishable from a crash")
    }

    func testSnapIsRejectedWhenTheFillEscapesToTheImageBorder() {
        // Seeding in the wallpaper of an image that does contain elements. The
        // fill escapes into the background and reaches the image border, which
        // is the rule that caught every flat-desktop case in the probe.
        let f = Fixture()
        let result = EdgeSnap.snap(in: f.buffer, at: PixelPoint(x: 600, y: 450))
        XCTAssertFalse(result.accepted, "reason was: \(result.reason)")
    }

    func testPressingSnapAgainGrowsToTheParent() {
        let f = Fixture()
        let result = EdgeSnap.snap(in: f.buffer, at: f.insideElement, maxLevels: 3)

        XCTAssertGreaterThanOrEqual(result.levels.count, 2, "the fixture is nested, so there is a parent")
        XCTAssertLessThanOrEqual(result.levels.count, 3, "two or three levels is all that is useful")
        XCTAssertGreaterThan(result.levels[1].iou(f.panel), 0.9,
                             "level 1 must be the panel, got \(result.levels[1])")

        // Pressing A again must grow, never shrink and never jump sideways.
        for i in 1..<result.levels.count {
            XCTAssertGreaterThan(result.levels[i].area, result.levels[i - 1].area)
            XCTAssertEqual(result.levels[i].intersection(result.levels[i - 1]), result.levels[i - 1],
                           "level \(i) must contain level \(i - 1)")
        }
    }

    // MARK: - Error classification
    //
    // MEASURED (probe A1). The assumption list predicted a silent black frame.
    // ScreenCaptureKit is not silent: it fails with SCStreamErrorDomain -3801,
    // so the app reads a missing grant from the ERROR and never from the pixels.

    func testUserDeclinedErrorMapsToNoPermission() {
        let error = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                            code: -3801,
                            userInfo: [NSLocalizedDescriptionKey:
                                "The user declined TCCs for application, window, display capture"])
        guard case .noPermission = CaptureEngine.classify(error) else {
            return XCTFail("-3801 must map to .noPermission")
        }
    }

    func testTheMeasuredCodeIsPinned() {
        XCTAssertEqual(CaptureEngine.userDeclinedCode, -3801)
        XCTAssertEqual(HotkeyManager.alreadyRegistered, -9878)
    }

    func testOtherErrorsDoNotMasqueradeAsAMissingPermission() {
        // A generic failure must NOT send the user to System Settings to grant
        // a permission they already granted.
        let error = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3802)
        guard case .failed = CaptureEngine.classify(error) else {
            return XCTFail("an unrelated code must map to .failed")
        }
    }

    func testAlreadyClassifiedErrorsPassThroughUnchanged() {
        guard case .blankFrame(let reason) = CaptureEngine.classify(CaptureError.blankFrame("all black")) else {
            return XCTFail("a CaptureError must not be re-wrapped as .failed")
        }
        XCTAssertEqual(reason, "all black")
    }

    // MARK: - Fixtures

    /// A wallpaper, a panel, and an element with a one-pixel border inside it.
    ///
    /// Every grey value here is load-bearing, so they are named rather than
    /// scattered:
    ///
    /// - The element's fill and its border differ by 14, so a per-channel sum of
    ///   42 keeps the level-0 flood inside the fill at tolerance 24, and lets
    ///   the level-1 flood at tolerance 48 cross into the panel.
    /// - The border and the panel differ by 5, which clears the acceptance
    ///   test's luma-step threshold of 4 on all four sides. `EdgeSnap` insets
    ///   its flood bounds by one pixel because a real element's border is a
    ///   shade off from its fill, so the inset edge has to land ON a border
    ///   that contrasts with what is outside it. A hard-edged box with no
    ///   border is correctly rejected, which is why this fixture has one.
    /// - The panel is 400x300. The flood caps at half the image, 153,600
    ///   pixels here, and a larger panel would overflow that cap and return no
    ///   parent at all.
    struct Fixture {
        let panel = PixelRect(x0: 50, y0: 50, x1: 450, y1: 350)
        let element = PixelRect(x0: 149, y0: 149, x1: 301, y1: 251)
        let insideElement = PixelPoint(x: 225, y: 200)
        let buffer: PixelBuffer

        init(width: Int = 640, height: Int = 480) {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            func fill(_ r: PixelRect, _ value: UInt8) {
                for y in max(0, r.y0)..<min(height, r.y1) {
                    for x in max(0, r.x0)..<min(width, r.x1) {
                        let o = (y * width + x) * 4
                        rgba[o] = value; rgba[o + 1] = value; rgba[o + 2] = value; rgba[o + 3] = 255
                    }
                }
            }
            fill(PixelRect.xywh(0, 0, width, height), 40)   // wallpaper
            fill(panel, 191)                                // the parent level
            fill(element, 186)                              // the element's border ring
            fill(element.inset(by: 1), 200)                 // the element's fill
            buffer = PixelBuffer(width: width, height: height, rgba: rgba)
        }
    }

    /// A desktop with nothing on it.
    static func flatBuffer(width: Int, height: Int, value: UInt8) -> PixelBuffer {
        var rgba = [UInt8](repeating: value, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }
}
