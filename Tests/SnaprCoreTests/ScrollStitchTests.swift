import Foundation
import Testing
@testable import SnaprCore

/// Stitching is judged against ground truth, never by eye.
///
/// Every test here builds a tall page, slices viewports out of it the way a
/// scrolling window would, and demands the page back. That is the only way to
/// catch the failure that matters: a seam that quietly duplicates or drops a
/// few rows produces a perfectly normal looking screenshot that is wrong.
@Suite("Scroll stitch")
struct ScrollStitchTests {

    // MARK: - Fixtures

    /// A tall page where every row is identifiable.
    ///
    /// The row number is written into the pixels, so a stitched result can be
    /// checked row by row against where it should have come from. Noise across
    /// the columns stops any two rows describing the same, which is what makes
    /// a wrong match possible to detect rather than merely unlikely.
    static func page(width: Int, height: Int, seed: UInt64 = 12345) -> PixelBuffer {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var state = seed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // The low bits carry the row number, so a misplaced row is
                // visible in the value rather than only in a checksum.
                rgba[i] = UInt8(y & 0xFF)
                rgba[i + 1] = next()
                rgba[i + 2] = UInt8((y >> 8) & 0xFF)
                rgba[i + 3] = 255
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }

    /// A page that looks like a real document rather than a helpful fixture.
    ///
    /// Every line is the same sentence, in a band of rows, separated by blank
    /// rows, and only a short "line number" at the left differs between them.
    /// That is what a text file, a chat log or a table actually looks like, and
    /// it is much harder than noise: whole bands of rows are pixel-identical to
    /// bands elsewhere on the page.
    ///
    /// MEASURED on a real capture of TextEdit before this fixture existed: the
    /// original noise fixture passed everything, and the real run dropped eight
    /// lines at a seam and left one row a blend of two.
    static func documentPage(width: Int, height: Int,
                             lineHeight: Int = 24, inkRows: Int = 14) -> PixelBuffer {
        var rgba = [UInt8](repeating: 20, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }

        for y in 0..<height {
            let line = y / lineHeight
            let within = y % lineHeight
            guard within < inkRows else { continue }   // the gap between lines
            for x in 0..<width {
                let i = (y * width + x) * 4
                // The left quarter carries the line number, and is the ONLY
                // thing that distinguishes one line from another.
                let ink: Bool
                if x < width / 4 {
                    ink = ((line >> (x / 3 % 8)) & 1) == 1 && within % 3 != 0
                } else {
                    // The same sentence on every line, pixel for pixel.
                    ink = (x * 7 + within * 13) % 11 < 4
                }
                let v: UInt8 = ink ? 235 : 20
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }

    /// One viewport onto the page, as a capture of the region would see it.
    static func viewport(_ page: PixelBuffer, at y: Int, height: Int) -> PixelBuffer {
        let w = page.width
        let stride = w * 4
        let top = min(max(0, y), page.height - height)
        let rows = Array(page.rgba[(top * stride)..<((top + height) * stride)])
        return PixelBuffer(width: w, height: height, rgba: rows)
    }

    /// Paste a fixed band over the top or bottom of a viewport, the way a
    /// sticky toolbar sits over a scrolling document.
    static func withSticky(_ frame: PixelBuffer, top: Int, bottom: Int) -> PixelBuffer {
        var rgba = frame.rgba
        let w = frame.width
        for y in 0..<top {
            for x in 0..<w {
                let i = (y * w + x) * 4
                rgba[i] = 10; rgba[i + 1] = UInt8(20 + x % 30); rgba[i + 2] = 30
            }
        }
        for k in 0..<bottom {
            let y = frame.height - 1 - k
            for x in 0..<w {
                let i = (y * w + x) * 4
                rgba[i] = 200; rgba[i + 1] = UInt8(90 + x % 40); rgba[i + 2] = 60
            }
        }
        return PixelBuffer(width: w, height: frame.height, rgba: rgba)
    }

    /// Which page row each row of the result came from, read back out of the
    /// pixels the fixture encoded.
    static func rowIDs(_ buffer: PixelBuffer) -> [Int] {
        (0..<buffer.height).map { y in
            let i = (y * buffer.width) * 4
            return Int(buffer.rgba[i]) | (Int(buffer.rgba[i + 2]) << 8)
        }
    }

    // MARK: - Offset

    @Test("a plain scroll is measured exactly")
    func exactOffset() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.viewport(doc, at: 100, height: 300)
        for dy in [1, 7, 40, 120, 200] {
            let b = Self.viewport(doc, at: 100 + dy, height: 300)
            #expect(ScrollStitch.offset(from: a, to: b) == .scrolled(dy),
                    "a \(dy) row scroll was not measured as \(dy)")
        }
    }

