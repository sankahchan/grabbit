import SwiftUI
import AppKit
import ServiceManagement

/// Settings tab: neo-styled cards for basic, downloads, torrents, and
/// updates. Everything binds to `SettingsStore` and persists via `save()`
/// on change.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(QueueStore.self) private var queueStore: QueueStore
    @Environment(WatchFolderStore.self) private var watchFolderStore: WatchFolderStore
    @Environment(DownloadEngine.self) private var downloadEngine: DownloadEngine
    @Environment(\.colorScheme) private var scheme
    /// Display name of the app macOS currently routes magnet: links to
    /// (e.g. "Motrix"); empty when none is set.
    @State private var magnetAppName = ""
    /// Phase 5 named queues: name for the queue being added.
    @State private var newQueueName = ""

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                NeoPageHeader(
                    sticker: NSLocalizedString("page.settings.sticker", comment: ""),
                    title: NSLocalizedString("settings.title", comment: ""),
                    accent: Neo.pink)
                // One wide Basic card (Motrix-style): appearance, language,
                // startup, seeding, and task management. Downloads, automation
                // and torrents get their own cards below. Content breathes with
                // the window (capped at 900 so rows don't stretch across
                // ultra-wide displays). Update controls live in the About tab.
                basicCard(settings: settings)
                downloadsCard(settings: settings)
                mediaCard(settings: settings)
                automationCard
                torrentsCard(settings: settings)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("settings.title", comment: ""))
        .onAppear {
            refreshMagnetHandler()
            syncOpenAtLogin()
        }
        .modifier(SettingsChangeHandlers(
            onLanguageChange: handleLanguageChange,
            onOpenAtLogin: applyOpenAtLogin))
        .modifier(ProxyChangeHandlers())
        .modifier(MediaChangeHandlers())
    }

    // MARK: - Change handlers

    /// The settings screen's `.onChange` save triggers, extracted into
    /// ViewModifiers so the main `body` stays small enough for the
    /// type-checker (the full modifier chain timed it out in CI).
    /// Split in two so neither chain gets long enough to stall it.
    private struct SettingsChangeHandlers: ViewModifier {
        @Environment(SettingsStore.self) private var store: SettingsStore
        var onLanguageChange: (AppLanguage, AppLanguage) -> Void
        var onOpenAtLogin: (Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.theme) { _, _ in store.save() }
                .onChange(of: store.settings.language, onLanguageChange)
                .onChange(of: store.settings.clipboardMonitorEnabled) { _, _ in store.save() }
                .onChange(of: store.settings.autoResumeOnLaunch) { _, _ in store.save() }
                .onChange(of: store.settings.autoClearFinished) { _, _ in store.save() }
                .onChange(of: store.settings.autoUpdateTrackers) { _, _ in store.save() }
                .onChange(of: store.settings.trackerSyncHours) { _, _ in store.save() }
                .onChange(of: store.settings.notificationsEnabled) { _, _ in store.save() }
                .onChange(of: store.settings.showCompletionToast) { _, _ in store.save() }
                .onChange(of: store.settings.showFailureToast) { _, _ in store.save() }
                .onChange(of: store.settings.completionSoundEnabled) { _, _ in store.save() }
                .onChange(of: store.settings.autoExtractArchives) { _, _ in store.save() }
                .onChange(of: store.settings.deleteArchiveAfterExtract) { _, _ in store.save() }
                .onChange(of: store.settings.completionAction) { _, _ in store.save() }
                .onChange(of: store.settings.completionCommand) { _, _ in store.save() }
                .modifier(SettingsChangeHandlersB(onOpenAtLogin: onOpenAtLogin))
        }
    }

    private struct SettingsChangeHandlersB: ViewModifier {
        @Environment(SettingsStore.self) private var store: SettingsStore
        @Environment(DownloadEngine.self) private var downloadEngine: DownloadEngine
        @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
        var onOpenAtLogin: (Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.autoClearFailed) { _, _ in store.save() }
                .onChange(of: store.settings.defaultConnections) { _, _ in store.save() }
                .onChange(of: store.settings.speedLimitBytesPerSec) { _, _ in
                    store.save()
                    // Phase 5 speed limiter: push the new cap into the
                    // running engines immediately (no relaunch).
                    downloadEngine.syncSpeedLimit()
                    Task { await torrentEngine.applySpeedLimit() }
                }
                .onChange(of: store.settings.vpnKillSwitchEnabled) { _, _ in store.save() }
                .onChange(of: store.settings.vpnInterfaceName) { _, _ in store.save() }
                .onChange(of: store.settings.defaultSeedRatio) { _, _ in store.save() }
                .onChange(of: store.settings.defaultSeedTimeMinutes) { _, _ in store.save() }
                .onChange(of: store.settings.openAtLogin) { _, new in
                    store.save()
                    onOpenAtLogin(new)
                }
                .onChange(of: store.settings.keepWindowFrame) { _, _ in store.save() }
                .onChange(of: store.settings.maxActiveTasks) { _, _ in
                    store.save()
                    downloadEngine.kickQueue()
                    Task { await torrentEngine.applyMaxActiveTasks() }
                }
                .onChange(of: store.settings.runMode) { _, _ in store.save() }
        }
    }

    // MARK: - Proxy change handlers

    /// Phase 5 proxy: saves + pushes the proxy into the running aria2
    /// daemon. A third small modifier so the main settings chains stay
    /// short enough for the type-checker. The native engine reads the
    /// proxy live at segment launch, so only torrents need the push.
    private struct ProxyChangeHandlers: ViewModifier {
        @Environment(SettingsStore.self) private var store: SettingsStore
        @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine

        private func proxyChanged() {
            store.save()
            Task { await torrentEngine.applyProxy() }
        }

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.proxyMode) { _, _ in proxyChanged() }
                .onChange(of: store.settings.proxyHost) { _, _ in proxyChanged() }
                .onChange(of: store.settings.proxyPort) { _, _ in proxyChanged() }
                .onChange(of: store.settings.proxyUsername) { _, _ in proxyChanged() }
                .onChange(of: store.settings.proxyPassword) { _, _ in proxyChanged() }
                // Performance profile: save + push into the running daemon.
                .onChange(of: store.settings.torrentPerformanceProfile) { _, _ in
                    store.save()
                    Task { await torrentEngine.applyPerformanceProfile() }
                }
        }
    }

    // MARK: - Language

    /// Applies the language instantly (no restart): the main bundle is
    /// re-pointed at the chosen language's `.lproj`, and MainView's
    /// `.id(language)` rebuilds the whole hierarchy so every tab
    /// re-renders in the new language immediately.
    private func handleLanguageChange(_ old: AppLanguage, _ new: AppLanguage) {
        BundleLocalization.apply(new)
        store.save()
    }

    // MARK: - Sections

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.heavy))
            .textCase(.uppercase)
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.heavy))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    /// Motrix-style wide card: appearance, language, startup, seeding, and
    /// task management in one place.
    private func basicCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.basic", comment: ""))
            subHeader(NSLocalizedString("settings.section.appearance", comment: ""))
            // Icons so the theme reads at a glance, not just as text.
            // Capped width — full-bleed segments look stretched in a wide card.
            HStack {
                NeoSegmented(selection: settings.theme, options: [
                    .init(value: ThemeMode.system,
                          title: NSLocalizedString("settings.theme.system", comment: ""),
                          icon: "circle.lefthalf.filled"),
                    .init(value: ThemeMode.light,
                          title: NSLocalizedString("settings.theme.light", comment: ""),
                          icon: "sun.max.fill"),
                    .init(value: ThemeMode.dark,
                          title: NSLocalizedString("settings.theme.dark", comment: ""),
                          icon: "moon.fill"),
                ])
                .frame(maxWidth: 420)
                Spacer()
            }
            subHeader(NSLocalizedString("settings.section.language", comment: ""))
            HStack {
                // Autonyms are shown in their own language by convention.
                // The bundle MUST switch before the observable mutation:
                // every body re-evaluated after this point (sidebar
                // included) resolves NSLocalizedString in the new language.
                // Doing it in .onChange instead left the sidebar baking
                // stale strings one toggle behind — the .id() re-key ran
                // before apply().
                let language = Binding<AppLanguage>(
                    get: { settings.wrappedValue.language },
                    set: { new in
                        BundleLocalization.apply(new)
                        settings.wrappedValue.language = new
                    }
                )
                NeoSegmented(selection: language, titles: [
                    (AppLanguage.system, NSLocalizedString("settings.language.system", comment: "")),
                    (AppLanguage.en, "English"),
                    (AppLanguage.my, "မြန်မာ"),
                ])
                .frame(maxWidth: 420)
                Spacer()
            }
            Text(NSLocalizedString("settings.language.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(NSLocalizedString("settings.notifications", comment: ""), isOn: settings.notificationsEnabled)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.toast.completed", comment: ""), isOn: settings.showCompletionToast)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.toast.failed", comment: ""), isOn: settings.showFailureToast)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.toast.sound", comment: ""), isOn: settings.completionSoundEnabled)
            .toggleStyle(NeoToggleStyle())
            runAsRow(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.section.startup", comment: ""))
            Toggle(NSLocalizedString("settings.startup.openAtLogin", comment: ""), isOn: settings.openAtLogin)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.startup.keepWindowFrame", comment: ""), isOn: settings.keepWindowFrame)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.startup.autoResumeTasks", comment: ""), isOn: settings.autoResumeOnLaunch)
            .toggleStyle(NeoToggleStyle())
            NeoDivider()
            subHeader(NSLocalizedString("settings.section.seeding", comment: ""))
            seedRatioRow(settings: settings)
            seedTimeRow(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.section.taskManagement", comment: ""))
            maxActiveTasksRow(settings: settings)
            NeoDivider()
            completionSection(settings: settings)
        }
        .neoCard()
    }

    private func maxActiveTasksRow(settings: Binding<AppSettings>) -> some View {
        let count = Binding<Int>(
            get: { settings.wrappedValue.maxActiveTasks },
            set: {
                settings.wrappedValue.maxActiveTasks = max(1, $0)
                store.save()
            }
        )
        return HStack {
            Text(NSLocalizedString("settings.maxActiveTasks", comment: ""))
                .font(.subheadline.weight(.semibold))
            Spacer()
            NeoStepper(value: count, in: 1...20, step: 1) { "\($0)" }
        }
    }

    private func downloadsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.downloads", comment: ""))
            ForEach(DownloadCategory.allCases, id: \.self) { category in
                folderRow(for: category, settings: settings)
            }
            NeoDivider()
            speedLimitRow(settings: settings)
            Toggle(NSLocalizedString("settings.clipboard", comment: ""), isOn: settings.clipboardMonitorEnabled)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.autoClear", comment: ""), isOn: settings.autoClearFinished)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.autoClearFailed", comment: ""), isOn: settings.autoClearFailed)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.autoClear.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            NeoDivider()
            subHeader(NSLocalizedString("settings.section.archives", comment: ""))
            Toggle(NSLocalizedString("settings.archives.autoExtract", comment: ""), isOn: settings.autoExtractArchives)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.archives.deleteAfterExtract", comment: ""), isOn: settings.deleteArchiveAfterExtract)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.archives.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            NeoDivider()
            proxySection(settings: settings)
        }
        .neoCard()
    }

    /// yt-dlp post-processing: embedded metadata/thumbnail/chapters/subtitles
    /// and the cookies.txt used for authenticated sites.
    private func mediaCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.media", comment: ""))
            Toggle(NSLocalizedString("settings.media.embedMetadata", comment: ""),
                   isOn: settings.mediaEmbedMetadata)
                .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.media.embedThumbnail", comment: ""),
                   isOn: settings.mediaEmbedThumbnail)
                .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.media.embedChapters", comment: ""),
                   isOn: settings.mediaEmbedChapters)
                .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.media.embedSubtitles", comment: ""),
                   isOn: settings.mediaEmbedSubtitles)
                .toggleStyle(NeoToggleStyle())
            TextField(NSLocalizedString("settings.media.subtitleLangs", comment: ""),
                      text: settings.mediaSubtitleLanguages)
                .neoTextField()
            Text(NSLocalizedString("settings.media.subtitleLangs.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            NeoDivider()
            cookiesFileRow(settings: settings)
            Text(NSLocalizedString("settings.media.cookies.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    /// Netscape cookies.txt picker (yt-dlp `--cookies` for authenticated
    /// sites that the browser extension cannot capture).
    private func cookiesFileRow(settings: Binding<AppSettings>) -> some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("settings.media.cookies", comment: ""))
                .font(.headline)
            Spacer()
            Text(settings.wrappedValue.cookiesFilePath.isEmpty
                 ? NSLocalizedString("settings.media.cookies.none", comment: "")
                 : (settings.wrappedValue.cookiesFilePath as NSString).lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(NSLocalizedString("common.choose", comment: "")) {
                chooseCookiesFile(settings: settings)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            if !settings.wrappedValue.cookiesFilePath.isEmpty {
                Button(NSLocalizedString("common.clear", comment: "")) {
                    settings.wrappedValue.cookiesFilePath = ""
                    store.save()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            }
        }
    }

    private func chooseCookiesFile(settings: Binding<AppSettings>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("settings.media.cookies.prompt", comment: "")
        panel.prompt = NSLocalizedString("common.choose", comment: "")
        if panel.runModal() == .OK, let url = panel.url {
            settings.wrappedValue.cookiesFilePath = url.path
            store.save()
        }
    }

    /// Saves changes to the media post-processing fields (the main handler
    /// chain is already at the type-checker's limit).
    private struct MediaChangeHandlers: ViewModifier {
        @Environment(SettingsStore.self) private var store: SettingsStore

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.mediaEmbedMetadata) { _, _ in store.save() }
                .onChange(of: store.settings.mediaEmbedThumbnail) { _, _ in store.save() }
                .onChange(of: store.settings.mediaEmbedChapters) { _, _ in store.save() }
                .onChange(of: store.settings.mediaEmbedSubtitles) { _, _ in store.save() }
                .onChange(of: store.settings.mediaSubtitleLanguages) { _, _ in store.save() }
                .onChange(of: store.settings.cookiesFilePath) { _, _ in store.save() }
        }
    }

    /// Ordering aids that act on the download pipeline (host profiles,
    /// rename/re-route rules, queues, watch folders). Split out of the
    /// Downloads card so each card stays scannable.
    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.automation", comment: ""))
            HostProfilesSection()
            NeoDivider()
            PackagizerRulesSection()
            NeoDivider()
            queuesSection()
            NeoDivider()
            watchSection()
        }
        .neoCard()
    }

    // MARK: - Backlog #9: after-downloads-finish actions

    /// Renders inside the Basic card (not as a standalone card).
    private func completionSection(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            subHeader(NSLocalizedString("settings.completion.title", comment: ""))
            HStack {
                Text(NSLocalizedString("settings.completion.action", comment: ""))
                    .font(.headline)
                Spacer()
                NeoMenuPicker(
                    selection: settings.completionAction,
                    options: CompletionAction.allCases.map {
                        (value: $0, title: NSLocalizedString($0.localizationKey, comment: ""))
                    },
                    maxWidth: 320
                )
            }
            if settings.wrappedValue.completionAction == .runCommand {
                TextField(
                    NSLocalizedString(
                        "settings.completion.command.placeholder", comment: ""),
                    text: settings.completionCommand
                )
                .neoTextField()
            }
            Text(NSLocalizedString("settings.completion.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Phase 5 named queues

    /// Queue list: rename (non-default), per-queue concurrency stepper,
    /// delete (non-default; its tasks fall back to the Default queue), add.
    private func queuesSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            subHeader(NSLocalizedString("queue.queues", comment: ""))
            ForEach(queueStore.queues) { queue in
                queueRow(queue: queue)
            }
            Text(NSLocalizedString("queue.deleteNote", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(
                    NSLocalizedString("queue.newName", comment: ""),
                    text: $newQueueName,
                    prompt: Text(NSLocalizedString("queue.newName", comment: ""))
                )
                .neoTextField()
                Button(NSLocalizedString("queue.add", comment: "")) {
                    queueStore.add(name: newQueueName, maxConcurrent: 3)
                    newQueueName = ""
                    downloadEngine.kickQueue()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(newQueueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func queueRow(queue: DownloadQueue) -> some View {
        HStack(spacing: 8) {
            if queue.isDefault {
                Text(queue.displayName)
                    .font(.subheadline.weight(.semibold))
            } else {
                TextField(
                    NSLocalizedString("queue.name", comment: ""),
                    text: Binding(
                        get: { queue.name },
                        set: { var updated = queue; updated.name = $0; queueStore.update(updated) }
                    )
                )
                .neoTextField()
            }
            Spacer()
            Text(NSLocalizedString("queue.maxConcurrent", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            NeoStepper(value: Binding(
                get: { queue.maxConcurrent },
                set: {
                    var updated = queue
                    updated.maxConcurrent = $0
                    queueStore.update(updated)
                    downloadEngine.kickQueue()
                }
            ), in: 1...20, step: 1) { v in "\(v)" }
            if !queue.isDefault {
                Button {
                    if queueStore.remove(id: queue.id) {
                        downloadEngine.reassignQueue(from: queue.id)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
                .accessibilityLabel(NSLocalizedString("queue.delete", comment: ""))
            }
        }
    }

    // MARK: - Phase 5 watch folders

    /// Watched folders: drop a .txt file (one link per line) in and new
    /// links are added automatically; duplicates are skipped.
    private func watchSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            subHeader(NSLocalizedString("watch.title", comment: ""))
            if watchFolderStore.folders.isEmpty {
                Text(NSLocalizedString("watch.empty", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(watchFolderStore.folders) { folder in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { folder.isEnabled },
                        set: { watchFolderStore.setEnabled(id: folder.id, enabled: $0) }
                    ))
                    .toggleStyle(NeoToggleStyle())
                    .labelsHidden()
                    Text(folder.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        watchFolderStore.remove(id: folder.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
                    .accessibilityLabel(NSLocalizedString("common.delete", comment: ""))
                }
            }
            Text(NSLocalizedString("watch.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("watch.add", comment: "")) {
                if let url = chooseDirectory(initial: nil) {
                    watchFolderStore.add(path: url.path)
                }
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
        }
    }

    // MARK: - Phase 5 proxy

    /// Proxy card: mode (Off/HTTP/SOCKS5) + host/port/credentials. Applies
    /// to the native download engine and to aria2 torrents.
    /// Renders inside the Downloads card (not as a standalone card).
    private func proxySection(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            subHeader(NSLocalizedString("proxy.title", comment: ""))
            HStack {
                NeoSegmented(selection: settings.proxyMode, titles: [
                    (ProxyMode.none, NSLocalizedString("proxy.mode.off", comment: "")),
                    (ProxyMode.http, NSLocalizedString("proxy.mode.http", comment: "")),
                    (ProxyMode.socks5, NSLocalizedString("proxy.mode.socks5", comment: "")),
                ])
                .frame(maxWidth: 420)
                Spacer()
            }
            if settings.proxyMode.wrappedValue != .none {
                HStack(spacing: 8) {
                    TextField(
                        NSLocalizedString("proxy.host", comment: ""),
                        text: settings.proxyHost,
                        prompt: Text(NSLocalizedString("proxy.host", comment: ""))
                    )
                    .neoTextField()
                    TextField(
                        NSLocalizedString("proxy.port", comment: ""),
                        value: settings.proxyPort,
                        format: .number
                    )
                    .neoTextField()
                    .frame(maxWidth: 110)
                }
                HStack(spacing: 8) {
                    TextField(
                        NSLocalizedString("proxy.username", comment: ""),
                        text: settings.proxyUsername,
                        prompt: Text(NSLocalizedString("proxy.username", comment: ""))
                    )
                    .neoTextField()
                    SecureField(
                        NSLocalizedString("proxy.password", comment: ""),
                        text: settings.proxyPassword,
                        prompt: Text(NSLocalizedString("proxy.password", comment: ""))
                    )
                    .neoTextField()
                }
            }
            Text(NSLocalizedString("proxy.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func torrentsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.torrents", comment: ""))
            HStack {
                Text(NSLocalizedString("settings.torrents.profile", comment: ""))
                    .font(.subheadline)
                Spacer()
                NeoSegmented(selection: settings.torrentPerformanceProfile, titles: [
                    (Aria2PerformanceProfile.balanced, Aria2PerformanceProfile.balanced.localizedName),
                    (Aria2PerformanceProfile.high, Aria2PerformanceProfile.high.localizedName),
                    (Aria2PerformanceProfile.maximum, Aria2PerformanceProfile.maximum.localizedName),
                ])
                .frame(maxWidth: 340)
            }
            Text(NSLocalizedString("settings.torrents.profile.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            NeoDivider()
            Toggle(NSLocalizedString("settings.vpnKillSwitch", comment: ""), isOn: settings.vpnKillSwitchEnabled)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.vpnKillSwitch.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(NSLocalizedString("settings.vpnInterface", comment: ""))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TextField(
                    "utun3",
                    text: settings.vpnInterfaceName,
                    prompt: Text(NSLocalizedString("settings.vpnInterface", comment: "")))
                    .neoTextField()
                    .frame(width: 160)
                    .disabled(!settings.wrappedValue.vpnKillSwitchEnabled)
            }
            NeoDivider()
            Toggle(
                NSLocalizedString("settings.trackers.autoUpdate", comment: ""),
                isOn: settings.autoUpdateTrackers
            )
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.trackers.autoUpdate.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(NSLocalizedString("settings.trackers.syncInterval", comment: ""))
                    .font(.subheadline)
                Spacer()
                NeoStepper(value: settings.trackerSyncHours, in: 1.0...168.0, step: 1.0) { v in
                    "\(Int(v))h"
                }
                .disabled(!settings.wrappedValue.autoUpdateTrackers)
            }
            NeoDivider()
            magnetHandlerRow()
        }
        .neoCard()
    }

    // MARK: - Run As (tray mode)

    /// Standard / tray / hidden dropdown. The mode itself is applied in
    /// GrabbitApp (activation policy + menu bar extra).
    /// Run As: standard app, tray (menu bar) app, or fully hidden.
    /// NeoSegmented matches the theme/language rows above — and keeps the
    /// type-checker happy (a Picker+tags here timed it out in CI).
    private func runAsRow(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            subHeader(NSLocalizedString("settings.runAs", comment: ""))
            HStack {
                NeoSegmented(selection: settings.runMode, titles: [
                    (RunMode.standard, NSLocalizedString("settings.runAs.standard", comment: "")),
                    (RunMode.tray, NSLocalizedString("settings.runAs.tray", comment: "")),
                    (RunMode.hidden, NSLocalizedString("settings.runAs.hidden", comment: "")),
                ])
                .frame(maxWidth: 420)
                Spacer()
            }
            if settings.wrappedValue.runMode == .hidden {
                Text(NSLocalizedString("settings.runAs.hiddenNote", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Startup

    /// Registers/unregisters Grabbit as a login item (macOS 13+ API).
    private func applyOpenAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    /// If the user removed Grabbit from Login Items in System Settings, the
    /// toggle would lie — re-register on appear when the setting says on.
    private func syncOpenAtLogin() {
        if store.settings.openAtLogin {
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - Magnet link handler

    /// Which app macOS opens magnet: links with. Registering the scheme in
    /// Info.plist isn't enough when another app (e.g. Motrix) already owns
    /// it — the user picks the winner here.
    private func magnetHandlerRow() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("settings.magnetHandler", comment: ""))
                    .font(.subheadline.weight(.semibold))
                Text(magnetHandlerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(NSLocalizedString("settings.magnetHandler.setDefault", comment: "")) {
                setGrabbitAsMagnetHandler()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            .disabled(isGrabbitMagnetHandler)
        }
    }

    private var isGrabbitMagnetHandler: Bool {
        magnetAppName == "Grabbit"
    }

    private var magnetHandlerNote: String {
        if isGrabbitMagnetHandler {
            return NSLocalizedString("settings.magnetHandler.current", comment: "")
        }
        let current = magnetAppName.isEmpty
            ? NSLocalizedString("settings.magnetHandler.none", comment: "")
            : magnetAppName
        return String(
            format: NSLocalizedString("settings.magnetHandler.note", comment: ""), current)
    }

    private func refreshMagnetHandler() {
        guard let magnet = URL(string: "magnet:"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: magnet)
        else {
            magnetAppName = ""
            return
        }
        magnetAppName = appURL.deletingPathExtension().lastPathComponent
    }

    private func setGrabbitAsMagnetHandler() {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: "magnet"
        ) { _ in
            Task { @MainActor in self.refreshMagnetHandler() }
        }
        // Optimistic immediate refresh; the completion re-reads anyway.
        refreshMagnetHandler()
    }

    private func seedRatioRow(settings: Binding<AppSettings>) -> some View {
        let ratio = Binding<Double>(
            get: { settings.wrappedValue.defaultSeedRatio },
            set: {
                settings.wrappedValue.defaultSeedRatio = $0
                store.save()
            }
        )
        return HStack {
            Text(NSLocalizedString("settings.seedRatio", comment: ""))
                .font(.subheadline.weight(.semibold))
            Spacer()
            NeoStepper(value: ratio, in: 0...10, step: 0.5) { v in
                v == 0
                    ? NSLocalizedString("settings.unlimited", comment: "")
                    : String(format: "%.1f", v)
            }
        }
    }

    private func seedTimeRow(settings: Binding<AppSettings>) -> some View {
        let minutes = Binding<Int>(
            get: { settings.wrappedValue.defaultSeedTimeMinutes },
            set: {
                settings.wrappedValue.defaultSeedTimeMinutes = $0
                store.save()
            }
        )
        return HStack {
            Text(NSLocalizedString("settings.seedTime", comment: ""))
                .font(.subheadline.weight(.semibold))
            Spacer()
            NeoStepper(value: minutes, in: 0...10080, step: 30) { v in
                v == 0
                    ? NSLocalizedString("settings.unlimited", comment: "")
                    : "\(v)"
            }
        }
    }

    // MARK: - Rows

    private func folderRow(for category: DownloadCategory, settings: Binding<AppSettings>) -> some View {
        HStack {
            Text(category.settingsFolderName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(currentFolderPath(for: category, settings: settings))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(NSLocalizedString("add.destination.choose", comment: "")) {
                if let url = chooseDirectory(initial: URL(fileURLWithPath: currentFolderPath(for: category, settings: settings))) {
                    settings.wrappedValue.folders[category] = url.path
                    store.save()
                }
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
        }
    }

    private func currentFolderPath(for category: DownloadCategory, settings: Binding<AppSettings>) -> String {
        settings.wrappedValue.folders[category] ?? store.folderURL(for: category).path
    }

    private func speedLimitRow(settings: Binding<AppSettings>) -> some View {
        let mb = Binding<Int>(
            get: { Int(settings.wrappedValue.speedLimitBytesPerSec / 1_048_576) },
            set: {
                settings.wrappedValue.speedLimitBytesPerSec = Int64($0) * 1_048_576
                store.save()
            }
        )
        return HStack {
            Text(NSLocalizedString("settings.speedLimit", comment: ""))
                .font(.subheadline.weight(.semibold))
            Spacer()
            NeoStepper(value: mb, in: 0...2000, step: 1) { v in
                v == 0
                    ? NSLocalizedString("settings.speedLimit.unlimited", comment: "")
                    : "\(v) MB/s"
            }
        }
    }

    // MARK: - Updates

    // Update controls (auto-check toggle + Check Now) live in the About tab.
}
