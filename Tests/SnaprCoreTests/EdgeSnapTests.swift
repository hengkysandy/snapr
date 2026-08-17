import Testing
@testable import SnaprCore

/// Builds a synthetic screen the way the A14 fixture did: flat rectangles on a
/// flat background, with known coordinates. That is the easy case for a flood
/// fill, and the design says so out loud. These tests protect the ALGORITHM,
/// not the accuracy claim.
struct SyntheticScreen {
    var width: Int
    var height: Int
    private var rgba: [UInt8]

    init(width: Int, height: Int, background: SRGB) {
        self.width = width
        self.height = height
        self.rgba = [UInt8](repeating: 255, count: width * height * 4)
        fill(PixelRect.xywh(0, 0, width, height), background)
    }

    mutating func fill(_ r: PixelRect, _ c: SRGB) {
        for y in max(0, r.y0)..<min(height, r.y1) {
            for x in max(0, r.x0)..<min(width, r.x1) {
                let o = (y * width + x) * 4
                rgba[o] = UInt8(c.r); rgba[o + 1] = UInt8(c.g)
                rgba[o + 2] = UInt8(c.b); rgba[o + 3] = 255
            }
        }
    }

    /// A filled rect with a one-pixel border a few shades off, which is what a
    /// real control looks like and what the flood fill stops at.
    mutating func control(_ r: PixelRect, fill f: SRGB, border b: SRGB) {
        fill(r, b)
        fill(r.inset(by: 1), f)
    }

    var buffer: PixelBuffer { PixelBuffer(width: width, height: height, rgba: rgba) }
}

@Suite("Edge snap")
struct EdgeSnapTests {

    let desktop = SRGB(r: 32, g: 38, b: 52)
    let windowFill = SRGB(r: 58, g: 58, b: 62)
    let controlFill = SRGB(r: 90, g: 92, b: 96)
    let controlBorder = SRGB(r: 140, g: 142, b: 146)

    func screenWithOneButton(buttonRect: PixelRect) -> PixelBuffer {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        s.fill(PixelRect.xywh(80, 60, 440, 280), windowFill)
        s.control(buttonRect, fill: controlFill, border: controlBorder)
        return s.buffer
    }

