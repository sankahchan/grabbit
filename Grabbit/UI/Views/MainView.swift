import SwiftUI

/// Root view: NavigationSplitView with a chunky neo-brutalist sidebar.
///
/// Add affordances live inside each tab (Downloads and Torrents each have
/// their own Add button; Media has its URL field), so there is no global
/// toolbar add button.
struct MainView: View {
    @State private var selection: SidebarSelection = .downloads
    @Environment(SettingsStore.self) private var store: SettingsStore
    // The real system theme, read from ABOVE our own override: a view's
    // environment comes from its parent, so this is unaffected by the
    // preferredColorScheme we apply below.
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detailView
        }
        .navigationTitle("Grabbit")
        // The Appearance setting actually drives the UI: without this the
        // picker only saved the value and everything followed the system.
        .preferredColorScheme(resolvedTheme)
        // Re-key on language AND theme: rebuilding the hierarchy makes
        // every NSLocalizedString re-evaluate (instant language switch)
        // and works around preferredColorScheme not reliably applying
        // when going from a concrete theme back to System (which left a
        // mixed light-sidebar / dark-content state).
        .id(store.settings.language.rawValue + "/" + store.settings.theme.rawValue)
    }

    /// Maps the saved theme to an explicit override — never nil. Resolving
    /// System to the real system theme avoids the stuck-override bug where
    /// going Dark -> System (nil) left the content dark.
    private var resolvedTheme: ColorScheme {
        switch store.settings.theme {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
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
