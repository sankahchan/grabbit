import SwiftUI
import AppKit
import Sparkle
import Observation

// TODO(code-signing): ad-hoc / Developer ID signing is intentionally disabled
// for local scaffolding (see project.yml). Before public distribution, enable
// signing and run Sparkle's `generate_keys` tool, then paste the public key
// into project.yml's SUPublicEDKey.

@main
struct GrabbitApp: App {
    @State private var downloadEngine: DownloadEngine
    @State private var torrentEngine: TorrentEngine
    @State private var mediaEngine: MediaEngine
    @State private var historyStore: HistoryStore
    @State private var settings: SettingsStore
    @State private var updater: SPUStandardUpdaterController?
    @State private var nativeMessagingHost: NativeMessagingHost?
    @State private var trayController: TrayController

    // @MainActor: TorrentEngine is main-actor-isolated, so it must be built here.
    @MainActor
    init() {
        // One SettingsStore shared by the app and the torrent engine (the
        // engine reads the VPN kill-switch and seeding defaults live).
        let sharedSettings = SettingsStore()
        // Apply the saved language immediately — without this the UI only
        // follows AppleLanguages at launch.
        BundleLocalization.apply(sharedSettings.settings.language)
        // One HistoryStore shared by all three engines; completions and
        // failures across downloads/torrents/media land in a single log.
        let sharedHistory = HistoryStore()
        _settings = State(initialValue: sharedSettings)
        _historyStore = State(initialValue: sharedHistory)
        _downloadEngine = State(initialValue: DownloadEngine(history: sharedHistory, settings: sharedSettings))
        _torrentEngine = State(initialValue: TorrentEngine(settings: sharedSettings, history: sharedHistory))
        _mediaEngine = State(initialValue: MediaEngine(history: sharedHistory))
        _trayController = State(initialValue: TrayController())
        _trayController.wrappedValue.configure(
            downloads: _downloadEngine.wrappedValue,
            torrents: _torrentEngine.wrappedValue)
        // One-time import of already-finished tasks so existing users don't
        // start with an empty history. Runs only when the store is empty.
        sharedHistory.backfillIfNeeded(
            downloads: _downloadEngine.wrappedValue.items,
            torrents: _torrentEngine.wrappedValue.torrents)
        // Sparkle's updater can't start in an unsigned dev build (it needs a
        // signed app + real SUPublicEDKey), and the failure pops an error
        // dialog. Only create it when it's actually usable.
        if Self.isUpdaterConfigured {
            _updater = State(initialValue: SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            ))
        }
    }

    /// True for signed Release builds with a real Sparkle Ed25519 key.
    /// Dev builds (and Release builds before `generate_keys` is run) skip
    /// the updater entirely instead of showing "Unable to Check For Updates".
    static var isUpdaterConfigured: Bool {
        #if DEBUG
        return false
        #else
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              !key.hasPrefix("TODO") else { return false }
        return true
        #endif
    }

    var body: some Scene {
        // Single-window scene: unlike WindowGroup, a Window never spawns a
        // new window for an incoming URL event (magnet:/grabbit:) — the URL
        // is delivered to this window's onOpenURL instead. WindowGroup's
        // default external-event routing opened a fresh window per click.
        Window("Grabbit", id: "main") {
            // MainView is owned by another workstream; it reads the engines and
            // settings from the environment.
            MainView()
                .environment(downloadEngine)
                .environment(torrentEngine)
                .environment(mediaEngine)
                .environment(historyStore)
                .environment(settings)
                .onOpenURL { url in
                    // In tray mode the window is hidden — a link click
                    // should bring it forward so the new task is visible.
                    if settings.settings.runMode == .tray {
                        MainWindowHolder.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    // magnet:?xt=… — handed to the torrent engine (clicking a
                    // magnet link anywhere opens Grabbit).
                    if url.scheme?.lowercased() == "magnet" {
                        let magnet = url.absoluteString
                        let savePath = settings.folderURL(for: .other)
                        Task { @MainActor in
                            try? await torrentEngine.add(
                                magnetOrURL: magnet, savePath: savePath)
                        }
                        return
                    }
                    // grabbit://download?url=… — from the browser extension,
                    // Shortcuts, or anywhere else.
                    guard let request = GrabbitURLScheme.parse(url) else { return }
                    Task { @MainActor in
                        await downloadEngine.add(
                            url: request.url,
                            filename: request.filename,
                            headers: request.headers.isEmpty ? nil : request.headers)
                    }
                }
                .onAppear {
                    applyRunMode(initial: true)
                    // Browser-extension mode: stdin/stdout are the
                    // native-messaging channel, not a normal launch.
                    if CommandLine.arguments.contains("--native-messaging") {
                        let host = NativeMessagingHost()
                        host.onMessage = { message in
                            // NativeMessagingHost invokes this on its reader
                            // thread; hop to the main actor for the engine.
                            Task { @MainActor in
                                let scheme = message.url.scheme?.lowercased()
                                guard scheme == "http" || scheme == "https" else { return }
                                await downloadEngine.add(
                                    url: message.url,
                                    filename: message.filename,
                                    sourcePageURL: message.pageUrl,
                                    headers: message.headers)
                            }
                        }
                        host.start()
                        nativeMessagingHost = host
                    }
                }
                .onChange(of: settings.settings.runMode) { _, _ in
                    applyRunMode(initial: false)
                }
        }
    }

    // MARK: - Run As (tray mode)

    private static var initialRunModeApplied = false

    /// Tray/hidden drop the Dock icon (activation policy .accessory).
    /// Tray mode additionally shows the menu-bar extra and starts with
    /// the main window hidden — the app lives in the menu bar until
    /// opened from the menu or a link click.
    private func applyRunMode(initial: Bool) {
        let mode = settings.settings.runMode
        NSApp.setActivationPolicy(mode == .standard ? .regular : .accessory)
        trayController.setVisible(mode == .tray)
        if initial, !Self.initialRunModeApplied {
            Self.initialRunModeApplied = true
            if mode == .tray {
                // WindowFrameSaver captures the window on the next
                // main-loop turn; hide after that so capture wins.
                DispatchQueue.main.async {
                    MainWindowHolder.window?.orderOut(nil)
                }
            }
        }
    }
}
