import Foundation

/// Snap a rough selection to the UI element under it.
///
/// MEASURED (probe A14) against 11 ground-truth elements, two seeds each:
///
/// | technique                       | mean IoU | IoU > 0.9 | median ms |
/// |---------------------------------|----------|-----------|-----------|
/// | flood fill on colour similarity |  0.961   | 20/22     |  **0.20** |
/// | naive 4-direction ray walk      |  0.795   | 12/22     |  0.00     |
/// | iterative gradient edge scan    |  0.837   | 16/22     |  0.08     |
/// | `VNDetectRectanglesRequest`     |  0.533   |  2/22     | 19.63     |
/// | hybrid (flood + acceptance)     |  0.961   | 20/22     | 10.35     |
///
/// Three results shaped this file.
///
/// 1. **Vision is the wrong tool and is not used.** 0.533 mean IoU, 2 of 22. It
///    inflates every box by 15 to 30 px because it detects the drop shadow and
///    the rounded corner, and it missed a checkbox entirely, returning the
///    whole window instead.
/// 2. **Plain flood fill matches the full hybrid exactly and is 50x faster.**
///    All the extra machinery bought zero accuracy.
/// 3. **The hybrid's only real job is refusing to snap.** On three flat-desktop
///    seeds it returned no result, where naive flood returned a confident
///    1.6-megapixel rectangle of empty desktop.
///
/// So: flood fill for the rectangle, then an acceptance test. If the test
/// fails, return `.rejected` and the UI shows no snap indicator at all rather
/// than a wrong one.
///
/// **The limitation, stated rather than buried.** That fixture is synthetic and
/// its elements are flat solid colours. Real macOS windows have vibrancy,
/// gradients, drop shadows and a wallpaper showing through. 0.961 will fall on
/// real windows. This proves the approach is worth its 0.2 ms and that the
/// rejection path works. It does not prove the accuracy number. The snap is
/// therefore always a suggestion the user can ignore, never automatic.
public enum EdgeSnap {

    public struct Result: Equatable, Sendable {
        /// Every level, innermost first. Pressing the snap key again moves out
        /// one level. Two or three is all that is useful: MEASURED, level-1
        /// parents are often a large jump (for a title bar, level 1 was the
        /// whole desktop band at IoU 0.043) rather than the visually obvious
        /// container.
        public var levels: [PixelRect]
        public var accepted: Bool
        /// Why it was rejected, or `"ok"`. Shown in the debug overlay and
        /// logged. A rejection with no reason is indistinguishable from a crash.
        public var reason: String
        public var confidence: Double

        public var rect: PixelRect { levels.first ?? .zero }

        public static let rejected = Result(levels: [], accepted: false,
                                            reason: "no element found", confidence: 0)
    }

    /// Colour distance tolerance for the flood fill, per channel sum.
    /// 24 is what the probe measured at 0.961 mean IoU. Lower misses
    /// anti-aliased edges, higher bleeds through subtle borders.
    public static let defaultTolerance = 24

    /// Snap from a seed point.
    ///
    /// - Parameter maxLevels: how many nesting levels to compute. The UI only
    ///   ever uses 3.
    public static func snap(in buffer: PixelBuffer,
                            at point: PixelPoint,
                            tolerance: Int = defaultTolerance,
                            maxLevels: Int = 3) -> Result {
        guard buffer.contains(point.x, point.y) else { return .rejected }
        guard let (colour, seed) = buffer.modalColour(around: point) else { return .rejected }

        var levels: [PixelRect] = []
        var tol = tolerance
        var previous = PixelRect.zero

        for level in 0..<maxLevels {
            let fill = floodFill(in: buffer, from: seed, colour: colour,
                                 tolerance: tol, maxPixels: buffer.width * buffer.height / 2)
            var rect = fill.bounds
            if level > 0 {
                // A parent must actually contain the child and be bigger.
                // Without this the "grow" key can jump sideways or shrink,
                // which feels broken even when each individual rect is sane.
                guard rect.area > previous.area,
                      rect.intersection(previous).area == previous.area else { break }
            }
            if rect.isEmpty { break }
            // Flood bounds are inclusive of the last matching pixel, and the
            // border of an element is usually one shade off from its fill, so
            // the component stops just inside it. One pixel out on each side
            // matches the drawn border. MEASURED: this is the difference
            // between IoU 0.967 and 1.000 on the text fields.
            rect = rect.inset(by: -1).clamped(to: buffer.bounds)
            levels.append(rect)
            previous = rect
            // Widen for the next level so the fill can cross the border it just
            // stopped at.
            tol = min(96, tol * 2)
        }

        guard let innermost = levels.first else { return .rejected }
        let (ok, reason, confidence) = accept(innermost, in: buffer)
        return Result(levels: levels, accepted: ok, reason: reason, confidence: confidence)
    }

