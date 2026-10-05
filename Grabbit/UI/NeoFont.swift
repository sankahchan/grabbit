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
            ? .custom(name(for: weight), size: size)
            : .system(size: size, weight: weight)
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

    private static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline: .semibold
        default: .regular
        }
    }

    /// macOS system text-style point sizes, so the dot font keeps the same
    /// optical hierarchy as the system font it replaces.
    private static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 9
        @unknown default: 13
        }
    }
}
