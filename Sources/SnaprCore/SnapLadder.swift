import Foundation

/// The ordered list of things the snap key can offer, smallest first.
///
/// **Why this exists.** MEASURED on real macOS windows
/// (`probes/edges/REAL-RESULTS.md`): pixel-based element snapping finds the
/// control under the cursor **8 times in 18**. It never suggests a wrong
/// rectangle, it stays silent instead, so more than half the time the snap key
/// does nothing at all. A key that usually does nothing is a key people stop
/// pressing.
///
/// Window frames fix that. `SCShareableContent` reports them **exactly**, they
/// cost no extra permission, and "select this window" is the most common thing
/// anyone wants. So the ladder is:
///
///   1. the element under the cursor, if the pixel snap accepted one
///   2. its parents, from the same flood
///   3. the window under the cursor, which is exact
///   4. larger windows under the cursor, outermost last
///
/// When the element snap misses, rung 1 is simply the window, and the key still
/// does something correct. That is the whole point.
public enum SnapLadder {

    /// Two rectangles this close are the same thing to a user, and offering
    /// both makes the key feel broken: press again, nothing visibly changes.
    static let duplicateIoU = 0.95

    /// Four rungs. Beyond that nobody tracks where they are in the ladder, and
    /// MEASURED in probe A14, the deeper flood parents are often a large jump
    /// rather than the visually obvious container.
    static let maxRungs = 4

    /// Build the ladder for one seed point.
    ///
    /// - Parameters:
    ///   - point: the seed, in image pixels.
    ///   - element: the pixel-based snap result. Ignored entirely when it was
    ///     not accepted, because a rejected snap is a refusal, not a hint.
    ///   - windows: window frames already converted into this image's pixel
    ///     space. Order does not matter, they are sorted here.
    ///   - bounds: the image, used to clip windows that hang off the screen.
    public static func build(at point: PixelPoint,
                             element: EdgeSnap.Result,
                             windows: [PixelRect],
                             bounds: PixelRect) -> [PixelRect] {
        var candidates: [PixelRect] = []

        // 1 and 2: the element and its parents, only if the snap accepted.
        if element.accepted {
            candidates.append(contentsOf: element.levels)
        }

        // 3 and 4: every window under the point, clipped to the screen and
        // sorted smallest first. A window that is partly off screen is still a
        // useful target, but only the visible part can be captured.
        let containing = windows
            .map { $0.clamped(to: bounds) }
            .filter { !$0.isEmpty && $0.contains(point) }
            .sorted { $0.area < $1.area }
        candidates.append(contentsOf: containing)

        return prune(candidates, bounds: bounds)
    }

    /// Keep a strictly growing, visibly distinct ladder.
    static func prune(_ candidates: [PixelRect], bounds: PixelRect) -> [PixelRect] {
        var out: [PixelRect] = []
        // Sort by area so a window smaller than the flood component still comes
        // first. Without this the ladder can go large then small, and "press
        // again to grow" would shrink, which reads as a bug even when every
        // individual rectangle is sensible.
        for rect in candidates.sorted(by: { $0.area < $1.area }) {
            if rect.isEmpty || rect.width < 4 || rect.height < 4 { continue }
            guard let last = out.last else { out.append(rect); continue }
            // Must actually grow, and must look different from the previous rung.
            if rect.area <= last.area { continue }
            if rect.iou(last) > duplicateIoU { continue }
            out.append(rect)
            if out.count >= maxRungs { break }
        }
        return out
    }
}