    @Test("a seed inside a button snaps to the button")
    func snapsToButton() {
        let truth = PixelRect.xywh(200, 150, 120, 40)
        let buffer = screenWithOneButton(buttonRect: truth)
        let result = EdgeSnap.snap(in: buffer, at: truth.centre)

        #expect(result.accepted, "should have snapped, reason was: \(result.reason)")
        #expect(result.rect.iou(truth) > 0.9,
                "IoU \(result.rect.iou(truth)), got \(result.rect), wanted \(truth)")
    }

    @Test("a rough drag over a button snaps to the same rect as a point seed")
    func roughSeedMatchesPointSeed() {
        // MEASURED in probe A14: point seeds and rough-rect seeds gave
        // identical results on all 11 targets, both directions.
        let truth = PixelRect.xywh(200, 150, 120, 40)
        let buffer = screenWithOneButton(buttonRect: truth)
        let point = EdgeSnap.snap(in: buffer, at: truth.centre)
        let rough = EdgeSnap.snap(in: buffer, roughly: PixelRect.xywh(210, 160, 40, 15))
        #expect(point.rect == rough.rect)
    }

    /// This is the important test in the file.
    ///
    /// MEASURED (probe A14): on three flat-desktop seeds the acceptance test
    /// correctly refused, where a naive flood returned a confident
    /// 1.6-megapixel rectangle of empty desktop and reported nothing wrong.
    /// The refusal IS the feature. Plain flood fill scored the same mean IoU as
    /// the full hybrid at 50x the speed, so the only thing the extra machinery
    /// buys is this.
    @Test("a completely flat screen is REJECTED, not snapped to everything")
    func flatScreenIsRejected() {
        let flat = SyntheticScreen(width: 600, height: 400, background: desktop).buffer
        let result = EdgeSnap.snap(in: flat, at: PixelPoint(x: 300, y: 200))
        #expect(!result.accepted, "a flat screen must not produce a snap, got \(result.rect)")
        #expect(!result.reason.isEmpty, "a rejection with no reason is a crash with a tidy face")
    }

    @Test("a seed on empty desktop beside a window is REJECTED")
    func desktopBesideWindowIsRejected() {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        s.fill(PixelRect.xywh(80, 60, 440, 280), windowFill)
        // Seed in the desktop margin. The fill runs to every image border.
        let result = EdgeSnap.snap(in: s.buffer, at: PixelPoint(x: 20, y: 200))
        #expect(!result.accepted, "reason was: \(result.reason)")
        #expect(result.reason.contains("border"))
    }

    @Test("a snap that covers almost the whole image is rejected")
    func wholeImageIsRejected() {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        // A window filling 96% of the screen, inset by 4 px so it does not
        // touch the border and the first rule cannot fire instead.
        s.fill(PixelRect.xywh(4, 4, 592, 392), windowFill)
        let result = EdgeSnap.snap(in: s.buffer, at: PixelPoint(x: 300, y: 200))
        #expect(!result.accepted, "reason was: \(result.reason)")
    }

    @Test("pressing snap again grows outward, never sideways and never smaller")
    func hierarchyGrowsOutward() {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        s.fill(PixelRect.xywh(80, 60, 440, 280), windowFill)
        s.control(PixelRect.xywh(200, 150, 120, 40), fill: controlFill, border: controlBorder)
        let result = EdgeSnap.snap(in: s.buffer, at: PixelPoint(x: 260, y: 170), maxLevels: 3)

        #expect(result.levels.count >= 1)
        for i in 1..<result.levels.count {
            let inner = result.levels[i - 1], outer = result.levels[i]
            #expect(outer.area > inner.area, "level \(i) did not grow")
            #expect(outer.intersection(inner).area == inner.area,
                    "level \(i) does not contain level \(i - 1), so the grow key jumps sideways")
        }
    }

    @Test("a seed outside the image is rejected rather than reading stray memory")
    func outOfBoundsSeed() {
        let buffer = screenWithOneButton(buttonRect: .xywh(200, 150, 120, 40))
        #expect(!EdgeSnap.snap(in: buffer, at: PixelPoint(x: 9999, y: 9999)).accepted)
        #expect(!EdgeSnap.snap(in: buffer, at: PixelPoint(x: -5, y: -5)).accepted)
    }

    /// The regression test for the bug that made edge snap useless on real
    /// windows, kept in the synthetic form so it runs in microseconds.
    ///
    /// MEASURED on real captures of Snapr's own windows: the flood fill found a
    /// **394x322** rectangle for a control that is about **395x330**, which is
    /// correct to within a few pixels, and the acceptance test then refused it
    /// with a reported side support of **0.02**.
    ///
    /// Two causes, both reproduced below. `snap` grows the flood bounds by one
    /// pixel before returning, so a two-touching-pixel test straddles a boundary
    /// that has already moved. And real macOS controls are rounded and
    /// anti-aliased, so the change in brightness is spread over two or three
    /// pixels instead of landing in a single step.
    ///
    /// Before the fix this test failed and `flatScreenIsRejected` passed. Both
    /// have to hold at once, which is the whole difficulty: the acceptance test
    /// must refuse empty desktop and accept a soft-edged control.
    @Test("a control with a SOFT anti-aliased edge is accepted, not thrown away")
    func softEdgedControlIsAccepted() {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        s.fill(PixelRect.xywh(80, 60, 440, 280), windowFill)

        // A control with a three-pixel gradient at its edge instead of a hard
        // border, which is what a real rounded, anti-aliased control looks like
        // to a pixel reader.
        let target = PixelRect.xywh(200, 150, 120, 40)
        // Steps of THREE, deliberately below the threshold of 4. A steeper ramp
        // does not reproduce the bug: the first attempt used steps of 10, the
        // old two-pixel test scored 1.00 on it, and the control correctly said
        // the test was proving nothing. Real vibrancy moves a shade or two per
        // pixel, which is exactly what slips under a single-step test.
        for (i, shade) in [60, 63, 66].enumerated() {
            s.fill(target.inset(by: i), SRGB(r: shade, g: shade, b: shade + 4))
        }
        s.fill(target.inset(by: 3), controlFill)

        let result = EdgeSnap.snap(in: s.buffer, at: target.centre)
        #expect(result.accepted,
                "a soft-edged control was refused with reason: \(result.reason)")
        #expect(result.rect.iou(target) > 0.8,
                "IoU \(result.rect.iou(target)), got \(result.rect), wanted \(target)")

        // The control. `band: 1` is the old two-touching-pixel behaviour. If it
        // ALSO passes, this test proves nothing and the fix was not the fix.
        let oldStyle = EdgeSnap.sideSupport(result.rect, in: s.buffer, band: 1)
        let newStyle = EdgeSnap.sideSupport(result.rect, in: s.buffer)
        #expect((oldStyle.min() ?? 0) < 0.30,
                "the old two-pixel test would have ACCEPTED this, so the fix is untested")
        #expect((newStyle.min() ?? 0) >= 0.30,
                "the banded test should see the soft edge, got \(newStyle)")
    }

    @Test("a one-pixel sliver is rejected as too small to be an element")
    func sliverRejected() {
        var s = SyntheticScreen(width: 600, height: 400, background: desktop)
        s.fill(PixelRect.xywh(80, 60, 440, 280), windowFill)
        s.fill(PixelRect.xywh(300, 200, 2, 2), controlFill)
        let result = EdgeSnap.snap(in: s.buffer, at: PixelPoint(x: 300, y: 200))
        #expect(!result.accepted, "reason was: \(result.reason)")
    }
}

