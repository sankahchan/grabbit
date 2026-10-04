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
        .background(Neo.sidebar(scheme))
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
                        .foregroundStyle(
                            Neo.shape.brutalist
                                ? Neo.onAccent(Neo.paper(scheme), scheme: scheme)
                                : Neo.ink2(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Neo.shape.brutalist ? Neo.paper(scheme) : Neo.card(scheme))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                Neo.ink(scheme),
                                lineWidth: Neo.shape.brutalist ? 2 : 0))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selectionForeground(isSelected))
            .background(rowBackground(isSelected))
            .clipShape(RoundedRectangle(
                cornerRadius: Neo.shape.brutalist ? 10 : 12, style: .continuous))
            .overlay(
                RoundedRectangle(
                    cornerRadius: Neo.shape.brutalist ? 10 : 12, style: .continuous)
                    .stroke(
                        Neo.ink(scheme),
                        lineWidth: Neo.shape.brutalist
                            ? (isSelected ? 3 : 2)
                            : (isSelected ? 1 : 0))
                    .opacity(Neo.shape.brutalist ? 1 : 0.10)
            )
        }
        .buttonStyle(.plain)
    }

    private func selectionForeground(_ isSelected: Bool) -> Color {
        if Neo.shape.brutalist {
            // Selected row sits on bright yellow — dark text in both modes.
            return Neo.onAccent(isSelected ? Neo.yellow : Neo.paper(scheme), scheme: scheme)
        }
        return isSelected ? Neo.ink(scheme) : Neo.ink2(scheme)
    }

    private func rowBackground(_ isSelected: Bool) -> Color {
        if Neo.shape.brutalist {
            return isSelected ? Neo.yellow : Neo.paper(scheme)
        }
        return isSelected ? Neo.card(scheme) : Color.clear
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
