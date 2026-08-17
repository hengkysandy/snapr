import Foundation

/// Integer pixel geometry, top-left origin, half-open ranges.
///
/// Deliberately not `CGRect`. A screenshot selection is a whole number of
/// device pixels, and floating point is where off-by-one selections come from:
/// a `CGRect` at scale 2.0 can land on x = 100.5, which is not a pixel. Every
/// conversion from points to pixels happens once, at the AppKit boundary, and
/// everything inside the core works in these types.
public struct PixelPoint: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct PixelSize: Equatable, Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct PixelRect: Equatable, Hashable, Sendable, Codable {
    /// Half-open: `x0..<x1`, `y0..<y1`. A 1x1 rect has x1 == x0 + 1.
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = min(x0, x1); self.y0 = min(y0, y1)
        self.x1 = max(x0, x1); self.y1 = max(y0, y1)
    }

    public static func xywh(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> PixelRect {
        PixelRect(x0: x, y0: y, x1: x + w, y1: y + h)
    }

    public static let zero = PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }
    public var area: Int { width * height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var origin: PixelPoint { PixelPoint(x: x0, y: y0) }
    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var centre: PixelPoint { PixelPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2) }

    public func contains(_ p: PixelPoint) -> Bool {
        p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1
    }

    public func intersection(_ o: PixelRect) -> PixelRect {
        // The emptiness check happens on the raw numbers, BEFORE building a
        // rect. The initialiser normalises with min/max, so it would silently
        // swap an inverted result back into a large valid-looking rect. Caught
        // by a test: two disjoint 10x10 rects 50 px apart reported an
        // intersection of 1600 px rather than zero.
        let nx0 = max(x0, o.x0), ny0 = max(y0, o.y0)
        let nx1 = min(x1, o.x1), ny1 = min(y1, o.y1)
        guard nx1 > nx0, ny1 > ny0 else { return .zero }
        return PixelRect(x0: nx0, y0: ny0, x1: nx1, y1: ny1)
    }

    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0),
                         x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    /// Clamp into a bounds rect. Used at every boundary, because a selection
    /// dragged past the edge of the screen must not produce a capture request
    /// for pixels that do not exist.
    public func clamped(to bounds: PixelRect) -> PixelRect {
        intersection(bounds)
    }

    public func inset(by d: Int) -> PixelRect {
        PixelRect(x0: x0 + d, y0: y0 + d, x1: x1 - d, y1: y1 - d)
    }

    public func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x0: x0 + dx, y0: y0 + dy, x1: x1 + dx, y1: y1 + dy)
    }

    /// Intersection over union. The scoring function the A14 probe used, kept
    /// because the same number is what the edge-snap tests assert on.
    public func iou(_ o: PixelRect) -> Double {
        let inter = intersection(o).area
        let uni = area + o.area - inter
        return uni <= 0 ? 0 : Double(inter) / Double(uni)
    }

    public var describedSize: String { "\(width) x \(height)" }
}

/// Which corner or edge of a selection a drag is moving.
public enum SelectionHandle: Equatable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
}

/// The selection a user is dragging, and the arrow-key nudging that makes it
/// exact. Pure integer maths, so every edge case is a unit test rather than a
/// thing you find out about while dragging.
public struct Selection: Equatable, Sendable {
    public var rect: PixelRect
    public var bounds: PixelRect

    public init(rect: PixelRect, bounds: PixelRect) {
        self.bounds = bounds
        self.rect = rect.clamped(to: bounds)
    }

    /// Build from the two points of a drag, in either direction.
    public init(from a: PixelPoint, to b: PixelPoint, bounds: PixelRect) {
        self.bounds = bounds
        // +1 on the far edge so a drag that starts and ends on the same pixel
        // selects that pixel rather than nothing. Users expect a click-drag of
        // one pixel to mean one pixel, not zero.
        let r = PixelRect(x0: min(a.x, b.x), y0: min(a.y, b.y),
                          x1: max(a.x, b.x) + 1, y1: max(a.y, b.y) + 1)
        self.rect = r.clamped(to: bounds)
    }

    /// Move the whole selection. Stops at the bounds instead of shrinking,
    /// which is the behaviour people expect from a drag.
    public mutating func move(dx: Int, dy: Int) {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        if moved.x0 < bounds.x0 { moved = moved.offsetBy(dx: bounds.x0 - moved.x0, dy: 0) }
        if moved.y0 < bounds.y0 { moved = moved.offsetBy(dx: 0, dy: bounds.y0 - moved.y0) }
        if moved.x1 > bounds.x1 { moved = moved.offsetBy(dx: bounds.x1 - moved.x1, dy: 0) }
        if moved.y1 > bounds.y1 { moved = moved.offsetBy(dx: 0, dy: bounds.y1 - moved.y1) }
        rect = moved.clamped(to: bounds)
    }

    /// Grow or shrink one edge by whole pixels. This is the arrow-key
    /// measurement feature: hold a modifier and each press is exactly one pixel.
    public mutating func resize(_ handle: SelectionHandle, dx: Int, dy: Int) {
        var r = rect
        switch handle {
        case .topLeft:     r.x0 += dx; r.y0 += dy
        case .top:         r.y0 += dy
        case .topRight:    r.x1 += dx; r.y0 += dy
        case .right:       r.x1 += dx
        case .bottomRight: r.x1 += dx; r.y1 += dy
        case .bottom:      r.y1 += dy
        case .bottomLeft:  r.x0 += dx; r.y1 += dy
        case .left:        r.x0 += dx
        case .inside:      move(dx: dx, dy: dy); return
        }
        // Never let an edge cross its opposite. Without this a fast drag
        // inverts the rect and the readout shows a negative size.
        if r.x1 <= r.x0 { r.x1 = r.x0 + 1 }
        if r.y1 <= r.y0 { r.y1 = r.y0 + 1 }
        rect = r.clamped(to: bounds)
    }

    /// Which handle a point is over, given a hit slop in pixels.
    public func handle(at p: PixelPoint, slop: Int) -> SelectionHandle? {
        guard rect.inset(by: -slop).contains(p) else { return nil }
        let nearLeft = abs(p.x - rect.x0) <= slop
        let nearRight = abs(p.x - rect.x1) <= slop
        let nearTop = abs(p.y - rect.y0) <= slop
        let nearBottom = abs(p.y - rect.y1) <= slop
        switch (nearTop, nearBottom, nearLeft, nearRight) {
        case (true, _, true, _):  return .topLeft
        case (true, _, _, true):  return .topRight
        case (_, true, true, _):  return .bottomLeft
        case (_, true, _, true):  return .bottomRight
        case (true, _, _, _):     return .top
        case (_, true, _, _):     return .bottom
        case (_, _, true, _):     return .left
        case (_, _, _, true):     return .right
        default: return rect.contains(p) ? .inside : nil
        }
    }
}
