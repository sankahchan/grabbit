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
        // With a transparent titlebar the drag strip gets thin; letting the
        // window move from any background area makes it easy to reposition.
        window.isMovableByWindowBackground = true
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
    /// Bundled release notes shown once after an update.
    @State private var whatsNew: ReleaseNotes.Digest?
    @State private var whatsNewVersion = ""

    var body: some View {
        // Keep the global theme runtime in sync before descendants render;
        // the .id() below rebuilds the tree when the style changes.
        let themeStyle = store.settings.themeStyle
        let _ = ThemeRuntime.current = themeStyle
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
        // The system toolbar material paints a white band over the paper in
        // light mode (and a mismatched band in dark). Tint the window toolbar
        // and the titlebar strip to the same paper as the content.
        .toolbarBackground(Neo.paper(effectiveScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowPaper(color: NSColor(Neo.paper(effectiveScheme))))
        // Completion/failure cards now render inline at the top of the
        // Downloads / Torrents tabs (inside each tab's own card) instead
        // of a floating overlay.
        // The Appearance setting drives the UI at the AppKit level.
        // preferredColorScheme did NOT reliably clear a concrete override
        // when going back to System (Dark -> System left the UI dark), so
        // we set NSApp.appearance directly instead — nil follows the
        // system, and the SwiftUI colorScheme environment follows the
        // effective appearance automatically.
        .onAppear {
            applyAppearance()
            presentWhatsNewIfNeeded()
        }
        .onChange(of: store.settings.theme) { _, _ in applyAppearance() }
        .sheet(isPresented: Binding(
            get: { whatsNew != nil },
            set: { if !$0 { whatsNew = nil } })
        ) {
            if let digest = whatsNew {
                WhatsNewView(digest: digest, version: whatsNewVersion) {
                    whatsNew = nil
                }
            }
        }
        // Persists the window's size/position across launches when enabled
        // in Settings > Basic > Startup.
        .background(WindowFrameSaver(enabled: store.settings.keepWindowFrame))
        // Re-key on language + theme style: rebuilding the hierarchy makes
        // every NSLocalizedString re-evaluate (instant language switch) and
        // every Neo.* token read resolve against the new theme.
        .id("\(store.settings.language.rawValue)-\(store.settings.themeStyle.rawValue)")
    }

    /// Shows the bundled release notes once per update. The version is
    /// recorded immediately so the sheet never reappears on the next launch.
    private func presentWhatsNewIfNeeded() {
        let key = "com.sankahchan.grabbit.lastSeenVersion"
        guard let current = ReleaseNotes.currentVersion() else { return }
        let lastSeen = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard ReleaseNotes.shouldPresent(lastSeen: lastSeen, current: current),
              let text = ReleaseNotes.bundledText()
        else { return }
        let digest = ReleaseNotes.parse(text)
        guard !digest.isEmpty else { return }
        whatsNewVersion = current
        whatsNew = digest
    }

    /// Concrete scheme, resolving "System" through the environment. The
    /// toolbar does not reliably inherit the app-applied appearance, so the
    /// titlebar tint derives from the Appearance setting instead.
    private var effectiveScheme: ColorScheme {
        switch store.settings.theme {
        case .light: .light
        case .dark: .dark
        case .system: scheme
        }
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
        case .rss:
            RSSFeedsView()
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
