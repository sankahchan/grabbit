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
    /// Torznab indexer add/remove flow.
    @State private var showingIndexerSheet = false
    @State private var indexerToRemove: TorznabIndexer?
    @State private var detectingIndexers = false
    @State private var discoveryNote: String?
    /// Browser-extension (Grabber) setup — moved in from its old tab.
    @State private var extensionConnected = false
    @State private var updateState: ExtensionUpdateState = .idle

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
                notchCard(settings: settings)
                downloadsCard(settings: settings)
                mediaCard(settings: settings)
                grabberSection(settings: settings)
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
            refreshConnectionStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in refreshConnectionStatus() }
        .modifier(SettingsChangeHandlers(
            onLanguageChange: handleLanguageChange,
            onOpenAtLogin: applyOpenAtLogin))
        .modifier(ProxyChangeHandlers())
        .modifier(MediaChangeHandlers())
        .modifier(NotchChangeHandlers())
    }

    // MARK: - Notch & Pill change handlers

    /// Saves and re-applies every notch/pill setting immediately.
    private struct NotchChangeHandlers: ViewModifier {
        @Environment(SettingsStore.self) private var store: SettingsStore
        @Environment(NotchController.self) private var notchController: NotchController

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.notchShape) { _, _ in changed() }
                .onChange(of: store.settings.notchClosedScale) { _, _ in changed() }
                .onChange(of: store.settings.notchHeightAdjust) { _, _ in changed() }
                .onChange(of: store.settings.notchGlassEnabled) { _, _ in changed() }
                .onChange(of: store.settings.notchTranslucency) { _, _ in changed() }
                .onChange(of: store.settings.notchAuraEnabled) { _, _ in changed() }
                .onChange(of: store.settings.notchCustomFill) { _, _ in changed() }
                .onChange(of: store.settings.notchFillColor) { _, _ in changed() }
                .onChange(of: store.settings.notchAnimationStyle) { _, _ in changed() }
                .onChange(of: store.settings.notchAnimationSpeed) { _, _ in changed() }
                .onChange(of: store.settings.notchExpandOnHover) { _, _ in changed() }
                .onChange(of: store.settings.notchHoverDelay) { _, _ in changed() }
                .onChange(of: store.settings.notchCollapseDelay) { _, _ in changed() }
                .onChange(of: store.settings.notchIdleTimeout) { _, _ in changed() }
                .onChange(of: store.settings.notchShowProgress) { _, _ in changed() }
                .onChange(of: store.settings.notchShowAdded) { _, _ in changed() }
                .onChange(of: store.settings.notchShowFinished) { _, _ in changed() }
                .onChange(of: store.settings.notchTransientSeconds) { _, _ in changed() }
                .onChange(of: store.settings.notchHideFromCapture) { _, _ in changed() }
        }

        private func changed() {
            store.save()
            notchController.applySettings()
        }
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
                .onChange(of: store.settings.themeStyle) { _, _ in store.save() }
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
        @Environment(NotchController.self) private var notchController: NotchController
        var onOpenAtLogin: (Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: store.settings.autoClearFailed) { _, _ in store.save() }
                .onChange(of: store.settings.autoStartIndexers) { _, _ in store.save() }
                .onChange(of: store.settings.notchModeEnabled) { _, newValue in
                    store.save()
                    notchController.setEnabled(newValue)
                }
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
            .font(NeoFont.f(.headline, .heavy))
            .textCase(.uppercase)
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(NeoFont.f(.subheadline, .heavy))
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
            subHeader(NSLocalizedString("settings.section.themeStyle", comment: ""))
            HStack {
                // Brand names stay Latin; only "Classic" is localized.
                Text(NSLocalizedString("settings.themeStyle", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Spacer()
                // Live accent swatch: the skin reads at a glance without
                // opening the menu.
                Circle()
                    .fill(ThemeCatalog.tokens(for: settings.wrappedValue.themeStyle).yellow)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Neo.ink(scheme).opacity(0.18), lineWidth: 1))
                NeoMenuPicker(
                    selection: settings.themeStyle,
                    options: ThemeStyle.allCases.map { (value: $0, title: $0.displayName) },
                    maxWidth: 220)
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
                .font(NeoFont.f(.caption))
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

    // MARK: - Notch & Pill card

    @ViewBuilder
    private func notchCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            subHeader(NSLocalizedString("settings.notch.header", comment: ""))
            notchShapeSection(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.notch.material", comment: ""))
            notchMaterialSection(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.notch.motion", comment: ""))
            notchMotionSection(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.notch.popups", comment: ""))
            notchPopupsSection(settings: settings)
            NeoDivider()
            subHeader(NSLocalizedString("settings.notch.visibility", comment: ""))
            notchVisibilitySection(settings: settings)
        }
        .neoCard()
    }

    @ViewBuilder
    private func notchShapeSection(settings: Binding<AppSettings>) -> some View {
        HStack {
            Text(NSLocalizedString("settings.notchMode", comment: ""))
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            Toggle("", isOn: settings.notchModeEnabled)
                .toggleStyle(NeoToggleStyle())
                .labelsHidden()
        }
        Text(NSLocalizedString("settings.notchMode.note", comment: ""))
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)
        HStack {
            Text(NSLocalizedString("settings.notch.shape", comment: ""))
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            NeoSegmented(selection: settings.notchShape, titles: [
                (.pill, NSLocalizedString("settings.notch.shape.pill", comment: "")),
                (.notch, NSLocalizedString("settings.notch.shape.notch", comment: "")),
            ])
            .frame(maxWidth: 220)
        }
        Text(NSLocalizedString("settings.notch.shape.note", comment: ""))
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)
        notchStepperRow(
            label: NSLocalizedString("settings.notch.closedSize", comment: ""),
            value: Binding(
                get: { settings.wrappedValue.notchClosedScale },
                set: { settings.wrappedValue.notchClosedScale = $0 }),
            in: 0.7...1.5, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
        HStack {
            Text(NSLocalizedString("settings.notch.heightAdjust", comment: ""))
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            NeoStepper(
                value: settings.notchHeightAdjust, in: -20...20, step: 2) {
                "\($0)pt"
            }
        }
    }

    @ViewBuilder
    private func notchMaterialSection(settings: Binding<AppSettings>) -> some View {
        notchToggleRow(
            NSLocalizedString("settings.notch.glass", comment: ""),
            isOn: settings.notchGlassEnabled)
        notchStepperRow(
            label: NSLocalizedString("settings.notch.translucency", comment: ""),
            value: Binding(
                get: { settings.wrappedValue.notchTranslucency * 100 },
                set: { settings.wrappedValue.notchTranslucency = $0 / 100 }),
            in: 80...100, step: 5) { "\(Int($0))%" }
        notchToggleRow(
            NSLocalizedString("settings.notch.aura", comment: ""),
            isOn: settings.notchAuraEnabled)
        notchToggleRow(
            NSLocalizedString("settings.notch.customFill", comment: ""),
            isOn: settings.notchCustomFill)
        if settings.wrappedValue.notchCustomFill {
            HStack {
                Text(NSLocalizedString("settings.notch.fillColor", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Spacer()
                ColorPicker(
                    "",
                    selection: Binding(
                        get: {
                            Color(hexString: settings.wrappedValue.notchFillColor)
                                ?? Color(hex: 0x101318)
                        },
                        set: { settings.wrappedValue.notchFillColor = $0.hexString }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func notchMotionSection(settings: Binding<AppSettings>) -> some View {
        HStack {
            Text(NSLocalizedString("settings.notch.animStyle", comment: ""))
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            NeoSegmented(selection: settings.notchAnimationStyle, titles: [
                (.calm, NSLocalizedString("settings.notch.animStyle.calm", comment: "")),
                (.snappy, NSLocalizedString("settings.notch.animStyle.snappy", comment: "")),
                (.bouncy, NSLocalizedString("settings.notch.animStyle.bouncy", comment: "")),
            ])
            .frame(maxWidth: 300)
        }
        notchStepperRow(
            label: NSLocalizedString("settings.notch.animSpeed", comment: ""),
            value: settings.notchAnimationSpeed,
            in: 0.5...2.0, step: 0.1) { String(format: "%.1f×", $0) }
        notchToggleRow(
            NSLocalizedString("settings.notch.expandHover", comment: ""),
            isOn: settings.notchExpandOnHover)
        notchStepperRow(
            label: NSLocalizedString("settings.notch.hoverDelay", comment: ""),
            value: settings.notchHoverDelay,
            in: 0...1, step: 0.05) { String(format: "%.2fs", $0) }
        notchStepperRow(
            label: NSLocalizedString("settings.notch.collapseDelay", comment: ""),
            value: settings.notchCollapseDelay,
            in: 0...2, step: 0.1) { String(format: "%.1fs", $0) }
        notchStepperRow(
            label: NSLocalizedString("settings.notch.idleTimeout", comment: ""),
            value: settings.notchIdleTimeout,
            in: 0...120, step: 10) {
                $0 == 0
                    ? NSLocalizedString("settings.notch.idleTimeout.never", comment: "")
                    : "\(Int($0))s"
            }
    }

    @ViewBuilder
    private func notchPopupsSection(settings: Binding<AppSettings>) -> some View {
        notchToggleRow(
            NSLocalizedString("settings.notch.showProgress", comment: ""),
            isOn: settings.notchShowProgress)
        notchToggleRow(
            NSLocalizedString("settings.notch.showAdded", comment: ""),
            isOn: settings.notchShowAdded)
        notchToggleRow(
            NSLocalizedString("settings.notch.showFinished", comment: ""),
            isOn: settings.notchShowFinished)
        notchStepperRow(
            label: NSLocalizedString("settings.notch.transientSeconds", comment: ""),
            value: settings.notchTransientSeconds,
            in: 1...10, step: 0.5) { String(format: "%.1fs", $0) }
        notchToggleRow(
            NSLocalizedString("settings.notchSounds", comment: ""),
            isOn: settings.notchSoundsEnabled)
    }

    @ViewBuilder
    private func notchVisibilitySection(settings: Binding<AppSettings>) -> some View {
        notchToggleRow(
            NSLocalizedString("settings.notchHideWhenOtherApp", comment: ""),
            isOn: settings.notchHideWhenOtherApp)
        notchToggleRow(
            NSLocalizedString("settings.notch.hideCapture", comment: ""),
            isOn: settings.notchHideFromCapture)
    }

    private func notchToggleRow(
        _ label: String, isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Text(label)
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(NeoToggleStyle())
                .labelsHidden()
        }
    }

    private func notchStepperRow(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack {
            Text(label)
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            NeoStepper(value: value, in: range, step: step, label: format)
        }
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
                .font(NeoFont.f(.subheadline, .semibold))
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
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            NeoDivider()
            subHeader(NSLocalizedString("settings.section.archives", comment: ""))
            Toggle(NSLocalizedString("settings.archives.autoExtract", comment: ""), isOn: settings.autoExtractArchives)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.archives.deleteAfterExtract", comment: ""), isOn: settings.deleteArchiveAfterExtract)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.archives.note", comment: ""))
                .font(NeoFont.f(.caption))
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
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            NeoDivider()
            cookiesFileRow(settings: settings)
            Text(NSLocalizedString("settings.media.cookies.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    /// Netscape cookies.txt picker (yt-dlp `--cookies` for authenticated
    /// sites that the browser extension cannot capture).
    private func cookiesFileRow(settings: Binding<AppSettings>) -> some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("settings.media.cookies", comment: ""))
                .font(NeoFont.f(.headline))
            Spacer()
            Text(settings.wrappedValue.cookiesFilePath.isEmpty
                 ? NSLocalizedString("settings.media.cookies.none", comment: "")
                 : (settings.wrappedValue.cookiesFilePath as NSString).lastPathComponent)
                .font(NeoFont.f(.subheadline))
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
                    .font(NeoFont.f(.headline))
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
                .font(NeoFont.f(.caption))
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
                .font(NeoFont.f(.caption))
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
                    .font(NeoFont.f(.subheadline, .semibold))
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
                .font(NeoFont.f(.caption))
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
                    AppIcon("trash", size: 14)
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
                    .font(NeoFont.f(.caption))
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
                        .font(NeoFont.f(.caption))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        watchFolderStore.remove(id: folder.id)
                    } label: {
                        AppIcon("trash", size: 14)
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
                    .accessibilityLabel(NSLocalizedString("common.delete", comment: ""))
                }
            }
            Text(NSLocalizedString("watch.note", comment: ""))
                .font(NeoFont.f(.caption))
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
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func torrentsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.torrents", comment: ""))
            HStack {
                Text(NSLocalizedString("settings.torrents.profile", comment: ""))
                    .font(NeoFont.f(.subheadline))
                Spacer()
                NeoSegmented(selection: settings.torrentPerformanceProfile, titles: [
                    (Aria2PerformanceProfile.balanced, Aria2PerformanceProfile.balanced.localizedName),
                    (Aria2PerformanceProfile.high, Aria2PerformanceProfile.high.localizedName),
                    (Aria2PerformanceProfile.maximum, Aria2PerformanceProfile.maximum.localizedName),
                ])
                .frame(maxWidth: 340)
            }
            Text(NSLocalizedString("settings.torrents.profile.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            NeoDivider()
            Toggle(NSLocalizedString("settings.vpnKillSwitch", comment: ""), isOn: settings.vpnKillSwitchEnabled)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.vpnKillSwitch.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            HStack {
                Text(NSLocalizedString("settings.vpnInterface", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
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
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            HStack {
                Text(NSLocalizedString("settings.trackers.syncInterval", comment: ""))
                    .font(NeoFont.f(.subheadline))
                Spacer()
                NeoStepper(value: settings.trackerSyncHours, in: 1.0...168.0, step: 1.0) { v in
                    "\(Int(v))h"
                }
                .disabled(!settings.wrappedValue.autoUpdateTrackers)
            }
            NeoDivider()
            indexersSection(settings: settings)
            NeoDivider()
            magnetHandlerRow()
        }
        .neoCard()
    }

    // MARK: - Browser extension (Grabber)

    enum ExtensionUpdateState: Equatable {
        case idle
        case working
        case updated
        case saved(path: String)
        case failed(String)
    }

    /// The browser can reach Grabbit iff the native-messaging manifest is
    /// installed for a supported browser.
    private static func hostManifestInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/Mozilla/NativeMessagingHosts",
        ]
        return dirs.contains { dir in
            FileManager.default.fileExists(atPath:
                home.appendingPathComponent(
                    dir + "/com.sankahchan.grabbit.json").path)
        }
    }

    private func refreshConnectionStatus() {
        extensionConnected = Self.hostManifestInstalled()
    }

    private func runExtensionUpdate() {
        updateState = .working
        Task { @MainActor in
            do {
                let zip = try await ExtensionUpdater.downloadLatest()
                defer { try? FileManager.default.removeItem(at: zip) }
                let copies = ExtensionUpdater.findUnpackedCopies()
                if copies.isEmpty {
                    let base = try ExtensionUpdater.saveForManualInstall(zip: zip)
                    updateState = .saved(path: base.path)
                } else {
                    for copy in copies {
                        try ExtensionUpdater.install(zip: zip, into: copy.folder)
                    }
                    updateState = .updated
                }
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                NeoSpinner(size: 16)
                Text(NSLocalizedString("grabber.extension.working", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
            }
        case .updated:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("grabber.extension.updated", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Button(NSLocalizedString("grabber.extension.openExtensions", comment: "")) {
                    ExtensionUpdater.openExtensionsPage()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            }
        case .saved(let path):
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("grabber.extension.saved", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Button(NSLocalizedString("grabber.extension.openFolder", comment: "")) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)])
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            }
        case .failed(let message):
            Text("\(NSLocalizedString("grabber.extension.failed", comment: "")) \(message)")
                .font(NeoFont.f(.subheadline, .semibold))
                .foregroundStyle(Neo.red)
        }
    }

    private func grabberSection(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(NSLocalizedString("settings.section.grabber", comment: ""))
            HStack(spacing: 8) {
                Circle()
                    .fill(extensionConnected ? Neo.green : Neo.red)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: (extensionConnected ? Neo.green : Neo.red)
                            .opacity(0.8),
                        radius: 3)
                Text(extensionConnected
                     ? NSLocalizedString("grabber.status.connected", comment: "")
                     : NSLocalizedString("grabber.status.disconnected", comment: ""))
                    .font(NeoFont.f(.caption, .semibold))
                Spacer()
                Button(extensionConnected
                       ? NSLocalizedString("grabber.updateExtension", comment: "")
                       : NSLocalizedString("grabber.getExtension", comment: "")) {
                    runExtensionUpdate()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                .disabled(updateState == .working)
            }
            updateStatusView
            if !extensionConnected {
                Text(NSLocalizedString("grabber.hint", comment: ""))
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.pink)
    }

    // MARK: - Torznab indexers

    /// Scans the default Jackett/Prowlarr config locations, probes the
    /// servers, and folds every discovered indexer into settings (keys to
    /// the Keychain). Existing entries are left alone.
    private func detectIndexers() {
        detectingIndexers = true
        discoveryNote = nil
        Task { @MainActor in
            let outcome = await TorznabDiscovery.discover()
            let found = outcome.found
            var added = 0
            for item in found {
                let exists = store.settings.torznabIndexers.contains {
                    $0.urlString == item.urlString && $0.name == item.name
                }
                guard !exists else { continue }
                let indexer = TorznabIndexer(
                    name: item.name, urlString: item.urlString)
                store.settings.torznabIndexers.append(indexer)
                if !item.apiKey.isEmpty {
                    TorznabVault.saveKey(item.apiKey, for: indexer.id)
                }
                added += 1
            }
            store.save()
            if found.isEmpty, let server = outcome.emptyServers.first {
                discoveryNote = String(
                    format: NSLocalizedString(
                        "settings.indexers.detect.emptyServer", comment: ""),
                    server)
            } else if found.isEmpty {
                discoveryNote = NSLocalizedString(
                    "settings.indexers.detect.none", comment: "")
            } else if added == 0 {
                discoveryNote = NSLocalizedString(
                    "settings.indexers.detect.already", comment: "")
            } else {
                discoveryNote = String(
                    format: NSLocalizedString(
                        "settings.indexers.detect.added", comment: ""),
                    added)
            }
            detectingIndexers = false
        }
    }

    private func indexersSection(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                subHeader(NSLocalizedString("settings.indexers.title", comment: ""))
                Spacer()
                Button {
                    detectIndexers()
                } label: {
                    if detectingIndexers {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(NSLocalizedString(
                            "settings.indexers.detect", comment: ""))
                    }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
                .disabled(detectingIndexers)
                Button(NSLocalizedString("settings.indexers.add", comment: "")) {
                    showingIndexerSheet = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            }
            Text(NSLocalizedString("settings.indexers.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            Toggle(
                NSLocalizedString("settings.indexers.autoStart", comment: ""),
                isOn: settings.autoStartIndexers
            )
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString(
                "settings.indexers.autoStart.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            if let discoveryNote {
                Text(discoveryNote)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.green)
            }
            let indexers = settings.wrappedValue.torznabIndexers
            if indexers.isEmpty {
                Text(NSLocalizedString("settings.indexers.empty", comment: ""))
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(indexers) { indexer in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(indexer.name)
                                .font(NeoFont.f(.subheadline, .semibold))
                            Text(indexer.urlString)
                                .font(NeoFont.f(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            indexerToRemove = indexer
                        } label: {
                            AppIcon("trash", size: 13)
                        }
                        .buttonStyle(NeoIconButtonStyle(bg: Neo.red))
                        .help(NSLocalizedString("common.delete", comment: ""))
                    }
                    .padding(8)
                    .background(
                        Neo.paper(scheme),
                        in: RoundedRectangle(
                            cornerRadius: 8, style: .continuous))
                }
            }
        }
        .sheet(isPresented: $showingIndexerSheet) {
            TorznabIndexerSheet()
        }
        .alert(
            NSLocalizedString("settings.indexers.remove.title", comment: ""),
            isPresented: Binding(
                get: { indexerToRemove != nil },
                set: { if !$0 { indexerToRemove = nil } })
        ) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                if let indexer = indexerToRemove {
                    store.settings.torznabIndexers.removeAll {
                        $0.id == indexer.id
                    }
                    TorznabVault.deleteKey(for: indexer.id)
                    store.save()
                }
                indexerToRemove = nil
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                indexerToRemove = nil
            }
        }
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
                    .font(NeoFont.f(.caption))
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
                    .font(NeoFont.f(.subheadline, .semibold))
                Text(magnetHandlerNote)
                    .font(NeoFont.f(.caption))
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
                .font(NeoFont.f(.subheadline, .semibold))
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
                .font(NeoFont.f(.subheadline, .semibold))
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
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            Text(currentFolderPath(for: category, settings: settings))
                .font(NeoFont.f(.caption))
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
                .font(NeoFont.f(.subheadline, .semibold))
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
