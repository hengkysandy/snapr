// Generates art/icon.png, the source `./app icons` turns into an .icns.
//
// A throwaway generator, run with `swift tools/makeicon.swift`. It is here
// rather than an image file so the icon can be adjusted without a design tool,
// and so the shape is under version control as code rather than as pixels.
//
// The icons are built with `iconutil` from this PNG, NOT with an asset catalog.
// MEASURED on the previous app: Xcode 26 silently dropped the 256, 512 and 1024
// entries from a scale-based AppIcon set, leaving the Dock and Get Info with no
// large artwork and no warning.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let S = CGFloat(size)

// macOS app icons sit inside a rounded square with a specific corner radius
// ratio. Getting this wrong makes an icon look subtly foreign next to every
// other one in the Dock.
func roundedSquare(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// The plate. Apple leaves roughly a 10% margin on each side of the canvas.
let margin = S * 0.10
let plate = CGRect(x: margin, y: margin, width: S - margin * 2, height: S - margin * 2)
ctx.saveGState()
ctx.addPath(roundedSquare(plate, radius: plate.width * 0.225))
ctx.clip()

// A vertical gradient, dark at the bottom. Screenshot tools live over other
// people's windows, so the icon reads better dark than light.
let gradient = CGGradient(colorsSpace: cs,
                          colors: [rgb(0.24, 0.28, 0.42), rgb(0.09, 0.11, 0.18)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: plate.maxY),
                       end: CGPoint(x: 0, y: plate.minY),
                       options: [])
ctx.restoreGState()

// A thin light edge along the top, which is what gives a flat plate depth.
ctx.saveGState()
ctx.addPath(roundedSquare(plate.insetBy(dx: S * 0.004, dy: S * 0.004),
                          radius: plate.width * 0.22))
ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
ctx.setLineWidth(S * 0.008)
ctx.strokePath()
ctx.restoreGState()

// The four selection corners. This is the shape the app is about: a rectangle
// being drawn around something.
let bracket = plate.insetBy(dx: plate.width * 0.20, dy: plate.width * 0.20)
let arm = bracket.width * 0.30
let lw = S * 0.038
ctx.setStrokeColor(rgb(1, 1, 1, 0.95))
ctx.setLineWidth(lw)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let corners: [(CGPoint, CGPoint, CGPoint)] = [
    // (corner, along x, along y)
    (CGPoint(x: bracket.minX, y: bracket.maxY),
     CGPoint(x: bracket.minX + arm, y: bracket.maxY),
     CGPoint(x: bracket.minX, y: bracket.maxY - arm)),
    (CGPoint(x: bracket.maxX, y: bracket.maxY),
     CGPoint(x: bracket.maxX - arm, y: bracket.maxY),
     CGPoint(x: bracket.maxX, y: bracket.maxY - arm)),
    (CGPoint(x: bracket.minX, y: bracket.minY),
     CGPoint(x: bracket.minX + arm, y: bracket.minY),
     CGPoint(x: bracket.minX, y: bracket.minY + arm)),
    (CGPoint(x: bracket.maxX, y: bracket.minY),
     CGPoint(x: bracket.maxX - arm, y: bracket.minY),
     CGPoint(x: bracket.maxX, y: bracket.minY + arm)),
]
for (c, ax, ay) in corners {
    ctx.move(to: ax); ctx.addLine(to: c); ctx.addLine(to: ay)
}
ctx.strokePath()

// A magnifier in the middle, which is the second half of what the app does:
// look closely, and read what is there.
let lensR = bracket.width * 0.235
let lensC = CGPoint(x: bracket.midX - bracket.width * 0.045,
                    y: bracket.midY + bracket.width * 0.045)
ctx.setLineWidth(lw * 0.95)
ctx.setStrokeColor(rgb(0.42, 0.78, 1.0, 1))
ctx.addArc(center: lensC, radius: lensR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// The handle, at the conventional 45 degrees.
let d = CGVector(dx: cos(-CGFloat.pi / 4), dy: sin(-CGFloat.pi / 4))
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: lensC.x + d.dx * lensR, y: lensC.y + d.dy * lensR))
ctx.addLine(to: CGPoint(x: lensC.x + d.dx * (lensR + bracket.width * 0.20),
                        y: lensC.y + d.dy * (lensR + bracket.width * 0.20)))
ctx.strokePath()

// A faint fill inside the lens, so it reads as glass and not as a ring.
ctx.setFillColor(rgb(0.42, 0.78, 1.0, 0.14))
ctx.addArc(center: lensC, radius: lensR - lw * 0.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("no image") }

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("art")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let out = outDir.appendingPathComponent("icon.png")
guard let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out.path)")
