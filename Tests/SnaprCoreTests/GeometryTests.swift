import Testing
@testable import SnaprCore

@Suite("Pixel geometry")
struct PixelRectTests {

    @Test("a rect normalises whichever way it was built")
    func normalises() {
        #expect(PixelRect(x0: 10, y0: 20, x1: 5, y1: 8) == PixelRect(x0: 5, y0: 8, x1: 10, y1: 20))
    }

    @Test("half-open ranges, so a 1x1 rect contains exactly one pixel")
    func halfOpen() {
        let r = PixelRect.xywh(5, 5, 1, 1)
        #expect(r.area == 1)
        #expect(r.contains(PixelPoint(x: 5, y: 5)))
        #expect(!r.contains(PixelPoint(x: 6, y: 5)))
        #expect(!r.contains(PixelPoint(x: 5, y: 6)))
    }

    @Test("non-overlapping rects intersect to zero, not to a negative rect")
    func disjointIntersection() {
        let a = PixelRect.xywh(0, 0, 10, 10)
        let b = PixelRect.xywh(50, 50, 10, 10)
        #expect(a.intersection(b) == .zero)
        #expect(a.intersection(b).area == 0)
    }

    @Test("touching edges do not intersect, because the ranges are half-open")
    func touchingEdges() {
        let a = PixelRect.xywh(0, 0, 10, 10)
        let b = PixelRect.xywh(10, 0, 10, 10)
        #expect(a.intersection(b) == .zero)
    }

    @Test("union with an empty rect returns the other one unchanged")
    func unionWithEmpty() {
        let a = PixelRect.xywh(5, 5, 20, 20)
        #expect(a.union(.zero) == a)
        #expect(PixelRect.zero.union(a) == a)
    }

    @Test("IoU is 1 for identical rects and 0 for disjoint ones")
    func iou() {
        let a = PixelRect.xywh(0, 0, 100, 100)
        #expect(abs(a.iou(a) - 1.0) < 0.0001)
        #expect(a.iou(PixelRect.xywh(500, 500, 10, 10)) == 0)
        // Half overlap: 100x100 and 100x100 offset by 50 in x.
        let b = PixelRect.xywh(50, 0, 100, 100)
        // intersection 50x100 = 5000, union 20000 - 5000 = 15000
        #expect(abs(a.iou(b) - (5000.0 / 15000.0)) < 0.0001)
    }

    @Test("clamping keeps a selection inside the screen")
    func clamping() {
        let screen = PixelRect.xywh(0, 0, 1000, 800)
        #expect(PixelRect.xywh(900, 700, 500, 500).clamped(to: screen)
                    == PixelRect.xywh(900, 700, 100, 100))
        #expect(PixelRect.xywh(-50, -50, 100, 100).clamped(to: screen)
                    == PixelRect.xywh(0, 0, 50, 50))
    }
}

@Suite("Selection dragging and pixel nudging")
struct SelectionTests {
    let bounds = PixelRect.xywh(0, 0, 1000, 800)

    @Test("a drag of one pixel selects one pixel, not zero")
    func onePixelDrag() {
        // Users expect a click-drag on a single pixel to mean that pixel. The
        // +1 on the far edge is what makes that true, and it is easy to lose.
        let s = Selection(from: PixelPoint(x: 100, y: 100),
                          to: PixelPoint(x: 100, y: 100), bounds: bounds)
        #expect(s.rect.width == 1)
        #expect(s.rect.height == 1)
    }

    @Test("a drag works in every direction")
    func anyDirection() {
        let a = Selection(from: PixelPoint(x: 200, y: 200),
                          to: PixelPoint(x: 100, y: 100), bounds: bounds)
        let b = Selection(from: PixelPoint(x: 100, y: 100),
                          to: PixelPoint(x: 200, y: 200), bounds: bounds)
        #expect(a.rect == b.rect)
    }

    @Test("arrow keys move by exactly one pixel")
    func nudgeIsExact() {
        var s = Selection(rect: .xywh(100, 100, 50, 40), bounds: bounds)
        s.move(dx: 1, dy: 0)
        #expect(s.rect == PixelRect.xywh(101, 100, 50, 40))
        s.move(dx: 0, dy: -1)
        #expect(s.rect == PixelRect.xywh(101, 99, 50, 40))
    }

    @Test("moving into the edge stops rather than shrinking the selection")
    func moveStopsAtBounds() {
        var s = Selection(rect: .xywh(0, 0, 50, 40), bounds: bounds)
        s.move(dx: -10, dy: -10)
        #expect(s.rect == PixelRect.xywh(0, 0, 50, 40), "size must not change when it hits the edge")

        var t = Selection(rect: .xywh(950, 760, 50, 40), bounds: bounds)
        t.move(dx: 100, dy: 100)
        #expect(t.rect == PixelRect.xywh(950, 760, 50, 40))
    }

    @Test("resizing an edge changes only that edge")
    func resizeOneEdge() {
        var s = Selection(rect: .xywh(100, 100, 50, 40), bounds: bounds)
        s.resize(.right, dx: 10, dy: 0)
        #expect(s.rect == PixelRect.xywh(100, 100, 60, 40))
        s.resize(.top, dx: 0, dy: -5)
        #expect(s.rect == PixelRect.xywh(100, 95, 60, 45))
    }

    @Test("an edge cannot cross its opposite, so the readout never shows a negative size")
    func edgesCannotInvert() {
        var s = Selection(rect: .xywh(100, 100, 10, 10), bounds: bounds)
        s.resize(.right, dx: -500, dy: 0)
        #expect(s.rect.width >= 1)
        #expect(s.rect.height >= 1)
        s.resize(.bottom, dx: 0, dy: -500)
        #expect(s.rect.height >= 1)
    }

    @Test("handle hit testing picks corners before edges")
    func handleHitTest() {
        let s = Selection(rect: .xywh(100, 100, 200, 150), bounds: bounds)
        #expect(s.handle(at: PixelPoint(x: 100, y: 100), slop: 6) == .topLeft)
        #expect(s.handle(at: PixelPoint(x: 300, y: 250), slop: 6) == .bottomRight)
        #expect(s.handle(at: PixelPoint(x: 200, y: 100), slop: 6) == .top)
        #expect(s.handle(at: PixelPoint(x: 200, y: 175), slop: 6) == .inside)
        #expect(s.handle(at: PixelPoint(x: 500, y: 500), slop: 6) == nil)
    }
}
