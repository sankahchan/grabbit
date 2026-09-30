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

/// Paints the window's titlebar strip with the theme paper. The SwiftUI
/// toolbar background only tints the toolbar itself; a transparent titlebar
/// plus a matching window background covers the traffic-light strip too.
private struct WindowPaper: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view, color] in
            Self.apply(on: view?.window, color: color)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView, color] in
            Self.apply(on: nsView?.window, color: color)
        }
    }

    private static func apply(on window: NSWindow?, color: NSColor) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = color
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: Binding(
                get: { navigation.selection },
                set: { navigation.selection = $0 }))
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            // Dot-grid paper behind every page (the neo-brutalist signature).
            ZStack {
                NeoDotBackground()
                detailView
            }
        }
        .navigationTitle("Grabbit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                themeToggle
            }
        }
        // The system toolbar material paints a white band over the paper in
        // light mode (and a mismatched band in dark). Tint the window toolbar
        // and the titlebar strip to the same paper as the content.
        .toolbarBackground(Neo.paper(scheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowPaper(color: NSColor(Neo.paper(scheme))))
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

    /// Quick appearance control in the titlebar: cycles System → Light → Dark.
    private var themeToggle: some View {
        Button {
            cycleTheme()
        } label: {
            Image(systemName: themeIcon)
        }
        .neoIconButton(bg: Neo.paper(scheme))
        .help(NSLocalizedString("settings.section.appearance", comment: ""))
    }

    private var themeIcon: String {
        switch store.settings.theme {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    private func cycleTheme() {
        switch store.settings.theme {
        case .system: store.settings.theme = .light
        case .light: store.settings.theme = .dark
        case .dark: store.settings.theme = .system
        }
        store.save()
        applyAppearance()
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
