import SwiftUI

// MARK: - Theme style

/// Selectable visual skin for the whole app. `classic` is the original
/// neo-brutalist look; the others are the reviewed preview themes from
/// `docs/theme-previews/` reduced to palette + shape tokens.
public enum ThemeStyle: String, Codable, CaseIterable, Sendable {
    case classic
    case aura
    case pulse
    case grove
    case velvet
    case liquid

    /// Brand names stay Latin in every language; only "Classic" is
    /// localized.
    public var displayName: String {
        switch self {
        case .classic: return NSLocalizedString("theme.classic", comment: "")
        case .aura: return "Aura"
        case .pulse: return "Pulse"
        case .grove: return "Grove"
        case .velvet: return "Velvet"
        case .liquid: return "Liquid"
        }
    }
}

// MARK: - Background + progress styles

/// A soft radial color wash painted on the page backdrop.
struct AmbientGlow: Sendable {
    var color: Color
    /// Unit position of the glow's center (0…1 of the canvas).
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
    var opacityLight: Double
    var opacityDark: Double
}

/// Progress bar language per theme.
enum ProgressStyle: Sendable {
    /// Classic bordered block per download segment.
    case blocks
    /// Aura: dotted measure line with an end knob.
    case dotted
    /// Pulse/Velvet: lit blocks with a "now" marker (marker optional).
    case segments
    /// Grove/Liquid: smooth capsule.
    case smooth
}

// MARK: - Shape tokens

/// Geometry/material tokens that differ per theme. The classic theme keeps
/// the hard-offset neo-brutalist look; modern themes drop the offset for
/// soft shadows, hairlines and (mostly) pill controls.
struct ThemeShape: Sendable {
    /// True for the neo-brutalist treatment (thick ink borders, hard
    /// offset block shadows, segmented meters, dot-grid paper).
    var brutalist = true

    var cardRadius: CGFloat = 14
    var cardBorder: CGFloat = 3
    /// > 0 draws the classic hard offset block behind cards.
    var cardHardOffset: CGFloat = 6
    /// Soft shadow used when `cardHardOffset == 0`.
    var cardShadowRadius: CGFloat = 0
    var cardShadowY: CGFloat = 0
    var cardShadowLight: Double = 0
    var cardShadowDark: Double = 0
    /// Accent strip height along the card top edge (0 = none).
    var cardTopStrip: CGFloat = 7

    var buttonRadius: CGFloat = 10
    var buttonBorder: CGFloat = 3
    var buttonHardOffset: CGFloat = 4

    var controlRadius: CGFloat = 10
    var controlBorder: CGFloat = 2.5
    var controlDivider: CGFloat = 2

    var fieldRadius: CGFloat = 8
    var fieldBorder: CGFloat = 2
    /// Divider / step button / spinner stroke width.
    var hairline: CGFloat = 2

    /// Concrete progress-bar rendering for this theme.
    var progress: ProgressStyle = .blocks
    /// Pulse: draw the white "now" marker on segmented bars.
    var progressMarker = false

    /// Pulse: cards glow from their own accent edge.
    var cardEdgeGlow = false
    /// Pulse: sidebar icons sit in colored, glowing rounded tiles.
    var sidebarIconTiles = false
    /// Aura: use the bundled Lucide line icons instead of SF Symbols.
    var lineIcons = false
    /// Aura/Liquid: badges are soft tinted chips instead of solid pills.
    var softBadges = false

    var dotGridLight: Double = 0.14
    var dotGridDark: Double = 0.09
}

// MARK: - Color tokens

/// A resolved theme: neutral colors per scheme, one accent set that reads
/// on both schemes, and the shape tokens.
struct ThemeTokens: Sendable {
    var paperLight: Color
    var paperDark: Color
    var cardLight: Color
    var cardDark: Color
    var sidebarLight: Color
    var sidebarDark: Color
    var inkLight: Color
    var inkDark: Color
    var ink2Light: Color
    var ink2Dark: Color
    var ink3Light: Color
    var ink3Dark: Color

    var yellow: Color
    var pink: Color
    var blue: Color
    var green: Color
    var orange: Color
    var purple: Color
    var red: Color

    var shape: ThemeShape

    /// Optional canvas gradient (Liquid's wallpaper). Empty = solid paper.
    var canvasGradientLight: [Color] = []
    var canvasGradientDark: [Color] = []
    /// Soft ambient washes painted over the canvas (Aura/Pulse/Grove/Velvet).
    var backgroundGlows: [AmbientGlow] = []
    /// Aura's little green status dot next to the brand subtitle.
    var brandDot: Color?

    func canvasGradient(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark ? canvasGradientDark : canvasGradientLight
    }

