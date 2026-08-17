import AppKit
import CoreGraphics
import CoreImage
import CoreText
import SnaprCore

/// Draws annotations, and flattens them into a new image.
///
/// Every function here expects a `CGContext` whose coordinate system is the
/// image's own pixel space: origin at the top left, y growing downwards, one
/// unit per image pixel. `Annotation` stores `PixelPoint` in exactly that
/// space, so no conversion happens inside this file. The screen path sets the
/// same transform before calling in, which is why one renderer serves both the
/// live canvas and the export.
enum AnnotationRenderer {

    /// One shared `CIContext`. Building one per blur annotation is expensive and
    /// `CIContext` is documented as safe to use from several threads.
    nonisolated(unsafe) private static let ciContext = CIContext()

    // MARK: - Flatten

    /// The base image with every annotation drawn in, at **full pixel
    /// resolution**.
    ///
    /// The output is always `base.width` by `base.height`. Rendering at the
    /// on-screen zoom instead is the mistake that produces an export which
    /// looks correct in the editor and is soft everywhere else.
    static func flatten(base: CGImage,
                        annotations: [Annotation],
                        blockSize: Int) -> CGImage? {
        let w = base.width, h = base.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // The base goes in first, in the context's own bottom-up space, so it
        // lands the right way up.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Now flip to the image's top-left pixel space for the annotations.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, base: base, in: ctx, blockSize: blockSize)

        return ctx.makeImage()
    }

    // MARK: - Draw

    /// Six kinds, one switch. A class hierarchy for six shapes would be three
    /// files of ceremony around this.
    static func draw(_ annotations: [Annotation],
                     base: CGImage,
                     in ctx: CGContext,
                     blockSize: Int) {
        for a in annotations {
            switch a.kind {
            case .arrow:     drawArrow(a, in: ctx)
            case .box:       drawBox(a, in: ctx)
            case .text:      drawText(a, in: ctx)
            case .counter:   drawCounter(a, in: ctx)
            case .blur:      drawBlur(a, base: base, in: ctx, blockSize: blockSize)
            case .highlight: drawHighlight(a, in: ctx)
            }
        }
    }

    // MARK: - Arrow

    /// A real arrow: one filled polygon with a shaft and a solid head.
    ///
    /// A stroked line with a V on the end reads as a line with a decoration.
    /// A filled head reads as an arrow at any size, which is the point of the
    /// tool.
    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let tail = CGPoint(x: a.from.x, y: a.from.y)
        let tip = CGPoint(x: a.to.x, y: a.to.y)
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1 else { return }

        let ux = dx / length, uy = dy / length      // along the arrow
        let nx = -uy, ny = ux                       // across the arrow

        let lw = CGFloat(max(1, a.lineWidth))
        // The head grows with the line width so a thick arrow does not end in a
        // tiny point. Half the arrow at most, so a short arrow is all head
        // rather than a head hanging off the back.
        let headLength = min(length * 0.5, max(lw * 4, 12))
        let headHalf = headLength * 0.45
        let shaftHalf = lw / 2

        let baseX = tip.x - ux * headLength
        let baseY = tip.y - uy * headLength

