import SwiftUI

enum SidebarSelection: String, Hashable, CaseIterable {
    case downloads, torrents, media, grabber, history, scheduler, settings

    var icon: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .torrents: "magnet"
        case .media: "play.rectangle"
        case .grabber: "globe"
        case .history: "clock.arrow.circlepath"
        case .scheduler: "clock"
        case .settings: "gearshape"
        }
    }

    var localizedTitle: String {
        switch self {
        case .downloads: String(localized: "nav.downloads")
        case .torrents: String(localized: "nav.torrents")
        case .media: String(localized: "nav.media")
        case .grabber: String(localized: "nav.grabber")
        case .history: String(localized: "nav.history")
        case .scheduler: String(localized: "nav.scheduler")
        case .settings: String(localized: "nav.settings")
        }
    }
}

/// Chunky neo-brutalist sidebar: icon + label rows with count badges for
/// downloads/torrents.
struct Sidebar: View {
    @Binding var selection: SidebarSelection
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SidebarSelection.allCases, id: \.self) { item in
                sidebarRow(for: item)
            }
            Spacer()
        }
        .padding(12)
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
        case .torrents: torrentEngine.torrents.count
        case .grabber, .media, .history, .scheduler, .settings: nil
        }
    }

}
