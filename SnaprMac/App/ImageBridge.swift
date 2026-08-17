import AppKit
import CoreGraphics
import ImageIO
import SnaprCore
import UniformTypeIdentifiers

/// The one place `CGImage` becomes something the core can reason about, and the
/// one place PNG bytes are produced.
///
/// Everything else in the app takes `PixelBuffer`, `Data` or `NSImage`. Keeping
/// the conversions here means the edge-snap algorithm can be tested against a
/// synthetic buffer with no display, no colour space and no permission.
enum ImageBridge {

    /// Render a `CGImage` into a tightly packed RGBA8 buffer.
    ///
    /// It draws into a context we allocate rather than reading
    /// `dataProvider.data` directly. A captured image can be BGRA, can have row
    /// padding, and can carry a colour space that is not sRGB. Reading its
    /// bytes directly is how a picker ends up reporting the wrong colour, which
    /// probe A15 measured as a 116-unit error on pure red.
    static func pixelBuffer(from image: CGImage) -> PixelBuffer? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return PixelBuffer(width: w, height: h, rgba: bytes)
    }

    /// The other direction, for the one thing that builds an image out of
    /// nothing: a scroll capture, whose result is taller than any frame that
    /// was ever on the screen.
    static func cgImage(from buffer: PixelBuffer) -> CGImage? {
        let w = buffer.width, h = buffer.height
        guard w > 0, h > 0, buffer.rgba.count >= w * h * 4 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let provider = CGDataProvider(data: Data(buffer.rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue:
                           CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pngData(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func image(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// A downscaled thumbnail.
    ///
    /// MEASURED (probe A12): decoding the full original for each grid tile
    /// costs 31 to 35 ms. Reading a stored thumbnail costs about 1 ms. A **32x
    /// to 37x** difference, so thumbnails are generated once at save time and
    /// stored as their own sealed blob, never derived on the fly.
    static func thumbnail(from image: CGImage, maxEdge: Int = 320) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, Double(maxEdge) / Double(max(w, h)))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Crop in top-left pixel coordinates, which is what `PixelRect` uses and
    /// what `CGImage.cropping(to:)` expects. `NSView` coordinates are bottom-up
    /// and every conversion between the two happens at a view boundary, never
    /// here.
    static func crop(_ image: CGImage, to rect: PixelRect) -> CGImage? {
        let clamped = rect.clamped(to: PixelRect.xywh(0, 0, image.width, image.height))
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: CGRect(x: clamped.x0, y: clamped.y0,
                                         width: clamped.width, height: clamped.height))
    }
}
