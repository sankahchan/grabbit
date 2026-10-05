import SwiftUI
import AppKit

/// Icons that match the theme language: every theme shares the same
/// bundled Lucide line-icon set (free, ISC), with SF Symbols only as a
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
/// points (Lucide assets are scaled to it; the SF fallback keeps the
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