    @Test("two identical frames are still, not a zero scroll")
    func noMovement() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.viewport(doc, at: 100, height: 300)
        #expect(ScrollStitch.offset(from: a, to: a) == .still)
    }

    @Test("scrolling back up is reported, not mistaken for progress")
    func rewind() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.viewport(doc, at: 300, height: 300)
        let b = Self.viewport(doc, at: 260, height: 300)
        // A rubber-band bounce at the end of a page does this, so it has to be
        // something other than a scroll forward.
        let step = ScrollStitch.offset(from: a, to: b)
        #expect(step != .scrolled(40))
        #expect(step == .lost || step == .rewound)
    }

    @Test("a jump with no overlap left is refused rather than guessed")
    func noOverlap() {
        let doc = Self.page(width: 320, height: 2000)
        let a = Self.viewport(doc, at: 0, height: 300)
        let b = Self.viewport(doc, at: 1200, height: 300)
        #expect(ScrollStitch.offset(from: a, to: b) == .lost)
    }

    @Test("a page of one flat colour is refused, not matched at random")
    func flatContent() {
        // Every offset fits equally well here. Picking one would silently
        // duplicate or drop rows, and there would be nothing on screen to say
        // it had happened.
        let flat = PixelBuffer(width: 200, height: 300,
                               rgba: [UInt8](repeating: 240, count: 200 * 300 * 4))
        #expect(ScrollStitch.offset(from: flat, to: flat) == .still)

        var shifted = flat.rgba
        // One faint mark, far too small to make any offset unambiguous.
        for x in 100..<104 { shifted[(150 * 200 + x) * 4] = 238 }
        let other = PixelBuffer(width: 200, height: 300, rgba: shifted)
        let step = ScrollStitch.offset(from: flat, to: other)
        #expect(step == .still || step == .lost,
                "a featureless page produced a confident scroll of \(step)")
    }

    // MARK: - Sticky bands

    @Test("a sticky header and footer are measured")
    func stickyDetected() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.withSticky(Self.viewport(doc, at: 100, height: 300), top: 24, bottom: 16)
        let b = Self.withSticky(Self.viewport(doc, at: 180, height: 300), top: 24, bottom: 16)

        let bands = ScrollStitch.stickyBands(a, b)
        #expect(bands.top == 24)
        #expect(bands.bottom == 16)
    }

    @Test("no sticky bands are found where there are none")
    func noSticky() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.viewport(doc, at: 100, height: 300)
        let b = Self.viewport(doc, at: 180, height: 300)
        let bands = ScrollStitch.stickyBands(a, b)
        #expect(bands.top == 0)
        #expect(bands.bottom == 0)
    }

    @Test("a scroll under a sticky toolbar is still measured exactly")
    func offsetWithSticky() {
        let doc = Self.page(width: 320, height: 900)
        let a = Self.withSticky(Self.viewport(doc, at: 100, height: 300), top: 24, bottom: 16)
        let b = Self.withSticky(Self.viewport(doc, at: 190, height: 300), top: 24, bottom: 16)

        // Without excluding the bands, the fixed toolbar rows match at every
        // offset and drag the score towards no movement at all.
        #expect(ScrollStitch.offset(from: a, to: b, stickyTop: 24, stickyBottom: 16)
                == .scrolled(90))
    }

    // MARK: - The whole thing

    /// Scroll a viewport down a page in steps and demand the page back.
    private func stitchThrough(pageHeight: Int, viewport vh: Int,
                               steps: [Int], sticky: (top: Int, bottom: Int) = (0, 0))
    -> (result: PixelBuffer, doc: PixelBuffer) {
        let doc = Self.page(width: 240, height: pageHeight)
        func frame(_ y: Int) -> PixelBuffer {
            let v = Self.viewport(doc, at: y, height: vh)
            guard sticky.top > 0 || sticky.bottom > 0 else { return v }
            return Self.withSticky(v, top: sticky.top, bottom: sticky.bottom)
        }
        var y = 0
        var stitcher = ScrollStitcher(first: frame(y))
        for step in steps {
            y += step
            stitcher.add(frame(y))
        }
        return (stitcher.finish(), doc)
    }

    @Test("an even scroll rebuilds the page exactly, with no seam")
    func evenScroll() {
        let vh = 300
        let (result, doc) = stitchThrough(pageHeight: 1200, viewport: vh,
                                          steps: Array(repeating: 100, count: 9))
        #expect(result.height == vh + 900)
        #expect(result.height <= doc.height)

        // Every row of the result must be the page row it should be. This is
        // the assertion that catches a one row duplicate at a seam, which is
        // the bug that survives every "it looks fine" review.
        let ids = Self.rowIDs(result)
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) of the result came from page row \(id)")
        }
    }

    @Test("an uneven, hand-driven scroll rebuilds the page exactly")
    func unevenScroll() {
        // What a trackpad actually produces: acceleration, a pause, a flick.
        // Every step stays inside the two thirds of the frame that can be
        // followed; `aScrollTooFastToFollowIsRefusedNotGuessed` covers the rest.
        let steps = [12, 40, 95, 160, 195, 0, 0, 8, 3, 140, 60]
        let (result, _) = stitchThrough(pageHeight: 1400, viewport: 300, steps: steps)
        let expected = 300 + steps.reduce(0, +)
        #expect(result.height == expected)

        let ids = Self.rowIDs(result)
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) of the result came from page row \(id)")
        }
    }

    @Test("a sticky toolbar appears once at the top and once at the bottom")
    func stickyStitch() {
        let vh = 300
        let top = 24, bottom = 16
        let (result, _) = stitchThrough(pageHeight: 1200, viewport: vh,
                                        steps: Array(repeating: 90, count: 8),
                                        sticky: (top, bottom))

        let ids = Self.rowIDs(result)
        // The header band, once, at the very top. Its encoded row id is the
        // fixed colour the fixture paints, not a page row.
        let headerID = 10 | (30 << 8)
        #expect(ids.prefix(top).allSatisfy { $0 == headerID })

        let footerID = 200 | (60 << 8)
        #expect(ids.suffix(bottom).allSatisfy { $0 == footerID })

        // And nowhere in between. A sticky footer pasted once per frame is the
        // headline failure of a naive stitcher: a toolbar stamped through the
        // middle of the document, eight times over.
        let middle = ids.dropFirst(top).dropLast(bottom)
        #expect(!middle.contains(footerID),
                "the sticky footer was stamped into the middle of the page")
        #expect(!middle.contains(headerID),
                "the sticky header was stamped into the middle of the page")

        // The content in between is continuous, in order, with no gaps.
        let content = Array(middle)
        for i in 1..<content.count {
            #expect(content[i] == content[i - 1] + 1,
                    "a seam at result row \(i + top): \(content[i - 1]) then \(content[i])")
        }
    }

    @Test("a pause adds nothing at all")
    func pauseAddsNothing() {
        let doc = Self.page(width: 240, height: 900)
        let first = Self.viewport(doc, at: 0, height: 300)
        var stitcher = ScrollStitcher(first: first)
        for _ in 0..<10 {
            #expect(stitcher.add(first) == .still)
        }
        #expect(stitcher.finish().height == 300, "a still frame added rows")
        #expect(stitcher.dropped == 10)
    }

    @Test("hitting the bottom of the page stops adding rows")
    func endOfPage() {
        // `viewport` clamps, so asking for more once the page has run out gives
        // the same frame again. That is exactly what a real window does, and it
        // must not keep pasting the last screen over and over.
        let (result, doc) = stitchThrough(pageHeight: 700, viewport: 300,
                                          steps: Array(repeating: 100, count: 12))
        #expect(result.height == doc.height,
                "the stitcher ran past the end of the page: \(result.height) vs \(doc.height)")
        let ids = Self.rowIDs(result)
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) of the result came from page row \(id)")
        }
    }

    /// Dim a frame the way the selection overlay does while it is fading out.
    static func dimmed(_ frame: PixelBuffer, by factor: Double = 0.45) -> PixelBuffer {
        var rgba = frame.rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            for c in 0..<3 { rgba[i + c] = UInt8(Double(rgba[i + c]) * factor) }
        }
        return PixelBuffer(width: frame.width, height: frame.height, rgba: rgba)
    }

    @Test("a base frame taken through the fading overlay is thrown away, not kept")
    func rebaseOffABadFirstFrame() {
        // MEASURED on the running app before this existed: the first frame of a
        // run is captured while the selection overlay still dims the screen. It
        // matched nothing, and because a refused frame never replaces the
        // reference, every later frame was refused too. 134 frames in, 133
        // refused, one frame out. `isEmpty` is what lets the caller tell that
        // the BASE is the wrong one while there is still nothing to lose.
        let doc = Self.page(width: 240, height: 1200)
        var stitcher = ScrollStitcher(first: Self.dimmed(Self.viewport(doc, at: 0, height: 300)))
        #expect(stitcher.isEmpty)

        #expect(stitcher.add(Self.viewport(doc, at: 0, height: 300)) == .lost)
        #expect(stitcher.isEmpty, "a refused frame must leave the run restartable")

        // What the session does with that: start again from the clean frame.
        stitcher = ScrollStitcher(first: Self.viewport(doc, at: 0, height: 300))
        for y in stride(from: 100, through: 600, by: 100) {
            #expect(stitcher.add(Self.viewport(doc, at: y, height: 300)) == .scrolled(100))
        }
        #expect(stitcher.isEmpty == false)

        let ids = Self.rowIDs(stitcher.finish())
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) came from page row \(id) after the rebase")
        }
    }

    @Test("a run stops being restartable once it has stitched anything")
    func notEmptyAfterFirstJoin() {
        let doc = Self.page(width: 240, height: 900)
        var stitcher = ScrollStitcher(first: Self.viewport(doc, at: 0, height: 300))
        #expect(stitcher.isEmpty)
        stitcher.add(Self.viewport(doc, at: 50, height: 300))
        // Throwing the base away now would silently drop the rows already
        // joined on, so the caller must not be told it is safe.
        #expect(stitcher.isEmpty == false)
    }

    // MARK: - Repetitive content, which is what real pages look like

    @Test("a scroll down a page of near-identical lines is measured exactly")
    func offsetOnRepetitiveContent() {
        let doc = Self.documentPage(width: 400, height: 2000)
        let a = Self.viewport(doc, at: 240, height: 500)
        // A blank gap between lines is pixel-identical to every other gap, so a
        // band that lands on one matches in dozens of places at once. Picking
        // any of them is a coin toss, and picking the nearest silently DROPS
        // the content in between.
        for dy in [24, 48, 96, 216, 300] {
            let b = Self.viewport(doc, at: 240 + dy, height: 500)
            #expect(ScrollStitch.offset(from: a, to: b) == .scrolled(dy),
                    "a \(dy) row scroll down a repetitive page was mismeasured")
        }
    }

    @Test("a repetitive page is rebuilt with no line dropped or repeated")
    func stitchRepetitivePage() {
        let doc = Self.documentPage(width: 400, height: 2400)
        func frame(_ y: Int) -> PixelBuffer { Self.viewport(doc, at: y, height: 500) }

        var y = 0
        var stitcher = ScrollStitcher(first: frame(0))
        // Jumps that are not multiples of the line height, because a hand never
        // scrolls in whole lines.
        for step in [96, 216, 168, 240, 144, 288, 192, 120, 264, 150] {
            y += step
            #expect(stitcher.add(frame(y)) == .scrolled(step),
                    "step to \(y) was mismeasured")
        }
        let result = stitcher.finish()
        #expect(result.height == 500 + 1878)

        // Compare against the page itself, row for row. This is the assertion
        // that a real capture failed: eight lines vanished at one seam and the
        // row at the join was a blend of two different lines.
        for row in stride(from: 0, to: result.height, by: 7) {
            let a = result.rgba[(row * 400 * 4)..<((row + 1) * 400 * 4)]
            let b = doc.rgba[(row * 400 * 4)..<((row + 1) * 400 * 4)]
            #expect(Array(a) == Array(b), "result row \(row) is not page row \(row)")
        }
    }

    @Test("a scroll too fast to follow is refused, not guessed, and then recovered")
    func aScrollTooFastToFollowIsRefusedNotGuessed() {
        // More than two thirds of the frame in one step leaves too little in
        // common to be sure of, so the frame is refused. That is the deliberate
        // trade: a refused frame costs nothing, because the next one is measured
        // against the last good frame, while a wrong match corrupts the result
        // in a way nobody can see.
        let doc = Self.page(width: 240, height: 2000)
        var stitcher = ScrollStitcher(first: Self.viewport(doc, at: 0, height: 300))

        #expect(stitcher.add(Self.viewport(doc, at: 260, height: 300)) == .lost,
                "a scroll of 260 out of 300 rows should be refused")
        // The user slows down. The offset is now measured from the last GOOD
        // frame, so it is the whole distance travelled, and nothing is missing.
        #expect(stitcher.add(Self.viewport(doc, at: 150, height: 300)) == .scrolled(150))

        let ids = Self.rowIDs(stitcher.finish())
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) came from page row \(id)")
        }
    }

    @Test("a frame that cannot be placed is dropped, and the run recovers")
    func lostFrameRecovers() {
        let doc = Self.page(width: 240, height: 1200)
        var stitcher = ScrollStitcher(first: Self.viewport(doc, at: 0, height: 300))

        stitcher.add(Self.viewport(doc, at: 100, height: 300))
        // A menu opens over the region, or the content is replaced for a moment.
        let noise = Self.page(width: 240, height: 300, seed: 999)
        #expect(stitcher.add(noise) == .lost)
        // The next real frame is measured against the last GOOD one, so the run
        // carries on instead of ending at the first hiccup.
        stitcher.add(Self.viewport(doc, at: 200, height: 300))

        let result = stitcher.finish()
        #expect(result.height == 500)
        let ids = Self.rowIDs(result)
        for (i, id) in ids.enumerated() {
            #expect(id == i, "row \(i) came from page row \(id) after a lost frame")
        }
    }
}

