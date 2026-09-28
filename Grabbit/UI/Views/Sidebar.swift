import SwiftUI

enum SidebarSelection: String, Hashable, CaseIterable {
    case downloads, torrents, media, grabber, linkgrabber, scheduler, history, settings

    /// Main tabs, top-to-bottom order.
    static let mainTabs: [SidebarSelection] = [
        .downloads, .torrents, .media, .grabber, .linkgrabber, .scheduler,
    ]
    /// Utility buttons pinned to the sidebar bottom.
    static let bottomTabs: [SidebarSelection] = [.history, .settings]

    var icon: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .linkgrabber: "link"
        case .torrents: "arrow.triangle.2.circlepath" // "magnet" is not a real SF Symbol — renders blank
        case .media: "play.rectangle"
        case .grabber: "globe"
        case .history: "clock.arrow.circlepath"
        case .scheduler: "clock"
        case .settings: "gearshape"
        }
    }

    var localizedTitle: String {
        switch self {
        case .downloads: NSLocalizedString("nav.downloads", comment: "")
        case .linkgrabber: NSLocalizedString("nav.linkgrabber", comment: "")
        case .torrents: NSLocalizedString("nav.torrents", comment: "")
        case .media: NSLocalizedString("nav.media", comment: "")
        case .grabber: NSLocalizedString("nav.grabber", comment: "")
        case .history: NSLocalizedString("nav.history", comment: "")
        case .scheduler: NSLocalizedString("nav.scheduler", comment: "")
        case .settings: NSLocalizedString("nav.settings", comment: "")
        }
    }
}

/// Chunky neo-brutalist sidebar: icon + label rows with count badges for
/// downloads/torrents.
struct Sidebar: View {
    @Binding var selection: SidebarSelection
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(LinkGrabberStore.self) private var linkGrabberStore: LinkGrabberStore
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SidebarSelection.mainTabs, id: \.self) { item in
                sidebarRow(for: item)
            }
            Spacer()
            Divider()
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

    private func count(for item: SidebarSelection) -> Int? {
        switch item {
        case .downloads: engine.items.count
        case .linkgrabber: linkGrabberStore.stagedCount
        case .torrents: torrentEngine.torrents.count
        case .grabber, .media, .history, .scheduler, .settings: nil
        }
    }

}
