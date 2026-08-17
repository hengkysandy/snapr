import Foundation

/// Joins a run of captures of the same region into one tall image, while the
/// user scrolls the content underneath.
///
/// The whole algorithm lives here, with no AppKit and no capture, because this
/// is the one part that can be wrong in ways nobody notices. A seam that
/// duplicates four rows of a paragraph, or drops them, looks like a perfectly
/// normal screenshot until somebody reads it. The tests build a tall page,
/// slice viewports out of it, and demand the original back.
public enum ScrollStitch {

    /// What one new frame turned out to be.
    public enum Step: Equatable, Sendable {
        /// Identical to the frame before it. The user has not scrolled yet, or
        /// has stopped. Dropped, and not an error.
        case still
        /// Content moved up by this many rows, so that many new rows arrived at
        /// the bottom.
        case scrolled(Int)
        /// The content moved backwards, which is a rubber-band bounce at the end
        /// of a page or the user scrolling up again. Dropped rather than
        /// treated as an error, because it is a normal thing for a hand to do.
        case rewound
        /// No overlap could be found. Either the jump was more than the search
        /// window allows, or the content underneath changed rather than moved.
        case lost
    }

    // MARK: - Row descriptors
    //
    // Rows are compared through a short descriptor rather than pixel by pixel.
    // A full comparison of every candidate offset is O(height^2 * width), which
    // is 640 million operations for an ordinary 1000x800 region. Eight block
    // sums per row bring that to about 5 million, and the winner is verified
    // against real pixels afterwards.
    //
    // Sums, not a hash. A hash is faster to compare but has no notion of
    // "close", and a scroll that re-renders text at a slightly different
    // sub-pixel position changes a few luma values without changing the
    // content. A hash calls that a total mismatch; a sum barely notices.

    static let blocks = 8
    /// How many consecutive rows are matched as one unit. Long enough that a
    /// blank run cannot masquerade as content, short enough to leave room for a
    /// large jump.
    static let bandRows = 24

    struct Descriptors {
        let height: Int
        /// `blocks` sums per row, row-major.
        let sums: [Int32]
    }

    static func describe(_ buffer: PixelBuffer) -> Descriptors {
        let w = buffer.width, h = buffer.height
        var sums = [Int32](repeating: 0, count: h * blocks)
        guard w > 0, h > 0 else { return Descriptors(height: h, sums: sums) }

        buffer.luma.withUnsafeBufferPointer { luma in
            for y in 0..<h {
                let row = y * w
                let out = y * blocks
                for b in 0..<blocks {
                    // Split by index rather than a fixed block width, so a width
                    // that does not divide by eight still covers every column.
                    let x0 = b * w / blocks
                    let x1 = (b + 1) * w / blocks
                    var total: Int32 = 0
                    for x in x0..<x1 { total += Int32(luma[row + x]) }
                    sums[out + b] = total
                }
            }
        }
        return Descriptors(height: h, sums: sums)
    }

    private static func rowDistance(_ a: Descriptors, _ ay: Int,
                                    _ b: Descriptors, _ by: Int) -> Int {
        var total = 0
        let ao = ay * blocks, bo = by * blocks
        for i in 0..<blocks {
            total += abs(Int(a.sums[ao + i]) - Int(b.sums[bo + i]))
        }
        return total
    }

    // MARK: - Sticky bands

    /// Rows at the top and bottom that stay put while the middle moves.
    ///
    /// A sticky header is harmless if it is only ever taken from the first
    /// frame. A sticky FOOTER is the dangerous one: without this it would be
    /// pasted into the middle of the finished image once per frame, which reads
    /// as a toolbar stamped through the middle of a document.
    ///
    /// Measured by identity in place, because a band that does not move is
    /// exactly what "sticky" means. The caller only trusts the result when the
    /// frame really did move, since two identical frames would otherwise report
    /// the whole height as sticky.
    static func stickyBands(_ previous: PixelBuffer,
                            _ current: PixelBuffer) -> (top: Int, bottom: Int) {
        let h = min(previous.height, current.height)
        guard h > 0, previous.width == current.width else { return (0, 0) }
        // A quarter each. Anything more is far more likely to be a page of one
        // flat colour than a real toolbar, and over-reporting a sticky footer
        // silently deletes content from the result.
        let cap = max(0, h / 4)

        var top = 0
        while top < cap, sameRow(previous, top, current, top) { top += 1 }

        var bottom = 0
        while bottom < cap,
              sameRow(previous, h - 1 - bottom, current, h - 1 - bottom) { bottom += 1 }

        return (top, bottom)
    }

    private static func sameRow(_ a: PixelBuffer, _ ay: Int,
                                _ b: PixelBuffer, _ by: Int) -> Bool {
        guard a.width == b.width else { return false }
        let w = a.width
        let ao = ay * w, bo = by * w
        for x in 0..<w where a.luma[ao + x] != b.luma[bo + x] { return false }
        return true
    }

    // MARK: - Offset search

