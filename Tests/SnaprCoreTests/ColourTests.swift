import Testing
@testable import SnaprCore

/// The A15.3 probe result, kept as a test.
///
/// The probe compared this implementation against published WCAG values AND
/// against a deliberate control that skips gamma linearisation. The control
/// disagreed by more than 2x on the grey cases, which is what proves the real
/// one is doing work rather than accidentally agreeing on the easy cases.
@Suite("WCAG contrast")
struct ContrastTests {

    /// The naive version, kept in the test file rather than the shipping code.
    /// It is the mistake nearly every hand-rolled contrast function makes:
    /// averaging the channels without linearising them first.
    static func naiveRatio(_ a: SRGB, _ b: SRGB) -> Double {
        func lum(_ c: SRGB) -> Double {
            (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static let published: [(name: String, fg: SRGB, bg: SRGB, ratio: Double)] = [
        ("black on white", .black, .white, 21.00),
        ("white on white", .white, .white, 1.00),
        ("mid grey on white", SRGB(r: 128, g: 128, b: 128), .white, 3.95),
        ("#767676 on white, the AA boundary", SRGB(r: 118, g: 118, b: 118), .white, 4.54),
    ]

    @Test("matches published values", arguments: published)
    func matchesPublished(c: (name: String, fg: SRGB, bg: SRGB, ratio: Double)) {
        let got = Contrast.ratio(c.fg, c.bg)
        #expect(abs(got - c.ratio) < 0.05,
                "\(c.name): got \(got), published \(c.ratio)")
    }

    /// If this test ever passes for the grey cases, the linearisation step has
    /// been removed from the shipping code and nobody noticed, because the
    /// numbers still look like contrast ratios.
    @Test("the naive control disagrees, which is why the real one is needed")
    func controlFires() {
        let grey = SRGB(r: 128, g: 128, b: 128)
        let real = Contrast.ratio(grey, .white)
        let naive = Self.naiveRatio(grey, .white)
        #expect(abs(real - naive) > 1.5,
                "the no-gamma control agreed with the real one, so the test proves nothing")
        #expect(abs(naive - 1.90) < 0.05, "the control itself drifted")
    }

    @Test("the ratio is symmetric, so foreground and background order does not matter")
    func symmetric() {
        let a = SRGB(r: 30, g: 90, b: 200), b = SRGB(r: 240, g: 240, b: 230)
        #expect(abs(Contrast.ratio(a, b) - Contrast.ratio(b, a)) < 0.0001)
    }

    @Test("grades sit on the right side of each WCAG threshold")
    func grades() {
        #expect(Contrast.grade(21.0) == .aaa)
        #expect(Contrast.grade(7.0) == .aaa)
        #expect(Contrast.grade(6.99) == .aa)
        #expect(Contrast.grade(4.5) == .aa)
        #expect(Contrast.grade(4.49) == .aaLarge)
        #expect(Contrast.grade(3.0) == .aaLarge)
        #expect(Contrast.grade(2.99) == .fail)
        // Large text has a lower bar, which is the whole reason for the flag.
        #expect(Contrast.grade(3.0, largeText: true) == .aa)
        #expect(Contrast.grade(4.5, largeText: true) == .aaa)
        #expect(Contrast.grade(2.99, largeText: true) == .fail)
    }

    @Test("the #767676 boundary case grades as AA, which is what makes it the boundary")
    func theBoundary() {
        // Anything one step darker passes, one step lighter fails. This is the
        // number designers actually look up, so getting it wrong is visible.
        #expect(Contrast.grade(Contrast.ratio(SRGB(r: 118, g: 118, b: 118), .white)) == .aa)
        #expect(Contrast.grade(Contrast.ratio(SRGB(r: 120, g: 120, b: 120), .white)) == .aaLarge)
    }
}

@Suite("Colour formatting")
struct ColourFormatTests {

    @Test("every format produces something a designer can paste")
    func formats() {
        let c = SRGB(r: 18, g: 52, b: 86)
        #expect(ColourFormat.hexUppercase.string(for: c) == "#123456")
        #expect(ColourFormat.hexLowercase.string(for: c) == "#123456".lowercased())
        #expect(ColourFormat.cssRGB.string(for: c) == "rgb(18, 52, 86)")
        #expect(ColourFormat.swiftUI.string(for: c).hasPrefix("Color(red:"))
        #expect(ColourFormat.appKit.string(for: c).hasPrefix("NSColor(srgbRed:"))
    }

    @Test("hex pads single digits, so 1,2,3 is not #123")
    func hexPadding() {
        #expect(SRGB(r: 1, g: 2, b: 3).hex == "#010203")
    }

    @Test("out of range values clamp instead of wrapping")
    func clamping() {
        #expect(SRGB(r: 300, g: -5, b: 255) == SRGB(r: 255, g: 0, b: 255))
    }

    @Test("isDark picks a readable label colour on both extremes")
    func darkness() {
        #expect(SRGB.black.isDark)
        #expect(!SRGB.white.isDark)
        // Mid grey is above the threshold, so a label over it should be dark.
        #expect(!SRGB(r: 128, g: 128, b: 128).isDark)
    }
}
