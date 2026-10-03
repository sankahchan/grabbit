import SwiftUI

enum SidebarSelection: String, Hashable, CaseIterable {
    case downloads, torrents, media, rss, grabber, linkgrabber, scheduler, history, settings, about

    /// Main tabs, top-to-bottom order. History is content (the record of
    /// finished work), so it lives with the work areas rather than with the
    /// app-level utilities pinned to the bottom.
    static let mainTabs: [SidebarSelection] = [
        .downloads, .torrents, .media, .rss, .grabber, .linkgrabber, .scheduler, .history,
    ]
    /// Utility buttons pinned to the sidebar bottom (macOS convention).
    static let bottomTabs: [SidebarSelection] = [.settings, .about]

    var icon: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .linkgrabber: "link"
        case .torrents: "arrow.triangle.2.circlepath" // "magnet" is not a real SF Symbol — renders blank
        case .media: "play.rectangle"
        case .rss: "dot.radiowaves.left.and.right"
        case .grabber: "globe"
        case .history: "clock.arrow.circlepath"
        case .scheduler: "clock"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    var localizedTitle: String {
        switch self {
        case .downloads: NSLocalizedString("nav.downloads", comment: "")
        case .linkgrabber: NSLocalizedString("nav.linkgrabber", comment: "")
        case .torrents: NSLocalizedString("nav.torrents", comment: "")
        case .media: NSLocalizedString("nav.media", comment: "")
        case .rss: NSLocalizedString("nav.rss", comment: "")
        case .grabber: NSLocalizedString("nav.grabber", comment: "")
        case .history: NSLocalizedString("nav.history", comment: "")
        case .scheduler: NSLocalizedString("nav.scheduler", comment: "")
        case .settings: NSLocalizedString("nav.settings", comment: "")
        case .about: NSLocalizedString("nav.about", comment: "")
        }
    }
}

/// Chunky neo-brutalist sidebar: icon + label rows with count badges for
/// downloads/torrents.
struct Sidebar: View {
    @Binding var selection: SidebarSelection
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(MediaEngine.self) private var mediaEngine: MediaEngine
    @Environment(LinkGrabberStore.self) private var linkGrabberStore: LinkGrabberStore
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            brandHeader
            NeoDivider()
                .padding(.vertical, 2)
            ForEach(SidebarSelection.mainTabs, id: \.self) { item in
                sidebarRow(for: item)
            }
            Spacer()
            appearanceRow
            NeoDivider()
            ForEach(SidebarSelection.bottomTabs, id: \.self) { item in
                sidebarRow(for: item)
            }
        }
        .padding(12)
        // Explicit language dependency: NavigationSplitView reuses its
        // sidebar column across MainView's `.id(language)` re-key, so the
        // sidebar rendered with the *previous* language's strings until an
        // unrelated re-render (tab switch, download tick). Re-keying the
        // column itself on language change fixes the lag.
        .id(settings.settings.language)
        // Explicit column background: the default sidebar material would not
        // follow our theme override, which left the sidebar light while the
        // content went dark.
        .background(Neo.paper(scheme))
    }

    // MARK: - Rows

    /// Brand block at the top of the sidebar (reference-style app tile).
    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Grabbit")
                .font(.headline.weight(.black))
            Text(NSLocalizedString("sidebar.subtitle", comment: ""))
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Neo.ink(scheme))
        .padding(.vertical, 2)
    }

    /// Cycles System → Light → Dark. Lives in the sidebar because the system
    /// draws a capsule around toolbar items, which clashes with the paper
    /// chrome; here it matches the other rows. The appearance itself is
    /// applied by MainView, which observes the same SettingsStore.
    private var appearanceRow: some View {
        Button {
            cycleTheme()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appearanceIcon)
                    .frame(width: 22)
                Text(NSLocalizedString("settings.section.appearance", comment: ""))
                    .font(.headline)
                Spacer()
                Text(appearanceName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Neo.paper(scheme))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Neo.ink(scheme), lineWidth: 2))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Neo.ink(scheme))
            .background(Neo.paper(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("sidebar.appearance.help", comment: ""))
    }

    private var appearanceIcon: String {
        switch settings.settings.theme {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    private var appearanceName: String {
        switch settings.settings.theme {
        case .system: NSLocalizedString("settings.theme.system", comment: "")
        case .light: NSLocalizedString("settings.theme.light", comment: "")
        case .dark: NSLocalizedString("settings.theme.dark", comment: "")
        }
    }

    private func cycleTheme() {
        switch settings.settings.theme {
        case .system: settings.settings.theme = .light
        case .light: settings.settings.theme = .dark
        case .dark: settings.settings.theme = .system
        }
        settings.save()
    }

    private func sidebarRow(for item: SidebarSelection) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .frame(width: 22)
                Text(item.localizedTitle)
                    .font(.headline)
                Spacer()
                if let count = count(for: item) {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Neo.onAccent(Neo.paper(scheme), scheme: scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Neo.paper(scheme))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Neo.ink(scheme), lineWidth: 2))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selected row sits on bright yellow — dark text in both modes.
            .foregroundStyle(Neo.onAccent(isSelected ? Neo.yellow : Neo.paper(scheme), scheme: scheme))
            .background(isSelected ? Neo.yellow : Neo.paper(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: isSelected ? 3 : 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// Badge counts: only actively-downloading tasks, and hidden entirely
    /// when zero — a "0" badge next to every tab is noise.
    private func count(for item: SidebarSelection) -> Int? {
        let n: Int
        switch item {
        case .downloads:
            n = engine.items.filter { $0.state == .downloading }.count
        case .torrents:
            n = torrentEngine.torrents.filter { $0.state == .downloading }.count
        case .media:
            // MediaEngine serializes probe/download, so the active media
            // download is either probing or downloading.
            let active = mediaEngine.state == .probing || mediaEngine.state == .downloading
            n = active ? 1 : 0
        case .linkgrabber:
            n = linkGrabberStore.stagedCount
        case .grabber, .rss, .history, .scheduler, .settings, .about:
            return nil
        }
        return n > 0 ? n : nil
    }

}