        func point(_ x: CGFloat, _ y: CGFloat, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: x + nx * offset, y: y + ny * offset)
        }

        let path = CGMutablePath()
        path.move(to: point(tail.x, tail.y, shaftHalf))
        path.addLine(to: point(baseX, baseY, shaftHalf))
        path.addLine(to: point(baseX, baseY, headHalf))
        path.addLine(to: tip)
        path.addLine(to: point(baseX, baseY, -headHalf))
        path.addLine(to: point(baseX, baseY, -shaftHalf))
        path.addLine(to: point(tail.x, tail.y, -shaftHalf))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setFillColor(cgColour(a.colour))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Box

    private static func drawBox(_ a: Annotation, in ctx: CGContext) {
        let lw = CGFloat(max(1, a.lineWidth))
        let full = cgRect(a.boundingBox)
        guard full.width > 0, full.height > 0 else { return }

        if a.fillStyle == .filled {
            // A filled rectangle covers what is under it, so it doubles as a
            // way to hide something with a solid block rather than a blur.
            ctx.saveGState()
            ctx.setFillColor(cgColour(a.colour))
            ctx.fill(full)
            ctx.restoreGState()
            return
        }

        // Inset by half the line width so the stroke stays inside the rectangle
        // the user dragged. Without this the box is fatter than the selection
        // and hit testing disagrees with what is on screen.
        let r = full.insetBy(dx: lw / 2, dy: lw / 2)
        guard r.width > 0, r.height > 0 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(cgColour(a.colour))
        ctx.setLineWidth(lw)
        ctx.setLineJoin(.miter)
        ctx.stroke(r)
        ctx.restoreGState()
    }

    // MARK: - Highlight

    private static func drawHighlight(_ a: Annotation, in ctx: CGContext) {
        let r = cgRect(a.boundingBox)
        guard r.width > 0, r.height > 0 else { return }
        ctx.saveGState()
        // Multiply, not plain alpha. Multiply darkens towards the wash colour
        // and keeps the dark text under it dark, so the text stays readable.
        // Plain alpha washes the text out towards the highlight colour.
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(cgColour(a.colour, alpha: 0.45))
        ctx.fill(r)
        ctx.restoreGState()
    }

    // MARK: - Blur

    private static func drawBlur(_ a: Annotation,
                                 base: CGImage,
                                 in ctx: CGContext,
                                 blockSize: Int) {
        // PIXELATION, never a gaussian blur. A gaussian is a linear filter, so
        // in principle the original text can be recovered from the blurred
        // pixels. Coarse pixelation averages the detail away and there is
        // nothing left to recover. This tool exists to hide things in a
        // screenshot before it is shared, so it has to be the destructive one.
        let region = a.boundingBox.clamped(to: PixelRect.xywh(0, 0, base.width, base.height))
        guard !region.isEmpty,
              let piece = ImageBridge.crop(base, to: region),
              let pixelated = pixellate(piece, blockSize: blockSize) else { return }

        let r = cgRect(region)
        ctx.saveGState()
        // The context is flipped to top-left origin. A bitmap drawn straight
        // into it comes out mirrored, so the flip is undone just for this draw.
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelated, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// `CIPixellate` over one cropped region.
    static func pixellate(_ image: CGImage, blockSize: Int) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: input.extent.midX, y: input.extent.midY),
                        forKey: kCIInputCenterKey)
        filter.setValue(Double(max(1, blockSize)), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        // The filter output extent is larger than the input, so it is cut back
        // to the region we asked about.
        return ciContext.createCGImage(output, from: input.extent)
    }

    // MARK: - Counter

    private static func drawCounter(_ a: Annotation, in ctx: CGContext) {
        let box = cgRect(a.boundingBox)
        let side = min(box.width, box.height)
        guard side >= 6 else { return }
        // The balloon is bigger than its circle, because the tail reaches out
        // to 1.95 radii. Size the circle so the WHOLE shape fits the rectangle
        // the user dragged. Letting the tail hang outside would make hit
        // testing disagree with what is drawn, and would clip the tip at the
        // image edge, which is the same class of bug as annotations drawn
        // outside the picture vanishing on save.
        let r = side / balloonExtent
        let circle = CGRect(x: box.minX + balloonTailReach * r - r,
                            y: box.minY,
                            width: 2 * r, height: 2 * r)

        // A speech balloon, not a plain circle. The tail points at the thing
        // being numbered, which is the whole job of a step marker: a bare
        // circle sitting near two controls does not say which one it means.
        ctx.saveGState()
        ctx.setFillColor(cgColour(a.colour))
        ctx.addPath(balloonPath(circle))
        ctx.fillPath()
        ctx.restoreGState()

        // Whichever of black or white has the better WCAG ratio against the
        // fill. Guessing white looks right on red and is wrong on yellow.
        let label = Contrast.ratio(a.colour, .white) >= Contrast.ratio(a.colour, .black)
            ? SRGB.white : SRGB.black
        let text = String(max(1, a.counterValue))
        // Sized from the CIRCLE, not from the drag box. The circle is now
        // smaller than the box, because the tail takes some of it.
        let fontSize = circle.width * 0.55
        let line = CTLineCreateWithAttributedString(
            attributed(text, fontSize: fontSize, colour: label))

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        ctx.saveGState()
        // Un-flip so the glyphs are the right way up, then place the baseline so
        // the digits sit optically centred in the circle.
        ctx.translateBy(x: circle.midX - width / 2,
                        y: circle.midY + (ascent - descent) / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A circle with a tail at the bottom left, drawn as one closed path.
    ///
    /// The context is in the image's TOP-LEFT pixel space, so a larger y is
    /// further DOWN the picture. The tail therefore points to a larger y.
    static func balloonPath(_ circle: CGRect) -> CGPath {
        let r = circle.width / 2
        let c = CGPoint(x: circle.midX, y: circle.midY)
        let path = CGMutablePath()
        let tip = CGPoint(x: c.x + r * balloonTailReach * cos(balloonGapCentre),
                          y: c.y + r * balloonTailReach * sin(balloonGapCentre))

        // Sweep the LONG way round, leaving only the gap the tail fills.
        // Sweeping the short way draws a thin sliver instead of a balloon,
        // which is what the first attempt did, and it was only obvious once it
        // had been rendered and looked at.
        path.addArc(center: c, radius: r,
                    startAngle: balloonGapCentre + balloonGapHalfWidth,
                    endAngle: balloonGapCentre - balloonGapHalfWidth + 2 * .pi,
                    clockwise: false)
        path.addLine(to: tip)
        path.closeSubpath()
        return path
    }

    /// Where the tail points. The context is in the image's TOP-LEFT pixel
    /// space, so +y is DOWN and 0.75 pi is down and to the left.
    static let balloonGapCentre = CGFloat.pi * 0.75
    /// Half the angular width of the gap the tail fills.
    static let balloonGapHalfWidth = CGFloat.pi * 0.16
    /// How far the tip sits from the centre, in radii.
    static let balloonTailReach: CGFloat = 1.95
    /// Total width and height of the balloon, in radii. The tail adds
    /// `balloonTailReach * cos(45 degrees)` on one side of each axis.
    static let balloonExtent: CGFloat = 1 + balloonTailReach * 0.7071

    // MARK: - Text

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let box = cgRect(a.boundingBox)
        guard box.width >= 1, box.height >= 1 else { return }

        let attr = attributed(a.text, fontSize: CGFloat(a.fontSize), colour: a.colour)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: box.height),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             path, nil)

        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        // A screenshot can be any colour under the text. A soft shadow keeps a
        // light label readable on a light background without an outline.
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                      color: CGColor(gray: 0, alpha: 0.55))
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// Measured size of a string, used to fit a text annotation's box to what is
    /// actually drawn so hit testing agrees with what the user sees.
    static func textSize(_ s: String, fontSize: Int, maxWidth: Double) -> PixelSize {
        guard !s.isEmpty else { return PixelSize(width: 1, height: 1) }
        let attr = attributed(s, fontSize: CGFloat(fontSize), colour: .black)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            &fitRange)
        return PixelSize(width: max(1, Int(size.width.rounded(.up))),
                         height: max(1, Int(size.height.rounded(.up))))
    }

    private static func attributed(_ s: String,
                                   fontSize: CGFloat,
                                   colour: SRGB) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: max(4, fontSize), weight: .semibold)
        // AppKit's own attribute dictionary is `[Key: Any]`. Nothing to narrow.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColour(colour)
        ]
        return NSAttributedString(string: s, attributes: attrs)
    }

    // MARK: - Small conversions

    /// `PixelRect` is half-open with a top-left origin, and so is the context
    /// this file draws into, so the conversion is a straight copy.
    static func cgRect(_ r: PixelRect) -> CGRect {
        CGRect(x: CGFloat(r.x0), y: CGFloat(r.y0),
               width: CGFloat(r.width), height: CGFloat(r.height))
    }

    static func cgColour(_ c: SRGB, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255, alpha: alpha)
    }

    static func nsColour(_ c: SRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func srgb(_ c: NSColor) -> SRGB {
        // Any NSColor can carry a wider space than sRGB. Converting first is
        // what keeps the stored value honest, for the same reason the capture
        // configuration pins sRGB.
        let s = c.usingColorSpace(.sRGB) ?? c
        return SRGB(r: Int((s.redComponent * 255).rounded()),
                    g: Int((s.greenComponent * 255).rounded()),
                    b: Int((s.blueComponent * 255).rounded()))
    }
}
