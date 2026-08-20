import Foundation
import Testing
@testable import SnaprCore

@Suite("Zoom level")
struct ZoomLevelTests {

    @Test("a pinch is proportional, so it feels the same at both ends")
    func pinchIsProportional() {
        // The same finger movement at 0.2x and at 4x must change the zoom by
        // the same PROPORTION. Adding the delta instead would be useless at one
        // end of the range and violent at the other.
        let delta = 0.1
        let small = ZoomLevel.pinched(from: 0.2, by: delta) / 0.2
        let large = ZoomLevel.pinched(from: 4.0, by: delta) / 4.0
        #expect(abs(small - large) < 0.0001, "\(small) against \(large)")
    }

    @Test("a pinch in and the same pinch back out returns to where it started")
    func pinchRoundTrips() {
        let start = 1.7
        var z = start
        for _ in 0..<20 { z = ZoomLevel.pinched(from: z, by: 0.05) }
        for _ in 0..<20 { z = ZoomLevel.pinched(from: z, by: -1 + 1 / 1.05) }
        #expect(abs(z - start) < 0.001, "ended at \(z), started at \(start)")
    }

    @Test("zoom stays inside its limits however it is driven")
    func limitsHold() {
        var z = 1.0
        for _ in 0..<200 { z = ZoomLevel.pinched(from: z, by: 0.5) }
        #expect(z == ZoomLevel.maximum)
        for _ in 0..<200 { z = ZoomLevel.pinched(from: z, by: -0.5) }
        #expect(z == ZoomLevel.minimum)

        for _ in 0..<200 { z = ZoomLevel.stepIn(from: z) }
        #expect(z == ZoomLevel.maximum)
        for _ in 0..<200 { z = ZoomLevel.stepOut(from: z) }
        #expect(z == ZoomLevel.minimum)
    }

    @Test("a hostile magnification cannot flip or collapse the image")
    func hostileMagnification() {
        // AppKit does not send these. Nothing in the type system says so, and a
        // mirrored image is a far worse failure than a floor.
        #expect(ZoomLevel.pinched(from: 2, by: -1) >= ZoomLevel.minimum)
        #expect(ZoomLevel.pinched(from: 2, by: -50) >= ZoomLevel.minimum)
        // A nonsense delta is IGNORED rather than clamped to a limit. Jumping
        // to 8x on a bad event would look like the app did it on purpose.
        #expect(ZoomLevel.pinched(from: 2, by: .nan) == 2)
        #expect(ZoomLevel.pinched(from: 2, by: .infinity) == 2)
        #expect(ZoomLevel.clamp(.nan) == 1)
    }

    @Test("fit shows the whole image and never magnifies past 100%")
    func fitNeverMagnifies() {
        // Taller than the viewport: fit is driven by the height.
        let tall = ZoomLevel.toFit(imageWidth: 1000, imageHeight: 4000,
                                   viewportWidth: 800, viewportHeight: 600)
        #expect(abs(tall - 600.0 / 4000.0) < 0.0001)

        // Smaller than the viewport: fit is 100%, NOT 6x. A 40x40 icon blown up
        // to fill the window is not what "fit" means.
        let small = ZoomLevel.toFit(imageWidth: 40, imageHeight: 40,
                                    viewportWidth: 800, viewportHeight: 600)
        #expect(small == 1)
    }

    @Test("fit answers 100% rather than dividing by a zero-sized window")
    func fitWithNoViewport() {
        #expect(ZoomLevel.toFit(imageWidth: 100, imageHeight: 100,
                                viewportWidth: 0, viewportHeight: 0) == 1)
        #expect(ZoomLevel.toFit(imageWidth: 0, imageHeight: 0,
                                viewportWidth: 800, viewportHeight: 600) == 1)
    }

    @Test("a very tall capture still fits, down to the floor")
    func aLongScrollingCaptureFits() {
        // 30,000 pixels is the scrolling-capture height limit. Fitting that in
        // an ordinary window wants 0.02, which is below the floor, so it clamps
        // rather than returning something that rounds to 0%.
        let z = ZoomLevel.toFit(imageWidth: 1441, imageHeight: 30_000,
                                viewportWidth: 900, viewportHeight: 700)
        #expect(z == ZoomLevel.minimum)
    }

    @Test("a two-finger double tap toggles between fit and actual pixels")
    func smartTapToggles() {
        let fit = 0.25
        // Sitting at fit, the tap goes to actual size.
        #expect(ZoomLevel.smartTarget(current: fit, fit: fit) == 1)
        // Anywhere else, it goes back to fit.
        #expect(ZoomLevel.smartTarget(current: 1, fit: fit) == fit)
        #expect(ZoomLevel.smartTarget(current: 4, fit: fit) == fit)
        // A pinch that landed a hair off fit still counts as fit, or the tap
        // would appear to do nothing.
        #expect(ZoomLevel.smartTarget(current: fit + 0.005, fit: fit) == 1)
    }
}
