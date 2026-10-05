import SwiftUI
import AppKit
import Sparkle
import Observation

// TODO(code-signing): ad-hoc / Developer ID signing is intentionally disabled
// for local scaffolding (see project.yml). Before public distribution, enable
// signing and run Sparkle's `generate_keys` tool, then paste the public key
// into project.yml's SUPublicEDKey.

/// Keeps the app alive when the main window closes: tray/hidden run modes
/// deliberately hide the window and live in the menu bar, so the default
/// "quit after the last window closes" behavior would terminate them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct GrabbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var downloadEngine: DownloadEngine
    @State private var torrentEngine: TorrentEngine
    @State private var mediaEngine: MediaEngine
    @State private var historyStore: HistoryStore
    @State private var settings: SettingsStore
    @State private var schedulerStore: SchedulerStore
    @State private var queueStore: QueueStore
    @State private var watchFolderStore: WatchFolderStore
    @State private var linkGrabberStore: LinkGrabberStore
    @State private var toastCenter: ToastCenter
    @State private var completionCenter: CompletionActionCenter
    /// Backlog #3/#4: per-host profiles and packagizer rules.
    @State private var hostProfileStore: HostProfileStore
    @State private var packagizerStore: PackagizerStore
    /// RSS subscriptions: persisted feeds + the polling monitor.
    @State private var rssStore = RSSStore()
    @State private var rssMonitor = RSSMonitor()
    /// Phase 5 watch folders: plain let — it owns no UI state itself.
    private let watchMonitor = WatchFolderMonitor()
    @State private var updater: SPUStandardUpdaterController?
    @State private var nativeMessagingHost: NativeMessagingHost?
    @State private var trayController: TrayController
    /// Sidebar selection shared with the URL-scheme handlers so incoming
    /// grabs switch to the tab that shows them.
    @State private var navigation = AppNavigation()

    // @MainActor: TorrentEngine is main-actor-isolated, so it must be built here.
    @MainActor
    init() {
        // Pulse's dot-matrix UI font (Doto, OFL) — one process-lifetime
        // registration; other themes never reference it.
        NeoFont.registerBundledFonts()
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
        // Phase 5 named queues: one store shared by the engine and the UI.
        let sharedQueues = QueueStore()
        _queueStore = State(initialValue: sharedQueues)
        _watchFolderStore = State(initialValue: WatchFolderStore())
        _linkGrabberStore = State(initialValue: LinkGrabberStore())
        _toastCenter = State(initialValue: ToastCenter())
        _downloadEngine = State(initialValue: DownloadEngine(history: sharedHistory, settings: sharedSettings, queues: sharedQueues))
        _torrentEngine = State(initialValue: TorrentEngine(settings: sharedSettings, history: sharedHistory))
        // Toast cards: both engines push completion/failure cards here.
        _downloadEngine.wrappedValue.toastCenter = _toastCenter.wrappedValue
        _torrentEngine.wrappedValue.toastCenter = _toastCenter.wrappedValue
        // Backlog #3/#4: per-host profiles and packagizer rules feed the
        // download engine's add path.
        _hostProfileStore = State(initialValue: HostProfileStore())
        _packagizerStore = State(initialValue: PackagizerStore())
        _downloadEngine.wrappedValue.hostProfileStore = _hostProfileStore.wrappedValue
        _downloadEngine.wrappedValue.packagizerStore = _packagizerStore.wrappedValue
        // After-downloads-finish actions (sleep/shutdown/quit/command).
        _completionCenter = State(initialValue: CompletionActionCenter(settings: sharedSettings))
        _completionCenter.wrappedValue.configure(
            downloads: _downloadEngine.wrappedValue,
            torrents: _torrentEngine.wrappedValue)
        _downloadEngine.wrappedValue.completionCenter = _completionCenter.wrappedValue
        _torrentEngine.wrappedValue.completionCenter = _completionCenter.wrappedValue
        _mediaEngine = State(initialValue: MediaEngine(history: sharedHistory))
        // Media downloads should surface completion/failure the same way
        // direct downloads do (extension-triggered yt-dlp runs have no
        // visible Media tab otherwise).
        _mediaEngine.wrappedValue.toastCenter = _toastCenter.wrappedValue
        _mediaEngine.wrappedValue.settingsStore = sharedSettings
        _schedulerStore = State(initialValue: SchedulerStore())
        _trayController = State(initialValue: TrayController())
        _trayController.wrappedValue.configure(
            downloads: _downloadEngine.wrappedValue,
            torrents: _torrentEngine.wrappedValue)
        // LinkGrabber staging: dedup + probe + commit through the engine.
        _linkGrabberStore.wrappedValue.configure(
            downloadEngine: _downloadEngine.wrappedValue)
        // One-time import of already-finished tasks so existing users don't
        // start with an empty history. Runs only when the store is empty.
        sharedHistory.backfillIfNeeded(
            downloads: _downloadEngine.wrappedValue.items,
            torrents: _torrentEngine.wrappedValue.torrents)
        // Sparkle's updater can't start in an unsigned dev build (it needs a
        // signed app + real SUPublicEDKey), and the failure pops an error
        // dialog. Only create it when it's actually usable.
        if Self.isUpdaterConfigured {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            // Settings > Check Now needs a handle, and the persisted
            // "automatically check for updates" preference must reach Sparkle.
            UpdaterBridge.controller = controller
            controller.updater.automaticallyChecksForUpdates =
                sharedSettings.settings.autoUpdateEnabled
            _updater = State(initialValue: controller)
        }
    }

    /// Extension media naming: the page title when present; otherwise a
    /// filename that isn't a generic playlist name ("master.m3u8" etc.).
    static func mediaName(for request: GrabbitURLRequest) -> String? {
        if let title = request.title, !title.isEmpty {
            return title
        }
        guard let filename = request.filename else { return nil }
        let base = (filename as NSString).deletingPathExtension
        let generic: Set<String> = ["master", "index", "playlist", "manifest", "video", "stream"]
        guard !base.isEmpty, !generic.contains(base.lowercased()) else { return nil }
        return base
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
                .environment(schedulerStore)
                .environment(queueStore)
                .environment(watchFolderStore)
                .environment(linkGrabberStore)
                .environment(toastCenter)
                .environment(completionCenter)
                .environment(hostProfileStore)
                .environment(packagizerStore)
                .environment(rssStore)
                .environment(rssMonitor)
                .environment(navigation)
                .onOpenURL { url in
                    NSLog("[Grabbit] onOpenURL: %@", url.absoluteString)
                    // In tray mode the window is hidden — a link click
                    // should bring it forward so the new task is visible.
                    if settings.settings.runMode == .tray {
                        MainWindowHolder.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    // magnet:?xt=… — handed to the torrent engine (clicking a
                    // magnet link anywhere opens Grabbit).
                    if url.scheme?.lowercased() == "magnet" {
                        navigation.selection = .torrents
                        let magnet = url.absoluteString
                        let savePath = settings.folderURL(for: .other)
                        Task { @MainActor in
                            try? await torrentEngine.add(
                                magnetOrURL: magnet, savePath: savePath)
                        }
                        return
                    }
                    // grabbit://import?payload=… — a capture (Telegram blob /
                    // MSE stream) or a finished browser download the native
                    // helper handed over. It is already on disk.
                    if url.scheme?.lowercased() == "grabbit",
                       url.host?.lowercased() == "import"
                    {
                        guard let request = GrabbitURLScheme.parseImport(url) else { return }
                        // The payload carried captured metadata (URLs, page
                        // titles); it has served its purpose — remove it so
                        // nothing lingers in the Inbox.
                        if let payloadURL = request.payloadURL {
                            try? FileManager.default.removeItem(at: payloadURL)
                        }
                        navigation.selection = .downloads
                        Task { @MainActor in
                            await downloadEngine.importCompletedFile(
                                at: request.fileURL,
                                auxiliaryAudioURL: request.auxiliaryAudioURL,
                                suggestedName: request.filename,
                                sourcePageURL: request.pageURL,
                                sourceSite: request.source == "extension-stream" ? .telegram : .other,
                                mimeType: request.mimeType)
                        }
                        return
                    }
                    // grabbit://download?url=… — from the browser extension,
                    // Shortcuts, or anywhere else.
                    guard let request = GrabbitURLScheme.parse(url) else {
                        NSLog("[Grabbit] URL parse failed")
                        return
                    }
                    // The payload carried captured request headers (cookies
                    // included) — delete it now that it is decoded.
                    if let payloadURL = request.payloadURL {
                        try? FileManager.default.removeItem(at: payloadURL)
                    }
                    Task { @MainActor in
                        // Stream playlists (m3u8/mpd) go to the media engine
                        // (yt-dlp) for proper video download, not the direct
                        // engine which would just save the playlist text.
                        let lower = request.url.absoluteString.lowercased()
                        if lower.contains(".m3u8") || lower.contains(".mpd") {
                            NSLog("[Grabbit] routing to MediaEngine: %@", request.url.absoluteString)
                            // Show the Media tab so the in-progress media
                            // download is visible immediately.
                            navigation.selection = .media
                            let directory = settings.folderURL(for: .video)
                            mediaEngine.speedLimitBytesPerSec = settings.settings.speedLimitBytesPerSec
                            await mediaEngine.downloadStream(
                                url: request.url,
                                to: directory,
                                headers: request.headers,
                                preferredName: Self.mediaName(for: request))
                            NSLog("[Grabbit] MediaEngine.downloadStream returned (state=%@)",
                                  String(describing: mediaEngine.state))
                        } else {
                            // Direct downloads land in the Downloads tab.
                            navigation.selection = .downloads
                            await downloadEngine.add(
                                url: request.url,
                                filename: request.filename,
                                headers: request.headers.isEmpty ? nil : request.headers)
                        }
                    }
                }
                .onAppear {
                    applyRunMode(initial: true)
                    // Keep the browser native-messaging pieces current: the
                    // bundled helper is copied into App Support and the host
                    // manifests are (re)written, so app updates deliver
                    // helper fixes without a manual install-host.sh run.
                    DispatchQueue.global(qos: .utility).async {
                        NativeHostInstaller.installIfNeeded()
                    }
                    // Durable finalize: complete any journal left by a crash
                    // (file moved but completion never persisted) before the
                    // resume logic sees the items.
                    downloadEngine.reconcileFinalizeJournals()
                    // Startup > "Auto-resume unfinished tasks": interrupted
                    // downloads restart on launch instead of waiting behind
                    // the recovery banner in the Downloads tab.
                    if settings.settings.autoResumeOnLaunch {
                        downloadEngine.resumeAllInterrupted()
                    }
                    // Ask once for notification authorization (completion /
                    // failure toasts); a no-op once decided.
                    Notifier.requestAuthorizationIfNeeded()
                    // Phase 5 scheduler: persisted entries + 1-minute
                    // firing timer driving both engines.
                    schedulerStore.start(
                        downloadEngine: downloadEngine,
                        torrentEngine: torrentEngine,
                        settings: settings)
                    // Phase 5 watch folders: poll watched dirs for .txt
                    // link files and feed new links to the engine.
                    watchMonitor.start(
                        store: watchFolderStore,
                        engine: downloadEngine,
                        history: historyStore)
                    // RSS subscriptions: poll feeds on a timer and
                    // auto-download new matching items (media enclosures go
                    // to the direct engine, page links to yt-dlp).
                    rssMonitor.start(
                        store: rssStore,
                        settings: settings,
                        downloadEngine: downloadEngine,
                        mediaEngine: mediaEngine)
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
