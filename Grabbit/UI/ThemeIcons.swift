import SwiftUI
import AppKit

/// Icons that match the theme language: every theme shares the same
/// bundled Tabler line-icon set (free, MIT), with SF Symbols only as a
/// fallback for symbols that have no bundled equivalent.
enum IconMap {
    static func asset(for systemName: String) -> String? {
        switch systemName {
        case "trash", "trash.fill": return "IconDelete"
        case "checkmark": return "IconCheck"
        case "checkmark.circle", "checkmark.circle.fill": return "IconCircleCheck"
        case "xmark": return "IconClose"
        case "xmark.circle", "xmark.circle.fill": return "IconCircleX"
        case "pencil": return "IconPencil"
        case "link": return "IconCopyLink"
        case "doc.on.doc": return "IconCopy"
        case "arrow.clockwise", "arrow.triangle.2.circlepath": return "IconRefresh"
        case "arrow.up.arrow.down": return "IconSort"
        case "magnifyingglass": return "IconSearch"
        case "tray.and.arrow.down": return "IconDownloads"
        case "sparkles": return "IconSparkles"
        case "plus": return "IconAdd"
        case "minus": return "IconMinus"
        case "magnet": return "IconMagnet"
        case "info.circle", "info.circle.fill": return "IconDetails"
        case "folder": return "IconFolder"
        case "folder.fill": return "IconOpenFolder"
        case "exclamationmark.shield.fill": return "IconShieldAlert"
        case "exclamationmark.triangle", "exclamationmark.triangle.fill":
            return "IconAlertTriangle"
        case "dot.radiowaves.left.and.right": return "IconRSS"
        case "doc.badge.plus": return "IconFilePlus"
        case "clock.arrow.circlepath": return "IconHistory"
        case "clock": return "IconScheduler"
        case "play.rectangle": return "IconMedia"
        case "chevron.down": return "IconChevronDown"
        case "chevron.right": return "IconChevronRight"
        case "sun.max", "sun.max.fill": return "IconSun"
        case "moon", "moon.fill": return "IconMoon"
        case "circle.lefthalf.filled": return "IconMonitor"
        default: return nil
        }
    }
}

/// An icon drawn from the shared line-icon set when one exists, falling
/// back to the SF Symbol otherwise. `size` is the rendered square size in
/// points (Tabler assets are scaled to it; the SF fallback keeps the
/// surrounding font sizing).
struct AppIcon: View {
    var system: String
    var size: CGFloat

    init(_ system: String, size: CGFloat = 14) {
        self.system = system
        self.size = size
    }

    var body: some View {
        if let asset = IconMap.asset(for: system), NSImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: system)
        }
    }
}

/// Explicit-asset icon used where a themed asset is chosen directly (the
/// sidebar nav and the task action bar), with an SF fallback.
struct ThemedIcon: View {
    /// Asset catalog name, e.g. "IconDownloads".
    var asset: String
    /// SF Symbol fallback.
    var system: String
    var size: CGFloat = 15

    var body: some View {
        if NSImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: system)
        }
    }
}

/// Colored die-cut sticker used only by the Classic skin's decorative empty
/// states. Unlike `ThemedIcon`, this preserves the artwork's own palette and
/// must not be used for small toolbar/action labels.
struct StickerIcon: View {
    var asset: String
    var size: CGFloat
    var fallback: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if NSImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(Neo.ink2(scheme))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// A Mochi-style sticker on a hard-offset paper tile. This is deliberately
/// decorative: empty states get a little personality while navigation and
/// actions stay on the shared, tintable line-icon set.
struct StickerPlate: View {
    var asset: String
    var fallback: String
    var size: CGFloat = 96

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Neo.card(scheme))

            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                .stroke(
                    Neo.ink3(scheme).opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .padding(size * 0.10)

            StickerIcon(
                asset: asset,
                size: size * 0.70,
                fallback: fallback)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: 2.5)
                .allowsHitTesting(false))
        .background(
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 5, y: 5))
        .rotationEffect(.degrees(-2))
    }
}