    func paper(_ scheme: ColorScheme) -> Color { scheme == .dark ? paperDark : paperLight }
    func card(_ scheme: ColorScheme) -> Color { scheme == .dark ? cardDark : cardLight }
    func sidebar(_ scheme: ColorScheme) -> Color { scheme == .dark ? sidebarDark : sidebarLight }
    func ink(_ scheme: ColorScheme) -> Color { scheme == .dark ? inkDark : inkLight }
    func ink2(_ scheme: ColorScheme) -> Color { scheme == .dark ? ink2Dark : ink2Light }
    func ink3(_ scheme: ColorScheme) -> Color { scheme == .dark ? ink3Dark : ink3Light }
}

// MARK: - Runtime

/// Global access point for the active theme. `MainView` assigns
/// `current` from settings on every render (cheap) and re-keys the view
/// tree on style changes so all `Neo.*` reads re-resolve.
enum ThemeRuntime {
    static var current: ThemeStyle = .classic

    static var tokens: ThemeTokens { ThemeCatalog.tokens(for: current) }
}

// MARK: - Catalog

enum ThemeCatalog {
    static func tokens(for style: ThemeStyle) -> ThemeTokens {
        switch style {
        case .classic: return classic
        case .aura: return aura
        case .pulse: return pulse
        case .grove: return grove
        case .velvet: return velvet
        case .liquid: return liquid
        }
    }

    // MARK: Classic — the original neo-brutalist look

    private static let classic = ThemeTokens(
        paperLight: Color(hex: 0xF8F2E3), paperDark: Color(hex: 0x17171C),
        cardLight: Color(hex: 0xF8F2E3), cardDark: Color(hex: 0x17171C),
        sidebarLight: Color(hex: 0xF8F2E3), sidebarDark: Color(hex: 0x17171C),
        inkLight: Color(hex: 0x111111), inkDark: Color(hex: 0xF2EDE3),
        ink2Light: Color(hex: 0x555555), ink2Dark: Color(hex: 0xB9B2A5),
        ink3Light: Color(hex: 0x8A8577), ink3Dark: Color(hex: 0x8A8577),
        yellow: Color(hex: 0xFFD02F),
        pink: Color(hex: 0xFF90E8),
        blue: Color(hex: 0x7DD3FC),
        green: Color(hex: 0x86EFAC),
        orange: Color(hex: 0xFB923C),
        purple: Color(hex: 0xC4B5FD),
        red: Color(hex: 0xFF6B6B),
        shape: ThemeShape())

    // MARK: Aura — clean airy SaaS, functional colors

    private static let aura = ThemeTokens(
        paperLight: Color(hex: 0xFFFFFF), paperDark: Color(hex: 0x141517),
        cardLight: Color(hex: 0xF1F1EF), cardDark: Color(hex: 0x1E1F22),
        sidebarLight: Color(hex: 0xFBFBFA), sidebarDark: Color(hex: 0x17181B),
        inkLight: Color(hex: 0x17181A), inkDark: Color(hex: 0xF2F3F4),
        ink2Light: Color(hex: 0x6E747B), ink2Dark: Color(hex: 0xA0A6AD),
        ink3Light: Color(hex: 0x9AA0A6), ink3Dark: Color(hex: 0x71787F),
        yellow: Color(hex: 0x2BA2C3),
        pink: Color(hex: 0x0EBE82),
        blue: Color(hex: 0x2BA2C3),
        green: Color(hex: 0x0EBE82),
        orange: Color(hex: 0xED4714),
        purple: Color(hex: 0x7A8790),
        red: Color(hex: 0xED4714),
        shape: ThemeShape(
            brutalist: false,
            cardRadius: 24, cardBorder: 1, cardHardOffset: 0,
            cardShadowRadius: 18, cardShadowY: 10,
            cardShadowLight: 0.07, cardShadowDark: 0.30,
            cardTopStrip: 0,
            buttonRadius: 999, buttonBorder: 0, buttonHardOffset: 0,
            controlRadius: 12, controlBorder: 1, controlDivider: 0,
            fieldRadius: 12, fieldBorder: 1, hairline: 1,
            progress: .dotted, lineIcons: true, softBadges: true,
            dotGridLight: 0.06, dotGridDark: 0.045),
        backgroundGlows: [
            AmbientGlow(color: Color(hex: 0xED4714), x: 0.06, y: -0.08, radius: 620,
                        opacityLight: 0.10, opacityDark: 0.07),
            AmbientGlow(color: Color(hex: 0x2BA2C3), x: 0.94, y: -0.10, radius: 720,
                        opacityLight: 0.14, opacityDark: 0.10),
            AmbientGlow(color: Color(hex: 0x0EBE82), x: 0.80, y: 1.12, radius: 760,
                        opacityLight: 0.12, opacityDark: 0.09),
        ],
        brandDot: Color(hex: 0x0EBE82))