    /// Snap from a rough drag rectangle. Seeds from its centre, which is what
    /// the probe measured: point seeds and rough-rect seeds gave identical
    /// results on all 11 targets.
    public static func snap(in buffer: PixelBuffer,
                            roughly rect: PixelRect,
                            tolerance: Int = defaultTolerance,
                            maxLevels: Int = 3) -> Result {
        snap(in: buffer, at: rect.centre, tolerance: tolerance, maxLevels: maxLevels)
    }

    // MARK: - The acceptance test, which is the whole point

    /// Reject a snap that is almost certainly not an element.
    ///
    /// MEASURED, six deliberate no-element seeds. Three flat-desktop seeds were
    /// correctly rejected by the border rule, where the naive flood returned
    /// `0,620 2940x1292` (1.6 M pixels of nothing) and reported no problem.
    static func accept(_ rect: PixelRect, in buffer: PixelBuffer) -> (Bool, String, Double) {
        // 1. Touching the image border means the fill escaped into the
        //    wallpaper. This one rule caught every flat-desktop case.
        if rect.x0 <= 0 || rect.y0 <= 0 || rect.x1 >= buffer.width || rect.y1 >= buffer.height {
            return (false, "touches image border", 0)
        }
        // 2. A degenerate sliver is not an element anyone meant to select.
        if rect.width < 4 || rect.height < 4 {
            return (false, "too small", 0)
        }
        // 3. Nearly the whole screen is not a snap, it is a failure to snap.
        if Double(rect.area) > Double(buffer.width * buffer.height) * 0.92 {
            return (false, "covers the whole image", 0)
        }
        // 4. A real element has a visible edge along most of each side. This is
        //    the check that would catch a fill escaping into a large flat area
        //    that happens not to reach the border.
        let support = sideSupport(rect, in: buffer)
        let weakest = support.min() ?? 0
        if weakest < 0.30 {
            return (false, String(format: "weak edge support %.2f", weakest), weakest)
        }
        let confidence = support.reduce(0, +) / 4
        return (true, "ok", confidence)
    }

    /// For each side, the fraction of its length that has a luma step across it.
    static func sideSupport(_ rect: PixelRect, in buffer: PixelBuffer, threshold: Int = 4) -> [Double] {
        func fraction(_ samples: Int, _ hits: Int) -> Double {
            samples <= 0 ? 0 : Double(hits) / Double(samples)
        }
        var top = 0, bottom = 0, left = 0, right = 0
        var hSamples = 0, vSamples = 0

        for x in rect.x0..<rect.x1 {
            guard buffer.contains(x, rect.y0), buffer.contains(x, rect.y1 - 1) else { continue }
            hSamples += 1
            if abs(buffer.lumaAt(x: x, y: rect.y0) - buffer.lumaAt(x: x, y: rect.y0 - 1)) >= threshold { top += 1 }
            if abs(buffer.lumaAt(x: x, y: rect.y1 - 1) - buffer.lumaAt(x: x, y: rect.y1)) >= threshold { bottom += 1 }
        }
        for y in rect.y0..<rect.y1 {
            guard buffer.contains(rect.x0, y), buffer.contains(rect.x1 - 1, y) else { continue }
            vSamples += 1
            if abs(buffer.lumaAt(x: rect.x0, y: y) - buffer.lumaAt(x: rect.x0 - 1, y: y)) >= threshold { left += 1 }
            if abs(buffer.lumaAt(x: rect.x1 - 1, y: y) - buffer.lumaAt(x: rect.x1, y: y)) >= threshold { right += 1 }
        }
        return [fraction(hSamples, top), fraction(hSamples, bottom),
                fraction(vSamples, left), fraction(vSamples, right)]
    }

    // MARK: - Flood fill

