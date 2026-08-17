import Foundation

/// An 8-bit sRGB colour.
///
/// The name says sRGB because that is a claim the app has to keep. MEASURED
/// (probe A15.1): a ScreenCaptureKit capture with the DEFAULT configuration
/// returned `234, 52, 36` for a pixel drawn as pure `255, 0, 0`, because the
/// display is wider than sRGB and the default hands back display-native values.
/// Worst channel error was 116 on the default and 1 with `colorSpaceName` pinned
/// to sRGB.
///
/// So every value of this type must have come from a capture whose
/// `SCStreamConfiguration.colorSpaceName` was set to `CGColorSpace.sRGB`.
/// Nothing in this file can check that. It is a contract the capture layer keeps.
public struct SRGB: Equatable, Hashable, Sendable, Codable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = min(255, max(0, r))
        self.g = min(255, max(0, g))
        self.b = min(255, max(0, b))
    }

    public static let black = SRGB(r: 0, g: 0, b: 0)
    public static let white = SRGB(r: 255, g: 255, b: 255)

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    public var hexLowercase: String { String(format: "#%02x%02x%02x", r, g, b) }
    public var cssRGB: String { "rgb(\(r), \(g), \(b))" }
    public var swiftLiteral: String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
               Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
    public var nsColorLiteral: String {
        String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)",
               Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    /// Perceived brightness, used only to decide whether to draw label text in
    /// black or white over this colour. Not a contrast ratio.
    public var isDark: Bool { Contrast.relativeLuminance(self) < 0.18 }
}

/// Which representation the colour picker copies.
public enum ColourFormat: String, CaseIterable, Sendable, Codable {
    case hexUppercase = "Hex uppercase"
    case hexLowercase = "Hex lowercase"
    case cssRGB = "CSS rgb()"
    case swiftUI = "SwiftUI Color"
    case appKit = "NSColor"

    public func string(for c: SRGB) -> String {
        switch self {
        case .hexUppercase: return c.hex
        case .hexLowercase: return c.hexLowercase
        case .cssRGB: return c.cssRGB
        case .swiftUI: return c.swiftLiteral
        case .appKit: return c.nsColorLiteral
        }
    }
}

/// WCAG 2.1 contrast.
///
/// MEASURED (probe A15.3) against published values, with a deliberate control
/// that skips gamma linearisation:
///
/// | pair                | this code | published | naive, no gamma |
/// |---------------------|-----------|-----------|-----------------|
/// | black on white      | 21.00:1   | 21.00     | 21.00:1         |
/// | mid grey on white   |  3.95:1   |  3.95     |  1.90:1         |
/// | #767676 on white    |  4.54:1   |  4.54     |  2.05:1         |
///
/// The naive column is wrong by more than 2x on the grey cases, which is the
/// mistake nearly every hand-rolled contrast function makes. The control
/// disagreeing is what proves this implementation is doing real work rather
/// than accidentally agreeing on the easy cases.
public enum Contrast {

    public static func relativeLuminance(_ c: SRGB) -> Double {
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255.0
            // The linearisation step. Removing it still produces plausible
            // numbers, which is exactly why it gets removed by accident.
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    public static func ratio(_ a: SRGB, _ b: SRGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public enum Grade: String, Sendable {
        case fail = "Fail"
        case aaLarge = "AA Large"
        case aa = "AA"
        case aaa = "AAA"
    }

    /// WCAG thresholds. Large text is 18pt regular or 14pt bold and above.
    public static func grade(_ r: Double, largeText: Bool = false) -> Grade {
        if largeText {
            if r >= 4.5 { return .aaa }
            if r >= 3.0 { return .aa }
            return .fail
        }
        if r >= 7.0 { return .aaa }
        if r >= 4.5 { return .aa }
        if r >= 3.0 { return .aaLarge }
        return .fail
    }

    public static func formatted(_ r: Double) -> String {
        String(format: "%.2f:1", r)
    }
}
