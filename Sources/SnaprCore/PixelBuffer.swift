import Foundation

/// A plain RGBA8 image in memory, top-left origin.
///
/// Deliberately not `CGImage`. Edge snapping is the one algorithm in this app
/// with real logic in it, and it has to be testable against a synthetic image
/// with known ground truth, with no display, no colour space and no capture
/// permission. The Mac shell converts a `CGImage` into this once per capture.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    /// 4 bytes per pixel, in R, G, B, A order. Row stride is exactly `width * 4`.
    public let rgba: [UInt8]
    /// Precomputed luma, one byte per pixel. Built once with the buffer because
    /// the edge scan reads it far more often than the colour planes.
    public let luma: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count >= width * height * 4, "rgba buffer too small")
        self.width = width
        self.height = height
        self.rgba = rgba
        var l = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            // Integer approximation of Rec.709 luma. Exactness does not matter
            // here: this drives edge detection, not a colour readout.
            let v = (54 * Int(rgba[o]) + 183 * Int(rgba[o + 1]) + 19 * Int(rgba[o + 2])) >> 8
            l[i] = UInt8(min(255, v))
        }
        self.luma = l
    }

    public var bounds: PixelRect { PixelRect.xywh(0, 0, width, height) }

    @inlinable
    public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Out of bounds returns nil rather than a plausible colour.
    ///
    /// MEASURED (probe A15.4): the probe's version of this returned a sentinel,
    /// and that sentinel is the only reason a harness bug in A15.1 was legible
    /// instead of being reported as a catastrophic colour failure. A picker
    /// that invents a value for a pixel that does not exist is worse than one
    /// that says nothing.
    @inlinable
    public func colour(x: Int, y: Int) -> SRGB? {
        guard contains(x, y) else { return nil }
        let o = (y * width + x) * 4
        return SRGB(r: Int(rgba[o]), g: Int(rgba[o + 1]), b: Int(rgba[o + 2]))
    }

    @inlinable
    public func lumaAt(x: Int, y: Int) -> Int {
        guard contains(x, y) else { return 0 }
        return Int(luma[y * width + x])
    }

    /// The forgiving pick. Nobody can hit a one-pixel target, so `Shift` takes
    /// the darkest pixel in a box around the cursor.
    ///
    /// MEASURED (probe A15.2): 0.0700 ms median for a 20x20 box. 238 of these
    /// fit in one 16.7 ms frame, so it runs on every mouse-moved event with no
    /// throttling.
    public func darkestColour(around p: PixelPoint, boxSize: Int = 20) -> SRGB? {
        let half = boxSize / 2
        var best: SRGB?
        var bestLuma = Int.max
        for dy in -half..<(boxSize - half) {
            for dx in -half..<(boxSize - half) {
                let x = p.x + dx, y = p.y + dy
                guard contains(x, y) else { continue }
                let l = Int(luma[y * width + x])
                if l < bestLuma, let c = colour(x: x, y: y) {
                    bestLuma = l; best = c
                }
            }
        }
        return best
    }

    /// The single most common colour in a small box, used to seed a flood fill.
    /// Sampling one pixel is fragile: anti-aliasing means the exact pixel under
    /// the cursor is often a blend that belongs to no region.
    public func modalColour(around p: PixelPoint, radius: Int = 5) -> (colour: SRGB, seed: PixelPoint)? {
        var counts: [UInt32: Int] = [:]
        var firstSeen: [UInt32: PixelPoint] = [:]
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = p.x + dx, y = p.y + dy
                guard contains(x, y) else { continue }
                let o = (y * width + x) * 4
                let key = UInt32(rgba[o]) << 16 | UInt32(rgba[o + 1]) << 8 | UInt32(rgba[o + 2])
                counts[key, default: 0] += 1
                if firstSeen[key] == nil { firstSeen[key] = PixelPoint(x: x, y: y) }
            }
        }
        guard let (key, _) = counts.max(by: { $0.value < $1.value }),
              let seed = firstSeen[key] else { return nil }
        return (SRGB(r: Int((key >> 16) & 0xFF),
                     g: Int((key >> 8) & 0xFF),
                     b: Int(key & 0xFF)), seed)
    }
}