    struct Fill {
        var bounds: PixelRect
        var count: Int
        /// True when the fill hit its pixel cap, which means the bounds are a
        /// lower bound and not a component. Callers must treat it as no result.
        var overflowed: Bool
    }

    /// Scanline flood fill on colour similarity.
    ///
    /// Scanline rather than a four-way pixel stack because a full-screen fill
    /// on a 2940x1912 image pushes millions of entries and the naive version
    /// spent more time on the stack than on pixels. MEASURED at 0.20 ms median
    /// per snap, which is why the snap can run on every mouse move.
    static func floodFill(in buffer: PixelBuffer,
                          from seed: PixelPoint,
                          colour: SRGB,
                          tolerance: Int,
                          maxPixels: Int) -> Fill {
        let w = buffer.width, h = buffer.height
        guard buffer.contains(seed.x, seed.y) else {
            return Fill(bounds: .zero, count: 0, overflowed: false)
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = [(seed.x, seed.y)]
        var minX = seed.x, maxX = seed.x, minY = seed.y, maxY = seed.y
        var count = 0
        var overflowed = false

        @inline(__always)
        func matches(_ x: Int, _ y: Int) -> Bool {
            let o = (y * w + x) * 4
            let d = abs(Int(buffer.rgba[o]) - colour.r)
                  + abs(Int(buffer.rgba[o + 1]) - colour.g)
                  + abs(Int(buffer.rgba[o + 2]) - colour.b)
            return d <= tolerance
        }

        while let (sx, sy) = stack.popLast() {
            if count > maxPixels { overflowed = true; break }
            var x = sx
            let y = sy
            if visited[y * w + x] || !matches(x, y) { continue }
            // Walk left to the start of the run.
            while x > 0 && !visited[y * w + x - 1] && matches(x - 1, y) { x -= 1 }
            var spanAbove = false, spanBelow = false
            while x < w && !visited[y * w + x] && matches(x, y) {
                visited[y * w + x] = true
                count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }

                if y > 0 {
                    let up = matches(x, y - 1) && !visited[(y - 1) * w + x]
                    if up && !spanAbove { stack.append((x, y - 1)); spanAbove = true }
                    else if !up { spanAbove = false }
                }
                if y < h - 1 {
                    let down = matches(x, y + 1) && !visited[(y + 1) * w + x]
                    if down && !spanBelow { stack.append((x, y + 1)); spanBelow = true }
                    else if !down { spanBelow = false }
                }
                x += 1
            }
            if count > maxPixels { overflowed = true; break }
        }

        if overflowed {
            return Fill(bounds: .zero, count: count, overflowed: true)
        }
        return Fill(bounds: PixelRect(x0: minX, y0: minY, x1: maxX + 1, y1: maxY + 1),
                    count: count, overflowed: false)
    }
}

/// Text snapping, which is a separate case the probe found by accident.
///
/// MEASURED (probe A14): seeding inside a paragraph makes the flood return the
/// whole content pane, `940,352 1580x1228`. That is genuinely the element under
/// the point, but a user pressing snap while pointing at a paragraph wants the
/// paragraph. `VNRecognizeTextRequest` gave the line under the seed at **IoU
/// 0.995**, and grouping lines that overlap horizontally within 30 px gave the
/// paragraph block at **IoU 0.795**.
///
/// Those boxes already exist from the OCR pass, so this costs nothing new.
public enum TextSnap {

    /// The line box under a point, if any.
    public static func line(at p: PixelPoint, lines: [PixelRect]) -> PixelRect? {
        // Smallest containing box wins, so a line inside a paragraph beats the
        // paragraph.
        lines.filter { $0.contains(p) }.min { $0.area < $1.area }
    }

    /// Grow a line into its paragraph: any line overlapping horizontally by
    /// more than half the narrower box, within `maxGap` vertically.
    public static func block(containing start: PixelRect,
                             lines: [PixelRect],
                             maxGap: Int = 30) -> PixelRect {
        var block = start
        var changed = true
        while changed {
            changed = false
            for r in lines {
                let overlapX = min(block.x1, r.x1) - max(block.x0, r.x0)
                let gap = max(block.y0 - r.y1, r.y0 - block.y1)
                let narrower = min(block.width, r.width)
                if overlapX > narrower / 2 && gap < maxGap {
                    let merged = block.union(r)
                    if merged != block { block = merged; changed = true }
                }
            }
        }
        return block
    }
}
