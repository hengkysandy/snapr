import Testing
@testable import SnaprCore

@Suite("Snap ladder")
struct SnapLadderTests {

    let bounds = PixelRect.xywh(0, 0, 2940, 1912)
    let point = PixelPoint(x: 500, y: 500)

    func accepted(_ levels: [PixelRect]) -> EdgeSnap.Result {
        EdgeSnap.Result(levels: levels, accepted: true, reason: "ok", confidence: 0.8)
    }

    /// The reason this type exists. MEASURED: element snap finds the control
    /// 8 times in 18 on real windows, so more than half the time the key would
    /// do nothing at all without a window to fall back to.
    @Test("when the element snap misses, the window becomes the first rung")
    func windowRescuesAMissedSnap() {
        let window = PixelRect.xywh(300, 300, 900, 700)
        let ladder = SnapLadder.build(at: point,
                                      element: .rejected,
                                      windows: [window],
                                      bounds: bounds)
        #expect(ladder == [window], "a refused element snap must still offer the window")
    }

    @Test("a refused element snap contributes nothing, not even a best guess")
    func rejectedElementIsIgnoredEntirely() {
        // A rejection is a refusal, not a hint. If the levels of a rejected
        // result leaked into the ladder, the acceptance test would be pointless.
        let rejected = EdgeSnap.Result(levels: [PixelRect.xywh(400, 400, 50, 50)],
                                       accepted: false, reason: "touches image border",
                                       confidence: 0)
        let ladder = SnapLadder.build(at: point, element: rejected,
                                      windows: [], bounds: bounds)
        #expect(ladder.isEmpty)
    }

    @Test("the element comes before the window that contains it")
    func elementBeforeWindow() {
        let button = PixelRect.xywh(480, 480, 120, 40)
        let window = PixelRect.xywh(300, 300, 900, 700)
        let ladder = SnapLadder.build(at: point,
                                      element: accepted([button]),
                                      windows: [window],
                                      bounds: bounds)
        #expect(ladder == [button, window])
    }

    @Test("windows that do not contain the point are not offered")
    func onlyWindowsUnderTheCursor() {
        let under = PixelRect.xywh(300, 300, 900, 700)
        let elsewhere = PixelRect.xywh(1500, 300, 900, 700)
        let ladder = SnapLadder.build(at: point, element: .rejected,
                                      windows: [under, elsewhere], bounds: bounds)
        #expect(ladder == [under])
    }

    @Test("nested windows are offered smallest first")
    func nestedWindowsGrowOutward() {
        let inner = PixelRect.xywh(400, 400, 400, 300)
        let outer = PixelRect.xywh(200, 200, 1200, 900)
        let ladder = SnapLadder.build(at: point, element: .rejected,
                                      windows: [outer, inner], bounds: bounds)
        #expect(ladder == [inner, outer], "the ladder must grow, never shrink")
    }

    /// The failure this guards against reads as a bug even when every
    /// individual rectangle is correct: press again to grow, and it shrinks.
    @Test("the ladder never shrinks, even when a window is smaller than the element")
    func neverShrinks() {
        let bigElement = PixelRect.xywh(100, 100, 1000, 900)
        let smallWindow = PixelRect.xywh(450, 450, 200, 150)
        let ladder = SnapLadder.build(at: point,
                                      element: accepted([bigElement]),
                                      windows: [smallWindow],
                                      bounds: bounds)
        for i in 1..<ladder.count {
            #expect(ladder[i].area > ladder[i - 1].area,
                    "rung \(i) did not grow: \(ladder)")
        }
        #expect(ladder.first == smallWindow, "the smaller rect must come first")
    }

    @Test("two rectangles a user cannot tell apart are offered once")
    func nearDuplicatesCollapse() {
        // A flood component and the window frame around it often differ by a
        // pixel or two. Offering both makes the key feel broken: press again,
        // nothing visibly changes.
        let element = PixelRect.xywh(300, 300, 900, 700)
        let window = PixelRect.xywh(299, 299, 902, 702)
        let ladder = SnapLadder.build(at: point,
                                      element: accepted([element]),
                                      windows: [window],
                                      bounds: bounds)
        #expect(ladder.count == 1, "got \(ladder)")
        #expect(ladder.first == element, "the element is the tighter answer, keep it")
    }

    @Test("a window hanging off the screen is clipped to what can be captured")
    func windowsAreClipped() {
        let offScreen = PixelRect.xywh(-400, -200, 1400, 1000)
        let ladder = SnapLadder.build(at: PixelPoint(x: 200, y: 200),
                                      element: .rejected,
                                      windows: [offScreen], bounds: bounds)
        #expect(ladder == [PixelRect.xywh(0, 0, 1000, 800)])
    }

    @Test("a window that is entirely off screen is dropped, not offered as empty")
    func fullyOffScreenWindowDropped() {
        let gone = PixelRect.xywh(-2000, -2000, 500, 500)
        let ladder = SnapLadder.build(at: point, element: .rejected,
                                      windows: [gone], bounds: bounds)
        #expect(ladder.isEmpty)
    }

    @Test("the ladder is capped, so the key stays predictable")
    func ladderIsCapped() {
        var windows: [PixelRect] = []
        for i in 1...10 {
            let inset = 100 * (10 - i)
            windows.append(PixelRect.xywh(inset, inset, 1200 - inset, 1000 - inset))
        }
        let ladder = SnapLadder.build(at: PixelPoint(x: 950, y: 950),
                                      element: .rejected,
                                      windows: windows, bounds: bounds)
        #expect(ladder.count <= SnapLadder.maxRungs)
    }

    @Test("degenerate slivers are never offered")
    func sliversDropped() {
        let sliver = PixelRect.xywh(495, 495, 2, 900)
        let real = PixelRect.xywh(300, 300, 900, 700)
        let ladder = SnapLadder.build(at: point, element: .rejected,
                                      windows: [sliver, real], bounds: bounds)
        #expect(ladder == [real])
    }

    @Test("no windows and no element means no ladder, not an empty rectangle")
    func nothingMeansNothing() {
        #expect(SnapLadder.build(at: point, element: .rejected,
                                 windows: [], bounds: bounds).isEmpty)
    }
}