    // MARK: Pulse — neon energy console

    private static let pulse = ThemeTokens(
        paperLight: Color(hex: 0xF5F7FA), paperDark: Color(hex: 0x0A0C10),
        cardLight: Color(hex: 0xFFFFFF), cardDark: Color(hex: 0x0F1216),
        sidebarLight: Color(hex: 0xFBFDFF), sidebarDark: Color(hex: 0x0B0E12),
        inkLight: Color(hex: 0x101418), inkDark: Color(hex: 0xEDF2F5),
        ink2Light: Color(hex: 0x5A6873), ink2Dark: Color(hex: 0x8FA0AC),
        ink3Light: Color(hex: 0x8A97A0), ink3Dark: Color(hex: 0x5A6873),
        yellow: Color(hex: 0xA8FF35),
        pink: Color(hex: 0xFFB020),
        blue: Color(hex: 0x25E3FF),
        green: Color(hex: 0xA8FF35),
        orange: Color(hex: 0xFFB020),
        purple: Color(hex: 0x25E3FF),
        red: Color(hex: 0xFF3355),
        shape: ThemeShape(
            brutalist: false,
            cardRadius: 20, cardBorder: 1, cardHardOffset: 0,
            cardShadowRadius: 16, cardShadowY: 12,
            cardShadowLight: 0.08, cardShadowDark: 0.32,
            cardTopStrip: 0,
            buttonRadius: 999, buttonBorder: 0, buttonHardOffset: 0,
            controlRadius: 999, controlBorder: 1, controlDivider: 0,
            fieldRadius: 12, fieldBorder: 1, hairline: 1,
            progress: .segments, progressMarker: true, cardEdgeGlow: true,
            sidebarIconTiles: true, lineIcons: true,
            dotGridLight: 0, dotGridDark: 0),
        backgroundGlows: [
            AmbientGlow(color: Color(hex: 0x25E3FF), x: 0.08, y: 0.06, radius: 640,
                        opacityLight: 0.07, opacityDark: 0.12),
            AmbientGlow(color: Color(hex: 0xA8FF35), x: 0.82, y: -0.10, radius: 520,
                        opacityLight: 0.04, opacityDark: 0.06),
            AmbientGlow(color: Color(hex: 0xFFB020), x: 0.95, y: 1.05, radius: 660,
                        opacityLight: 0.05, opacityDark: 0.08),
        ])

    // MARK: Grove — earthy olive command console, warm gold

    private static let grove = ThemeTokens(
        paperLight: Color(hex: 0xFAFAF2), paperDark: Color(hex: 0x14170F),
        cardLight: Color(hex: 0xFFFFFF), cardDark: Color(hex: 0x1B1F14),
        sidebarLight: Color(hex: 0xF4F5EA), sidebarDark: Color(hex: 0x12150D),
        inkLight: Color(hex: 0x1E2015), inkDark: Color(hex: 0xF2F2E8),
        ink2Light: Color(hex: 0x5F6653), ink2Dark: Color(hex: 0xA9AF9A),
        ink3Light: Color(hex: 0x8A9080), ink3Dark: Color(hex: 0x6F7663),
        yellow: Color(hex: 0xE0A94E),
        pink: Color(hex: 0xA3B565),
        blue: Color(hex: 0x8FA05A),
        green: Color(hex: 0x7FB069),
        orange: Color(hex: 0xC97B2E),
        purple: Color(hex: 0xB9C46A),
        red: Color(hex: 0xE06C5B),
        shape: ThemeShape(
            brutalist: false,
            cardRadius: 18, cardBorder: 1, cardHardOffset: 0,
            cardShadowRadius: 16, cardShadowY: 12,
            cardShadowLight: 0.07, cardShadowDark: 0.40,
            cardTopStrip: 0,
            buttonRadius: 999, buttonBorder: 0, buttonHardOffset: 0,
            controlRadius: 999, controlBorder: 1, controlDivider: 0,
            fieldRadius: 12, fieldBorder: 1, hairline: 1,
            progress: .smooth, lineIcons: true,
            dotGridLight: 0, dotGridDark: 0),
        backgroundGlows: [
            AmbientGlow(color: Color(hex: 0xE0A94E), x: 0.92, y: 1.08, radius: 620,
                        opacityLight: 0.05, opacityDark: 0.09),
            AmbientGlow(color: Color(hex: 0x8FA05A), x: 0.06, y: -0.06, radius: 560,
                        opacityLight: 0.05, opacityDark: 0.08),
            AmbientGlow(color: Color(hex: 0x5B7FA6), x: 0.95, y: 0.05, radius: 520,
                        opacityLight: 0.03, opacityDark: 0.05),
        ])

