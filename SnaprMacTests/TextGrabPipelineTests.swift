import AppKit
import CoreGraphics
import XCTest
@testable import SnaprMac
import SnaprCore

/// End to end for the on-demand text grab: a real image through real Vision.
///
/// Everything else about this feature is tested against a string. This is the
/// one test that would fail if `OCRService.text(in:)` returned nothing on a
/// picture that plainly has words in it, which is exactly what happened before
/// `minimumTextHeightFraction` was lowered: zero observations, no error, and an
/// empty result that looks identical to an image with no text in it.
@MainActor
final class TextGrabPipelineTests: XCTestCase {

    /// White background, black words, at a size a real screenshot would have.
    private func imageWithWords(_ words: String, fontSize: Int = 40) throws -> CGImage {
        let base = try XCTUnwrap(CGContext(
            data: nil, width: 900, height: 300,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        base.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        base.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
        let blank = try XCTUnwrap(base.makeImage())

        let label = Annotation(kind: .text,
                               from: PixelPoint(x: 40, y: 100),
                               to: PixelPoint(x: 860, y: 200),
                               colour: .black,
                               text: words,
                               fontSize: fontSize)
        return try XCTUnwrap(AnnotationRenderer.flatten(base: blank,
                                                        annotations: [label],
                                                        blockSize: 12))
    }

    func testRecognitionFindsWordsThatArePlainlyThere() async throws {
        let image = try imageWithWords("Hello Snapr")

        let found = try await OCRService.text(in: image)
        let grab = try XCTUnwrap(TextGrab.clipboard(text: found.text,
                                                    barcodes: found.barcodes),
                                 "recognition returned nothing for an image full of words")

        XCTAssertTrue(grab.text.contains("Hello"), "got: \(grab.text)")
        XCTAssertTrue(grab.text.contains("Snapr"), "got: \(grab.text)")
        XCTAssertFalse(grab.fromBarcode)
    }

    func testABlankImageProducesNothingRatherThanAnEmptyString() async throws {
        let blank = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 300,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        blank.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(blank.makeImage())

        let found = try await OCRService.text(in: image)

        // Nil, not "". The caller uses nil to decide to LEAVE THE CLIPBOARD
        // ALONE, and an empty string would wipe whatever the user had copied.
        XCTAssertNil(TextGrab.clipboard(text: found.text, barcodes: found.barcodes))
    }

    func testBlurredTextIsNotRecoverableFromTheFlattenedImage() async throws {
        // The editor grabs text from the FLATTENED image on purpose. Reading the
        // original would hand back the very text a blur was placed over, which
        // is the worst possible failure for a tool whose blur exists to hide
        // passwords and account numbers.
        let image = try imageWithWords("SECRET")
        let cover = Annotation(kind: .blur,
                               from: PixelPoint(x: 0, y: 0),
                               to: PixelPoint(x: 899, y: 299))
        let hidden = try XCTUnwrap(AnnotationRenderer.flatten(base: image,
                                                              annotations: [cover],
                                                              blockSize: 40))

        let found = try await OCRService.text(in: hidden)

        XCTAssertFalse(found.text.uppercased().contains("SECRET"),
                       "recognition read straight through the blur: \(found.text)")
    }
}
