import Foundation

/// What the editor's zoom may be, and how each way of changing it arrives at
/// the next value.
///
/// Here rather than in the view. The limits, the step and the pinch response
/// are decisions, and a decision that lives inside an `NSView` can only be
/// checked by opening a window and using your hands. The view keeps the half
/// that genuinely needs AppKit: which point to hold still, and how to move the
/// scroll origin to hold it there.
public enum ZoomLevel {

    /// A tenth. Below this a long scrolling capture is a smear with no
    /// information left in it.
    public static let minimum = 0.1
    /// Eight times. Past this one image pixel is a large flat tile and there is
    /// nothing further to see.
    public static let maximum = 8.0

    /// A button press, or Cmd and plus.
    ///
    /// 1.25 rather than 2. A screenshot is annotated at the zoom where the text
    /// is readable, and doubling steps straight past it.
    public static let step = 1.25

    public static func clamp(_ z: Double) -> Double {
        // A non-finite zoom is not clamped to a limit, it is refused. It can
        // only come from a division by a zero-sized viewport, and 100% is the
        // honest answer to "we do not know".
        guard z.isFinite else { return 1 }
        return min(maximum, max(minimum, z))
    }

    public static func stepIn(from z: Double) -> Double { clamp(z * step) }
    public static func stepOut(from z: Double) -> Double { clamp(z / step) }

    /// One pinch event.
    ///
    /// AppKit reports `NSEvent.magnification` as a DELTA for that event, not as
    /// a factor, so it is applied as a proportion of the zoom already in force.
    /// That proportionality is what makes a pinch feel the same at 0.2x as at
    /// 4x: the same movement of the fingers is the same proportional change
    /// either way. Adding the delta instead would make the gesture useless at
    /// one end of the range and violent at the other.
    public static func pinched(from z: Double, by magnification: Double) -> Double {
        guard magnification.isFinite else { return clamp(z) }
        // A delta of -1 or below would take the zoom to zero or make it
        // negative. AppKit does not send those, but nothing in the type system
        // says so and a mirrored image is a much worse failure than a floor.
        return clamp(z * max(0.01, 1 + magnification))
    }

    /// The zoom that shows the whole image.
    ///
    /// Never magnifies past 100%. A small capture blown up to fill the window
    /// is not what "fit" means, and it makes a 40x40 icon look like a bug.
    public static func toFit(imageWidth: Int, imageHeight: Int,
                             viewportWidth: Double, viewportHeight: Double) -> Double {
        guard imageWidth > 0, imageHeight > 0,
              viewportWidth > 0, viewportHeight > 0 else { return 1 }
        return clamp(min(1, min(viewportWidth / Double(imageWidth),
                                viewportHeight / Double(imageHeight))))
    }

    /// Where a two-finger double tap should land.
    ///
    /// Fit and 100% are the two zooms worth toggling between in a screenshot
    /// tool: one to see the whole thing, one to see its real pixels. Anything
    /// cleverer is a guess at what the user meant.
    public static func smartTarget(current: Double, fit: Double) -> Double {
        // "Near enough to fit" rather than equal to it. `fit` is a computed
        // fraction and the current zoom has usually been nudged by a pinch, so
        // an equality test here would mean the tap did nothing.
        abs(current - fit) < 0.01 ? 1 : clamp(fit)
    }
}
