import SwiftUI

/// Root view: NavigationSplitView with a chunky neo-brutalist sidebar.
///
/// The toolbar's "+ Add" button is contextual: on the Torrents tab it opens the
/// torrent add sheet, everywhere else it opens the download sheet. This keeps a
/// single global add affordance instead of duplicating toolbar buttons per tab.
struct MainView: View {
    @State private var selection: SidebarSelection = .downloads
    @State private var showingAddSheet = false
    @State private var showingTorrentSheet = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detailView
        }
        .navigationTitle("Grabbit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if selection == .torrents {
                        showingTorrentSheet = true
                    } else {
                        showingAddSheet = true
                    }
                } label: {
                    Label(addButtonLabel, systemImage: "plus")
                }
                .neoButton(bg: Neo.yellow)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDownloadSheet()
        }
        .sheet(isPresented: $showingTorrentSheet) {
            TorrentAddSheet()
        }
    }

    private var addButtonLabel: String {
        selection == .torrents
            ? String(localized: "torrents.add")
            : String(localized: "downloads.add")
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .downloads:
            DownloadsView()
        case .torrents:
            TorrentsView()
        case .media:
            MediaView()
        case .grabber:
            GrabberView()
        case .history:
            HistoryView(selection: $selection)
        case .scheduler:
            SchedulerView()
        case .settings:
            SettingsView()
        }
    }
}
