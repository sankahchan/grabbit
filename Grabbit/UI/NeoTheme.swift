import SwiftUI
import AppKit

// MARK: - Hex helper

extension Color {
    /// Creates a Color from a 0xRRGGBB hex value.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Neo-brutalist palette

/// Neo-brutalist palette for Grabbit: thick ink borders, hard offset shadows,
/// flat bright accents.
///
/// The bright accents are fixed; `ink` / `paper` adapt to the color scheme —
/// pass the view's scheme explicitly:
///
/// ```swift
/// @Environment(\.colorScheme) private var scheme
/// ...
/// .foregroundStyle(Neo.ink(scheme))
/// .neoCard() // background defaults to theme-aware paper
/// ```
enum NeoPalette {
    // MARK: Bright accents (identical in light & dark)

    static let yellow = Color(hex: 0xFFD02F)
    static let pink   = Color(hex: 0xFF90E8)
    static let blue   = Color(hex: 0x7DD3FC)
    static let green  = Color(hex: 0x86EFAC)
    static let orange = Color(hex: 0xFB923C)
    static let purple = Color(hex: 0xC4B5FD)
    static let red    = Color(hex: 0xFF6B6B)

    // MARK: Scheme-adaptive neutrals

    static let inkLight   = Color(hex: 0x111111)
    static let paperLight = Color(hex: 0xFFFDF7)
    static let inkDark    = Color(hex: 0xF2EDE3)
    static let paperDark  = Color(hex: 0x17171C)

    /// Near-black in light mode, near-white in dark mode.
    /// Use for borders, text, and hard shadows.
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? inkDark : inkLight
    }

    /// Warm paper in light mode, deep charcoal in dark mode.
    /// Default card background.
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? paperDark : paperLight
    }

    /// Foreground for a filled background: dark ink on bright fills
    /// (yellow/green/blue/…), scheme-adaptive ink on dark fills.
    /// Without this, dark mode renders white text on bright accents
    /// (white-on-yellow, white-on-green) which is unreadable.
    static func onAccent(_ bg: Color, scheme: ColorScheme) -> Color {
        isBright(bg) ? inkLight : ink(scheme)
    }

    private static func isBright(_ color: Color) -> Bool {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * rgb.redComponent
            + 0.587 * rgb.greenComponent
            + 0.114 * rgb.blueComponent
        return luminance > 0.55
    }
}

/// Terse alias so call sites read `Neo.yellow`, `Neo.ink(scheme)`, …
typealias Neo = NeoPalette

// MARK: - Neo modifiers

/// Card: 3pt ink border, 6pt hard offset shadow, 14pt radius.
struct NeoCardModifier: ViewModifier {
    /// Pass nil (default) for theme-aware paper.
    var bg: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(bg ?? Neo.paper(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 3)
            )
            .shadow(color: Neo.ink(scheme), radius: 0, x: 6, y: 6)
    }
}

/// Small uppercase pill badge with a 2pt ink border.
struct NeoBadgeModifier: ViewModifier {
    var bg: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Neo.ink(scheme), lineWidth: 2))
    }
}

/// Chunky neo-brutalist button: thick ink border, hard offset shadow that
/// collapses on press, plus a slight scale-down for tactile feedback.
struct NeoButtonStyle: ButtonStyle {
    var bg: Color
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.bold) : .headline.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 10)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 3)
            )
            .shadow(
                color: Neo.ink(scheme), radius: 0,
                x: configuration.isPressed ? 1 : 4,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Neo-brutalist card. Pass `bg` to override the theme-aware paper default.
    func neoCard(bg: Color? = nil) -> some View {
        modifier(NeoCardModifier(bg: bg))
    }

    /// Small uppercase pill badge with a 2pt ink border.
    func neoBadge(bg: Color) -> some View {
        modifier(NeoBadgeModifier(bg: bg))
    }

    /// Convenience for `.buttonStyle(NeoButtonStyle(bg: bg))`.
    func neoButton(bg: Color) -> some View {
        buttonStyle(NeoButtonStyle(bg: bg))
    }
}

// MARK: - Progress bars

/// Renders one bordered block per download segment:
/// complete → green, partial → blue filled to its fraction, empty → paper.
struct SegmentedProgressBar: View {
    var segments: [Segment]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(segments) { segment in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Neo.paper(scheme))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillColor(for: segment))
                            .frame(width: max(0, geo.size.width * fraction(of: segment)))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Neo.ink(scheme), lineWidth: 2)
                    )
                }
            }
        }
        .frame(height: 14)
    }

    private func fraction(of segment: Segment) -> Double {
        if segment.isComplete { return 1 }
        let total = max(segment.byteCount, 1)
        return min(1, max(0, Double(segment.receivedBytes) / Double(total)))
    }

    private func fillColor(for segment: Segment) -> Color {
        if segment.isComplete { return Neo.green }
        return segment.receivedBytes > 0 ? Neo.blue : Neo.paper(scheme)
    }
}

/// Plain neo-brutalist linear bar (used for torrents).
struct NeoLinearBar: View {
    var progress: Double
    var fill: Color = Neo.blue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Neo.paper(scheme))
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .frame(width: geo.size.width * min(1, max(0, progress)))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Neo.ink(scheme), lineWidth: 2)
            )
        }
        .frame(height: 12)
    }
}

// MARK: - Source badge

/// Small colored badge identifying where a download came from.
struct SourceBadge: View {
    var site: SourceSite

    var body: some View {
        Text(label)
            .neoBadge(bg: color)
    }

    private var label: String {
        switch site {
        case .direct: "Direct"
        case .youtube: "YouTube"
        case .x: "X"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .telegram: "Telegram"
        case .other: "Other"
        }
    }

    private var color: Color {
        switch site {
        case .direct: Neo.green
        case .youtube: Neo.red
        case .x: Neo.yellow
        case .tiktok: Neo.pink
        case .instagram: Neo.purple
        case .telegram: Neo.blue
        case .other: Neo.paperLight
        }
    }
}

// MARK: - Formatting helpers

/// 1536 -> "1.5 KB", 2_147_483_648 -> "2.0 GB"
func formatBytes(_ bytes: Int64) -> String {
    let b = Double(bytes)
    guard b >= 1024 else { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = b / 1024
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}

/// 1_048_576 -> "1.0 MB/s"
func formatSpeed(_ bytesPerSec: Double) -> String {
    "\(formatBytes(Int64(bytesPerSec)))/s"
}

/// 45 -> "45s", 900 -> "15m", 5400 -> "1h 30m", nil -> "—"
func formatETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
    let total = Int(seconds)
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

// MARK: - Directory picker

/// Presents an NSOpenPanel for choosing a directory. Returns nil on cancel.
func chooseDirectory(initial: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if let initial {
        panel.directoryURL = initial
    }
    return panel.runModal() == .OK ? panel.url : nil
}