    /// The smallest overlap worth trusting, as a fraction of the usable height.
    ///
    /// A candidate that leaves only a sliver in common can score a perfect zero
    /// by having almost nothing to disagree about. MEASURED on the repetitive
    /// fixture with an eighth of the frame as the floor: a frame had TWO exact
    /// matches, the true offset and a two-line sliver elsewhere on the page,
    /// and the ambiguity test correctly refused a frame it should have been
    /// sure about.
    ///
    /// A third of the frame caps the scroll that can be followed at two thirds
    /// of the region per frame, which is about 5800 pixels a second at the
    /// capture rate. Beyond that the frame is refused, and being refused is
    /// safe: the next frame is measured against the last good one, so nothing
    /// is lost. A wrong match is not safe, so the floor is set for that.
    static let minOverlapFraction = 3

    /// How far the content moved between two frames of the same region.
    ///
    /// Positive means the content moved up, which is what scrolling down does,
    /// and that many new rows arrived at the bottom.
    ///
    /// Every candidate offset is scored over the WHOLE overlap, not over a band
    /// near the top. That costs about five million integer operations for an
    /// ordinary region, which is a few milliseconds, and it is the difference
    /// between working and not.
    ///
    /// MEASURED on a real capture of TextEdit: a band of 24 rows lands in the
    /// blank gap between two lines of text, and a blank gap is pixel-identical
    /// to every other blank gap on the page. Dozens of offsets scored a perfect
    /// zero, the smallest won, and a 216 row scroll was recorded as 24. Eight
    /// lines of the document vanished at that seam and the row at the join was
    /// a blend of two different lines. Scoring the whole overlap makes a wrong
    /// offset disagree on every line of the frame instead of agreeing on one
    /// unlucky gap.
    public static func offset(from previous: PixelBuffer,
                              to current: PixelBuffer,
                              stickyTop: Int = 0,
                              stickyBottom: Int = 0) -> Step {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.width > 0 else { return .lost }

        let usableEnd = current.height - stickyBottom
        let usable = usableEnd - stickyTop
        let minOverlap = max(64, usable / minOverlapFraction)
        guard usable > minOverlap else { return .lost }

        let a = describe(previous)
        let b = describe(current)

        // Mean distance per overlapping row, so a candidate cannot win simply by
        // overlapping less and having less to disagree about.
        let maxDY = usable - minOverlap
        var means = [Int](repeating: Int.max, count: maxDY + 1)
        for dy in 0...maxDY {
            let rows = usable - dy
            var total = 0
            for k in 0..<rows {
                total += rowDistance(a, stickyTop + dy + k, b, stickyTop + k)
            }
            means[dy] = total / rows
        }

        // Nothing moved is checked first and on its own terms. It is the most
        // common frame in a run, because a hand scrolls in bursts and pauses in
        // between, and putting it through the ambiguity test below would refuse
        // every pause on a page without much contrast. Appending nothing is
        // also the safe answer when the page is too plain to read: the worst it
        // can do is miss content, never invent it.
        if means[0] == 0,
           verify(previous, current, dy: 0, stickyTop: stickyTop, stickyBottom: stickyBottom) {
            lastDiagnosis = Diagnosis(best: 0, bestDY: 0, second: Int.max,
                                      median: means.sorted()[means.count / 2], verified: true)
            return .still
        }

        let best = means.min()!
        let bestDY = means.firstIndex(of: best)!

        // The runner-up, from a genuinely different offset. Neighbours of the
        // winner always score similarly and say nothing about ambiguity.
        var second = Int.max
        for (dy, m) in means.enumerated() where abs(dy - bestDY) > bandRows {
            second = min(second, m)
        }

        let median = means.sorted()[means.count / 2]
        let spread = median - best
        lastDiagnosis = Diagnosis(best: best, bestDY: bestDY, second: second,
                                  median: median, verified: false)

        // Two conditions, and both are needed.
        //
        // The RATIO is what actually separates a real match from a rival: the
        // truth usually scores zero, because a scrolled view blits its pixels
        // rather than redrawing them, while the nearest wrong offset on a page
        // of text still disagrees on every line number. MEASURED on the
        // repetitive fixture: 0 against 572.
        //
        // The SPREAD stops that ratio being read into noise. On a page of one
        // flat colour every offset scores about the same, so the median
        // collapses onto the winner and a gap of one unit would otherwise look
        // like a decisive win.
        guard spread > 0 else { return .lost }
        if second != Int.max {
            guard second > best * 3, second - best > spread / 100 else { return .lost }
        }

        let ok = verify(previous, current, dy: bestDY,
                        stickyTop: stickyTop, stickyBottom: stickyBottom)
        lastDiagnosis?.verified = ok
        guard ok else { return .lost }

        return bestDY == 0 ? .still : .scrolled(bestDY)
    }

    /// The numbers behind the last decision, for probes and for a failing test.
    ///
    /// Kept because this algorithm is judged on numbers, not on appearance, and
    /// "it returned lost" is not enough to tell a bad gate from a bad match.
    public struct Diagnosis: Sendable {
        public var best: Int
        public var bestDY: Int
        public var second: Int
        public var median: Int
        public var verified: Bool
    }

    nonisolated(unsafe) public private(set) static var lastDiagnosis: Diagnosis?