@Suite("Text snapping")
struct TextSnapTests {

    /// MEASURED (probe A14): seeding inside a paragraph makes the flood return
    /// the whole content pane, which is genuinely the element under the point
    /// but not what the user wanted. The Vision line box under the seed scored
    /// IoU 0.995 against the true line, and grouping lines gave the paragraph
    /// at IoU 0.795.
    let lines = [
        PixelRect.xywh(100, 100, 400, 22),
        PixelRect.xywh(100, 130, 380, 22),
        PixelRect.xywh(100, 160, 420, 22),
        PixelRect.xywh(900, 100, 200, 22),   // a separate column, must not merge
    ]

    @Test("the smallest containing line wins")
    func lineUnderPoint() {
        #expect(TextSnap.line(at: PixelPoint(x: 200, y: 140), lines: lines)
                    == PixelRect.xywh(100, 130, 380, 22))
        #expect(TextSnap.line(at: PixelPoint(x: 700, y: 140), lines: lines) == nil)
    }

    @Test("grouping reaches the paragraph and stops at the other column")
    func blockGrouping() {
        let start = PixelRect.xywh(100, 130, 380, 22)
        let block = TextSnap.block(containing: start, lines: lines)
        #expect(block.y0 == 100)
        #expect(block.y1 == 182)
        #expect(block.x1 <= 520, "the separate column at x=900 must not be merged in")
    }

    @Test("a big vertical gap stops the grouping")
    func gapStopsGrouping() {
        let far = [PixelRect.xywh(100, 100, 400, 22), PixelRect.xywh(100, 500, 400, 22)]
        let block = TextSnap.block(containing: far[0], lines: far, maxGap: 30)
        #expect(block == far[0])
    }
}

@Suite("Pixel buffer sampling")
struct PixelBufferTests {

    @Test("out of bounds returns nil rather than a plausible colour")
    func outOfBounds() {
        // MEASURED (probe A15.4): the sentinel is the only reason a harness bug
        // in A15.1 was legible instead of reported as a colour failure.
        var s = SyntheticScreen(width: 100, height: 100, background: .white)
        s.fill(PixelRect.xywh(10, 10, 20, 20), .black)
        let b = s.buffer
        #expect(b.colour(x: -1, y: 0) == nil)
        #expect(b.colour(x: 100, y: 0) == nil)
        #expect(b.colour(x: 0, y: 100) == nil)
        #expect(b.colour(x: 15, y: 15) == .black)
    }

    @Test("the forgiving pick finds the dark pixel a user could not click")
    func darkestInBox() {
        var s = SyntheticScreen(width: 100, height: 100, background: .white)
        s.fill(PixelRect.xywh(50, 50, 1, 1), SRGB(r: 10, g: 10, b: 10))
        let b = s.buffer
        // Aim 4 px off the target, which is roughly how accurate a mouse is.
        #expect(b.darkestColour(around: PixelPoint(x: 54, y: 54), boxSize: 20)
                    == SRGB(r: 10, g: 10, b: 10))
        // Far away, it correctly finds only white.
        #expect(b.darkestColour(around: PixelPoint(x: 5, y: 5), boxSize: 20) == .white)
    }

    @Test("the modal colour ignores a single stray anti-aliased pixel")
    func modalColour() {
        var s = SyntheticScreen(width: 100, height: 100, background: .white)
        s.fill(PixelRect.xywh(40, 40, 20, 20), SRGB(r: 200, g: 30, b: 30))
        s.fill(PixelRect.xywh(50, 50, 1, 1), SRGB(r: 127, g: 127, b: 127))  // the stray
        let b = s.buffer
        let m = b.modalColour(around: PixelPoint(x: 50, y: 50), radius: 5)
        #expect(m?.colour == SRGB(r: 200, g: 30, b: 30))
    }
}