    // MARK: Velvet — luxe plum, silver & coral

    private static let velvet = ThemeTokens(
        paperLight: Color(hex: 0xEFEAE3), paperDark: Color(hex: 0x0B0A0C),
        cardLight: Color(hex: 0xFFFFFF), cardDark: Color(hex: 0x151316),
        sidebarLight: Color(hex: 0xF8F5F0), sidebarDark: Color(hex: 0x0D0C0F),
        inkLight: Color(hex: 0x1A151A), inkDark: Color(hex: 0xF5F2F4),
        ink2Light: Color(hex: 0x6B6169), ink2Dark: Color(hex: 0xA79BA3),
        ink3Light: Color(hex: 0x968B93), ink3Dark: Color(hex: 0x6E646C),
        yellow: Color(hex: 0xF27E93),
        pink: Color(hex: 0xA8456B),
        blue: Color(hex: 0xA99DAE),
        green: Color(hex: 0xD9D3C6),
        orange: Color(hex: 0xE06C5B),
        purple: Color(hex: 0x7A2E4F),
        red: Color(hex: 0xE06C5B),
        shape: ThemeShape(
            brutalist: false,
            cardRadius: 22, cardBorder: 1, cardHardOffset: 0,
            cardShadowRadius: 20, cardShadowY: 14,
            cardShadowLight: 0.08, cardShadowDark: 0.45,
            cardTopStrip: 0,
            buttonRadius: 999, buttonBorder: 0, buttonHardOffset: 0,
            controlRadius: 999, controlBorder: 1, controlDivider: 0,
            fieldRadius: 12, fieldBorder: 1, hairline: 1,
            progress: .segments, lineIcons: true,
            dotGridLight: 0, dotGridDark: 0),
        backgroundGlows: [
            AmbientGlow(color: Color(hex: 0xA8456B), x: 0.86, y: -0.10, radius: 700,
                        opacityLight: 0.10, opacityDark: 0.18),
            AmbientGlow(color: Color(hex: 0xF27E93), x: 0.08, y: 1.10, radius: 620,
                        opacityLight: 0.05, opacityDark: 0.10),
        ])

    // MARK: Liquid — Apple Liquid Glass

    private static let liquid = ThemeTokens(
        paperLight: Color(hex: 0xF5F6F8), paperDark: Color(hex: 0x1B1C20),
        // Translucent "glass" cards and sidebar: the wallpaper gradient
        // shows through, like the preview's Liquid Glass sheets.
        cardLight: Color.white.opacity(0.82), cardDark: Color(hex: 0x202127).opacity(0.84),
        sidebarLight: Color(hex: 0xEFF2F6).opacity(0.74),
        sidebarDark: Color(hex: 0x1E1F25).opacity(0.72),
        inkLight: Color(hex: 0x1C1C1E), inkDark: Color(hex: 0xFFFFFF),
        ink2Light: Color(hex: 0x5F6470), ink2Dark: Color(hex: 0xB8C0CC),
        ink3Light: Color(hex: 0x8E939E), ink3Dark: Color(hex: 0x8A93A0),
        yellow: Color(hex: 0x0A84FF),
        pink: Color(hex: 0x5AC8FA),
        blue: Color(hex: 0x0A84FF),
        green: Color(hex: 0x30D158),
        orange: Color(hex: 0xFF9F0A),
        purple: Color(hex: 0xBF5AF2),
        red: Color(hex: 0xFF453A),
        shape: ThemeShape(
            brutalist: false,
            cardRadius: 18, cardBorder: 1, cardHardOffset: 0,
            cardShadowRadius: 18, cardShadowY: 12,
            cardShadowLight: 0.08, cardShadowDark: 0.35,
            cardTopStrip: 0,
            buttonRadius: 999, buttonBorder: 0, buttonHardOffset: 0,
            controlRadius: 10, controlBorder: 1, controlDivider: 0,
            fieldRadius: 10, fieldBorder: 1, hairline: 1,
            progress: .smooth, lineIcons: true, softBadges: true,
            dotGridLight: 0, dotGridDark: 0),
        // The wallpaper behind the glass: pastel swirls in light, the
        // vivid blue-violet flow in dark.
        canvasGradientLight: [
            Color(hex: 0xDDEAF8), Color(hex: 0xE5E5F7),
            Color(hex: 0xEFE4F3), Color(hex: 0xFBE9E4),
        ],
        canvasGradientDark: [
            Color(hex: 0x1C2C5B), Color(hex: 0x3A3A9E),
            Color(hex: 0x6A35A8), Color(hex: 0xA84590),
        ])
}
