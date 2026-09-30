import SwiftUI
import AppKit

/// Bridges NSWindow frame autosave into SwiftUI: when enabled, the main
/// window restores its last size/position on launch and macOS keeps saving
/// it on move/resize. Disabled removes the autosave name (stops saving).
private struct WindowFrameSaver: NSViewRepresentable {
    var enabled: Bool
    private let name = "GrabbitMainWindow"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view, enabled, name] in
            guard let window = view?.window else { return }
            // Tray mode needs a handle to show the window from the menu.
            MainWindowHolder.window = window
            if enabled {
                window.setFrameUsingName(name)
                window.setFrameAutosaveName(name)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        if enabled, window.frameAutosaveName != name {
            window.setFrameAutosaveName(name)
        } else if !enabled, !window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("")
        }
    }
}

/// Root view: NavigationSplitView with a chunky neo-brutalist sidebar.
///
/// Add affordances live inside each tab (Downloads and Torrents each have
/// their own Add button; Media has its URL field), so there is no global
/// toolbar add button.
struct MainView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(SettingsStore.self) private var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: Binding(
                get: { navigation.selection },
                set: { navigation.selection = $0 }))
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detailView
        }
        .navigationTitle("Grabbit")
        // Completion/failure cards now render inline at the top of the
        // Downloads / Torrents tabs (inside each tab's own card) instead
        // of a floating overlay.
        // The Appearance setting drives the UI at the AppKit level.
        // preferredColorScheme did NOT reliably clear a concrete override
        // when going back to System (Dark -> System left the UI dark), so
        // we set NSApp.appearance directly instead — nil follows the
        // system, and the SwiftUI colorScheme environment follows the
        // effective appearance automatically.
        .onAppear { applyAppearance() }
        .onChange(of: store.settings.theme) { _, _ in applyAppearance() }
        // Persists the window's size/position across launches when enabled
        // in Settings > Basic > Startup.
        .background(WindowFrameSaver(enabled: store.settings.keepWindowFrame))
        // Re-key on language: rebuilding the hierarchy makes every
        // NSLocalizedString re-evaluate (instant language switch). Theme
        // needs no rebuild — NSApp.appearance applies immediately.
        .id(store.settings.language.rawValue)
    }

    /// Maps the saved theme onto the app-wide AppKit appearance.
    private func applyAppearance() {
        switch store.settings.theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selection {
        case .downloads:
            DownloadsView()
        case .linkgrabber:
            LinkGrabberView()
        case .torrents:
            TorrentsView()
        case .media:
            MediaView()
        case .grabber:
            GrabberView()
        case .history:
            HistoryView(selection: Binding(
                get: { navigation.selection },
                set: { navigation.selection = $0 }))
        case .scheduler:
            SchedulerView()
        case .settings:
            SettingsView()
        case .about:
            AboutView()
        }
    }
}