/// The page that a real text editor actually shows.
///
/// MEASURED on a live automatic scrolling capture of TextEdit, from the app's
/// own log:
///
///     refused frame, bestDY=520  best=0   second=282 median=36295
///     refused frame, bestDY=1040 best=0   second=324 median=36275
///     refused frame, bestDY=1040 best=319 second=329 median=36245
///
/// The first two are EXACT matches, scoring a perfect zero, and both were
/// refused. The third really is ambiguous and was refused correctly.
///
/// `documentPage` never caught this because it writes a line number across the
/// whole left quarter, so two neighbouring lines look very different. A real
/// document is the opposite: "line 0041 the quick brown fox..." differs from
/// the line below it by two digits in seventy characters, so the runner-up
/// offset scores almost as well as the truth and the winner's margin is thin in
/// absolute terms while being decisive in kind.
@Suite("Scroll stitch, near-identical lines")
struct ScrollStitchNarrowMarginTests {

    /// Lines that are identical except for a short counter at the left margin.
    static func editorPage(width: Int, height: Int,
                           lineHeight: Int = 26, inkRows: Int = 15) -> PixelBuffer {
        var rgba = [UInt8](repeating: 20, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
        // Narrow on purpose. This is the only thing that separates one line
        // from the next, exactly as a line number is.
        let counterWidth = 34

        for y in 0..<height {
            let line = y / lineHeight
            let within = y % lineHeight
            guard within < inkRows else { continue }
            for x in 0..<width {
                let i = (y * width + x) * 4
                let ink: Bool
                if x < counterWidth {
                    ink = ((line >> ((x / 4) % 8)) & 1) == 1 && within % 4 != 0
                } else {
                    // Byte for byte the same sentence on every single line.
                    ink = (x &* 7 &+ within &* 13) % 11 < 4
                }
                let v: UInt8 = ink ? 235 : 20
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }

    @Test("an exact match on a page of near-identical lines is accepted")
    func exactMatchIsAccepted() {
        let page = Self.editorPage(width: 720, height: 3000)
        let h = 780
        let previous = ScrollStitchTests.viewport(page, at: 0, height: h)

        // Whole multiples of the line height, which is what a real scroll of a
        // text view lands on and what produced the measured numbers. 520 is the
        // largest offset the stitcher will look for at this frame height, since
        // it insists on a third of the frame in common.
        for dy in [130, 260, 520] {
            let current = ScrollStitchTests.viewport(page, at: dy, height: h)
            let step = ScrollStitch.offset(from: previous, to: current)
            let d = ScrollStitch.lastDiagnosis
            #expect(step == .scrolled(dy),
                    """
                    dy=\(dy) got \(step). \
                    best=\(d?.best ?? -1) second=\(d?.second ?? -1) \
                    median=\(d?.median ?? -1) bestDY=\(d?.bestDY ?? -1)
                    """)
        }
    }

    @Test("a run of such a page is rebuilt with no line lost")
    func aRunIsRebuilt() {
        let page = Self.editorPage(width: 720, height: 4000)
        // A third of the frame, which is what the app aims for. 520 was tried
        // and it is the cliff edge: at two thirds of the frame the overlap is
        // down to the ten lines the stitcher insists on, one frame is refused,
        // and from then on every frame is two steps away and out of range for
        // good. That is a fact about the algorithm, not a bug, and it is why
        // the automatic scroll step is set well below the limit.
        let h = 780, step = 260
        var stitcher = ScrollStitcher(first: ScrollStitchTests.viewport(page, at: 0, height: h))
        var y = 0
        while y + step + h <= page.height {
            y += step
            stitcher.add(ScrollStitchTests.viewport(page, at: y, height: h))
        }
        let out = stitcher.finish()
        #expect(out.height == y + h, "expected \(y + h) rows, got \(out.height)")

        // Every row of the result must be the row of the page it came from.
        var wrong = 0
        for row in 0..<out.height {
            for x in stride(from: 0, to: out.width, by: 37) {
                if out.rgba[(row * out.width + x) * 4] != page.rgba[(row * page.width + x) * 4] {
                    wrong += 1; break
                }
            }
        }
        #expect(wrong == 0, "\(wrong) of \(out.height) rows came from the wrong place")
    }
}

/// A page with a bar bolted to the top and another bolted to the bottom.
///
/// MEASURED in Safari, on a local page with a `position: fixed` header and a
/// `position: fixed` footer, captured with a region that included both:
///
///     266 frames captured, 0 refused, 223 restarted, 42 unchanged  -> nothing
///
/// The identical region with the two bars left outside it:
///
///     128 frames, 0 refused, 0 rebased                             -> stitched
///
/// So it is the bars, not Safari's momentum scrolling. A band that stays put
/// while the rest of the page moves disagrees with the content at EVERY
/// candidate offset, the true one included, so the winner no longer scores near
/// zero and the ratio test refuses the frame. Nothing is accepted, so the bands
/// are never measured, so nothing is ever accepted.
@Suite("Scroll stitch, sticky bars")
struct ScrollStitchStickyDeadlockTests {

    static func framed(_ page: PixelBuffer, at y: Int, height: Int,
                       top: Int, bottom: Int) -> PixelBuffer {
        ScrollStitchTests.withSticky(
            ScrollStitchTests.viewport(page, at: y, height: height),
            top: top, bottom: bottom)
    }

    @Test("a page with a fixed header and footer still stitches")
    func stickyBarsDoNotDeadlock() {
        let page = ScrollStitchNarrowMarginTests.editorPage(width: 720, height: 4000)
        let h = 780, step = 260
        // Proportions taken from the Safari fixture: a 56 point header and a
        // 44 point footer on a 826 point region, doubled for a Retina display.
        let top = 106, bottom = 83

        var stitcher = ScrollStitcher(first: Self.framed(page, at: 0, height: h,
                                                         top: top, bottom: bottom))
        var y = 0
        var accepted = 0
        while y + step + h <= page.height {
            y += step
            if case .scrolled = stitcher.add(Self.framed(page, at: y, height: h,
                                                         top: top, bottom: bottom)) {
                accepted += 1
            }
        }
        #expect(accepted >= 10, "only \(accepted) frames were accepted")

        let out = stitcher.finish()
        #expect(out.height > h * 3, "result is only \(out.height) rows tall")

        // The bars must appear once each, not once per frame. The header is the
        // dark blue band and the footer the orange one, both written by
        // `withSticky`, and both are unmistakable in the red channel.
        func rowIsHeader(_ row: Int) -> Bool {
            out.rgba[(row * out.width + 40) * 4] == 10
        }
        func rowIsFooter(_ row: Int) -> Bool {
            out.rgba[(row * out.width + 40) * 4] == 200
        }
        let headerRows = (0..<out.height).filter(rowIsHeader).count
        let footerRows = (0..<out.height).filter(rowIsFooter).count
        #expect(headerRows == top, "header appears on \(headerRows) rows, expected \(top)")
        #expect(footerRows == bottom, "footer appears on \(footerRows) rows, expected \(bottom)")
    }
}
