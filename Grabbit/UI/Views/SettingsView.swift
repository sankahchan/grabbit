import SwiftUI
import AppKit
import ServiceManagement

/// Settings tab: neo-styled cards for basic, downloads, torrents, and
/// updates. Everything binds to `SettingsStore` and persists via `save()`
/// on change.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(DownloadEngine.self) private var downloadEngine: DownloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme
    /// Display name of the app macOS currently routes magnet: links to
    /// (e.g. "Motrix"); empty when none is set.
    @State private var magnetAppName = ""

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                // One wide Basic card (Motrix-style): appearance, language,
                // startup, seeding, and task management. The wide
                // downloads/torrents cards get full rows below. Content
                // breathes with the window (capped at 1000 so rows don't
                // stretch across ultra-wide displays).
                basicCard(settings: settings)
                downloadsCard(settings: settings)
                torrentsCard(settings: settings)
                // The updates card only exists when Sparkle can actually
                // run (signed Release build + real SUPublicEDKey).
                if GrabbitApp.isUpdaterConfigured {
                    updatesCard(settings: settings)
                }
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("settings.title", comment: ""))
        .onAppear {
            refreshMagnetHandler()
            syncOpenAtLogin()
        }
        .onChange(of: store.settings.theme) { _, _ in store.save() }
        .onChange(of: store.settings.language, handleLanguageChange)
        .onChange(of: store.settings.speedLimitBytesPerSec) { _, _ in store.save() }
        .onChange(of: store.settings.clipboardMonitorEnabled) { _, _ in store.save() }
        .onChange(of: store.settings.autoResumeOnLaunch) { _, _ in store.save() }
        .onChange(of: store.settings.autoClearFinished) { _, _ in store.save() }
        .onChange(of: store.settings.autoUpdateTrackers) { _, _ in store.save() }
        .onChange(of: store.settings.autoUpdateEnabled) { _, _ in store.save() }
        .onChange(of: store.settings.notificationsEnabled) { _, _ in store.save() }
        .onChange(of: store.settings.defaultConnections) { _, _ in store.save() }
        .onChange(of: store.settings.vpnKillSwitchEnabled) { _, _ in store.save() }
        .onChange(of: store.settings.vpnInterfaceName) { _, _ in store.save() }
        .onChange(of: store.settings.defaultSeedRatio) { _, _ in store.save() }
        .onChange(of: store.settings.defaultSeedTimeMinutes) { _, _ in store.save() }
        .onChange(of: store.settings.openAtLogin) { _, new in
            store.save()
            applyOpenAtLogin(new)
        }
        .onChange(of: store.settings.keepWindowFrame) { _, _ in store.save() }
        .onChange(of: store.settings.maxActiveTasks) { _, _ in
            store.save()
            downloadEngine.kickQueue()
            Task { await torrentEngine.applyMaxActiveTasks() }
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
                NeoSegmented(selection: settings.language, titles: [
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
            Divider()
            subHeader(NSLocalizedString("settings.section.startup", comment: ""))
            Toggle(NSLocalizedString("settings.startup.openAtLogin", comment: ""), isOn: settings.openAtLogin)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.startup.keepWindowFrame", comment: ""), isOn: settings.keepWindowFrame)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.startup.autoResumeTasks", comment: ""), isOn: settings.autoResumeOnLaunch)
            .toggleStyle(NeoToggleStyle())
            Divider()
            subHeader(NSLocalizedString("settings.section.seeding", comment: ""))
            seedRatioRow(settings: settings)
            seedTimeRow(settings: settings)
            Divider()
            subHeader(NSLocalizedString("settings.section.taskManagement", comment: ""))
            maxActiveTasksRow(settings: settings)
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
            Divider()
            speedLimitRow(settings: settings)
            Toggle(NSLocalizedString("settings.clipboard", comment: ""), isOn: settings.clipboardMonitorEnabled)
            .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("settings.autoClear", comment: ""), isOn: settings.autoClearFinished)
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.autoClear.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    private func torrentsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.torrents", comment: ""))
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
            Divider()
            Toggle(
                NSLocalizedString("settings.trackers.autoUpdate", comment: ""),
                isOn: settings.autoUpdateTrackers
            )
            .toggleStyle(NeoToggleStyle())
            Text(NSLocalizedString("settings.trackers.autoUpdate.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            magnetHandlerRow()
        }
        .neoCard()
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

    private func updatesCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.updates", comment: ""))
            Toggle(NSLocalizedString("settings.autoUpdate", comment: ""), isOn: settings.autoUpdateEnabled)
            .toggleStyle(NeoToggleStyle())
            Button(NSLocalizedString("settings.checkNow", comment: "")) {
                checkForUpdates()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
        }
        .neoCard()
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

    /// Sparkle hookup point: call
    /// `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil).checkForUpdates(nil)`
    /// here once the Sparkle package is integrated.
    private func checkForUpdates() {
    }
}
