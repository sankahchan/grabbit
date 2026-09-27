import SwiftUI

/// Root view: NavigationSplitView with a chunky neo-brutalist sidebar.
///
/// Add affordances live inside each tab (Downloads and Torrents each have
/// their own Add button; Media has its URL field), so there is no global
/// toolbar add button.
struct MainView: View {
    @State private var selection: SidebarSelection = .downloads

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detailView
        }
        .navigationTitle("Grabbit")
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
