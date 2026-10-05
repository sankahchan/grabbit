import CoreText
import SwiftUI

/// Theme-aware typography. Every explicit font in the app goes through
/// `NeoFont`: in Pulse the whole UI renders in the bundled dot-matrix font
/// (Doto, OFL — the reference's flip-dot display); every other theme gets
/// exactly the system font it asked for, untouched.
///
/// `ThemeRuntime.current` is read at view-build time, and MainView re-keys
/// the hierarchy on a style change, so switching themes re-resolves every
/// font in one pass.
enum NeoFont {
    static var usesDotMatrix: Bool { Neo.shape.dotFont }

    // MARK: - Semantic styles

    static func f(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        if usesDotMatrix {
            return .custom(
                name(for: weight ?? defaultWeight(for: style)),
                size: size(for: style))
        }
        let base = Font.system(style)
        return weight.map { base.weight($0) } ?? base
    }

    static func f(
        _ style: Font.TextStyle,
        design: Font.Design,
        _ weight: Font.Weight? = nil
    ) -> Font {
        if usesDotMatrix {
            return .custom(
                name(for: weight ?? defaultWeight(for: style)),
                size: size(for: style))
        }
        let base = Font.system(style, design: design)
        return weight.map { base.weight($0) } ?? base
    }

    // MARK: - Fixed sizes

    static func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        usesDotMatrix
            ? .custom(name(for: weight), size: scaled(size))
            : .system(size: size, weight: weight)
    }

    /// Doto's dots sit visually smaller than a system glyph at the same
    /// point size. Small UI text (≤16pt) gets a 25% bump so labels stay
    /// legible; display sizes are left alone.
    private static func scaled(_ size: CGFloat) -> CGFloat {
        size <= 16 ? (size * 1.25).rounded() : size
    }

    // MARK: - Monospaced variants

    static func mono(
        _ style: Font.TextStyle, _ weight: Font.Weight? = nil
    ) -> Font {
        if usesDotMatrix {
            return .custom(
                name(for: weight ?? defaultWeight(for: style)),
                size: size(for: style))
        }
        let base = Font.system(style, design: .monospaced)
        return weight.map { base.weight($0) } ?? base
    }

    static func digits(_ style: Font.TextStyle) -> Font {
        if usesDotMatrix {
            return .custom(name(for: .regular), size: size(for: style))
        }
        return Font.system(style).monospacedDigit()
    }

    static func monoDigits(_ style: Font.TextStyle) -> Font {
        if usesDotMatrix {
            return .custom(name(for: .regular), size: size(for: style))
        }
        return Font.system(style, design: .monospaced).monospacedDigit()
    }

    // MARK: - Registration

    /// Registers the bundled Doto faces for this process. Safe to call more
    /// than once; a missing bundle resource just falls back to system fonts.
    static func registerBundledFonts() {
        for resource in ["Doto-Regular", "Doto-Bold"] {
            guard let url = Bundle.main.url(
                forResource: resource, withExtension: "ttf")
            else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    // MARK: - Mappings

    private static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black:
            "Doto-Bold"
        default:
            "Doto-Regular"
        }
    }

    /// Small text is drawn bold: Doto's regular dots get sparse below
    /// ~14pt, and the extra dot weight is what keeps captions readable.
    private static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline, .body, .callout, .subheadline, .footnote,
             .caption, .caption2:
            .bold
        case .largeTitle, .title, .title2, .title3:
            .regular
        @unknown default:
            .regular
        }
    }

    /// macOS system text-style point sizes, so the dot font keeps the same
    /// optical hierarchy as the system font it replaces.
    private static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 28
        case .title: 24
        case .title2: 18.5
        case .title3: 16.5
        case .headline: 14
        case .body: 14
        case .callout: 13
        case .subheadline: 12.5
        case .footnote: 11.5
        case .caption: 11.5
        case .caption2: 10.5
        @unknown default: 14
        }
    }
}