    /// Check the winning offset against real pixels, not descriptors.
    ///
    /// Eight sums per row throw away where in the row the ink was, so two very
    /// different rows can describe identically. This is cheap because it only
    /// ever runs once per frame, on the one candidate that won.
    private static func verify(_ previous: PixelBuffer, _ current: PixelBuffer,
                               dy: Int, stickyTop: Int, stickyBottom: Int) -> Bool {
        let h = current.height, w = current.width
        let from = stickyTop
        let to = h - stickyBottom - dy
        guard to > from else { return false }

        // Sample rows across the whole overlap rather than a run of adjacent
        // ones, so a single matching paragraph cannot carry a wrong offset.
        let samples = 16
        var checked = 0
        var mismatched = 0
        for s in 0..<samples {
            let y = from + (to - from) * s / samples
            guard y + dy < h else { continue }
            checked += 1
            var wrong = 0
            let ao = (y + dy) * w, bo = y * w
            for x in stride(from: 0, to: w, by: 3) {
                // A tolerance per pixel, because a re-rendered row can differ by
                // a shade without being different content.
                if abs(Int(previous.luma[ao + x]) - Int(current.luma[bo + x])) > 12 {
                    wrong += 1
                }
            }
            // A tenth of the sampled columns may differ. A cursor, a caret, or a
            // hover highlight moves without the page moving.
            if wrong * 10 > w / 3 { mismatched += 1 }
        }
        guard checked > 0 else { return false }
        return mismatched * 4 <= checked
    }
}

/// Accumulates frames into one tall image.
///
/// Deliberately incremental rather than keeping every frame. A long page is
/// sixty captures, and holding them all would be around 190 MB before any
/// stitching started.
public struct ScrollStitcher: Sendable {

    public let width: Int
    /// Height of the region being captured, not of the result.
    public let frameHeight: Int

    public private(set) var height: Int
    public private(set) var rgba: [UInt8]

    public private(set) var stickyTop = 0
    public private(set) var stickyBottom = 0
    private var stickyKnown = false

    public private(set) var accepted = 1
    public private(set) var dropped = 0

    /// True while the base frame is still the only thing here.
    ///
    /// The caller uses this to decide that a frame which cannot be matched
    /// means the BASE is wrong, not the new frame. That is not a hypothetical:
    /// the first frame of a run is grabbed while the selection overlay is still
    /// on screen dimming everything, and a dimmed frame can never match a clean
    /// one. Every later frame is then refused and the run produces nothing.
    /// Starting again costs nothing while this is true.
    public var isEmpty: Bool { accepted == 1 }

    private var previous: PixelBuffer

    public init(first: PixelBuffer) {
        self.width = first.width
        self.frameHeight = first.height
        self.height = first.height
        self.rgba = first.rgba
        self.previous = first
    }

    /// Feed the next capture. The return value is for the on-screen readout, so
    /// the user can see it following along rather than guessing.
    @discardableResult
    public mutating func add(_ frame: PixelBuffer) -> ScrollStitch.Step {
        guard frame.width == width, frame.height == frameHeight else { return .lost }

        let step = ScrollStitch.offset(from: previous, to: frame,
                                       stickyTop: stickyTop, stickyBottom: stickyBottom)

        guard case .scrolled(let dy) = step else {
            if step == .still || step == .rewound { dropped += 1 }
            // The previous frame is NOT replaced on a lost frame. A frame we
            // could not place is the wrong thing to measure the next one
            // against, and keeping the last good one lets a brief hiccup, a
            // menu opening or a tooltip, recover on its own.
            if step == .still { previous = frame }
            return step
        }

        if !stickyKnown {
            // Measured on the first frame pair that really moved. Two identical
            // frames would report the entire height as sticky, so it cannot be
            // done before this point.
            let bands = ScrollStitch.stickyBands(previous, frame)
            stickyTop = bands.top
            stickyBottom = bands.bottom
            stickyKnown = true
            // The first frame was appended whole, including a sticky footer that
            // is about to be pasted over by real content. Trim it once, here,
            // rather than leaving a toolbar buried in the finished image.
            if stickyBottom > 0 {
                rgba.removeLast(stickyBottom * width * 4)
                height -= stickyBottom
            }
        }

        // New content is the rows that arrived at the bottom, above any sticky
        // footer. The footer itself is added once at the end, from the last
        // frame, by `finish`.
        let end = frameHeight - stickyBottom
        let start = max(0, end - dy)
        guard end > start else { return .still }
        appendRows(of: frame, from: start, to: end)
        previous = frame
        accepted += 1
        return .scrolled(end - start)
    }

    /// The finished image. Adds the sticky footer back, once, from the last
    /// frame seen.
    public mutating func finish() -> PixelBuffer {
        if stickyBottom > 0 {
            appendRows(of: previous, from: frameHeight - stickyBottom, to: frameHeight)
            stickyBottom = 0
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }

    private mutating func appendRows(of frame: PixelBuffer, from: Int, to: Int) {
        let stride = width * 4
        rgba.append(contentsOf: frame.rgba[(from * stride)..<(to * stride)])
        height += to - from
    }
}
