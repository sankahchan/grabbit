import SwiftUI
import AppKit

/// Settings tab: neo-styled cards for appearance, language, downloads,
/// torrents, updates, and general. Everything binds to `SettingsStore` and persists
/// via `save()` on change.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(\.colorScheme) private var scheme
    /// Display name of the app macOS currently routes magnet: links to
    /// (e.g. "Motrix"); empty when none is set.
    @State private var magnetAppName = ""

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                // Appearance + Language always share one row; the wide
                // cards (downloads/torrents) get the full row below.
                // Content breathes with the window (capped at 1000 so rows
                // don't stretch across ultra-wide displays).
                HStack(alignment: .top, spacing: 16) {
                    appearanceCard(settings: settings)
                        .frame(maxWidth: .infinity, alignment: .top)
                    languageCard(settings: settings)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                downloadsCard(settings: settings)
                torrentsCard(settings: settings)
                // The updates card only exists when Sparkle can actually
                // run (signed Release build + real SUPublicEDKey).
                if GrabbitApp.isUpdaterConfigured {
                    updatesCard(settings: settings)
                }
                // General always comes last.
                generalCard(settings: settings)
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(String(localized: "settings.title"))
        .onAppear { refreshMagnetHandler() }
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
    }

    // MARK: - Language

    /// Applies the language instantly (no restart): the main bundle is
    /// re-pointed at the chosen language's `.lproj`, and this view
    /// re-renders on the setting change; other tabs pick it up when
    /// navigated to.
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

    private func appearanceCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.appearance"))
            Picker(String(localized: "settings.theme"), selection: settings.theme) {
                Text(String(localized: "settings.theme.system")).tag(ThemeMode.system)
                Text(String(localized: "settings.theme.light")).tag(ThemeMode.light)
                Text(String(localized: "settings.theme.dark")).tag(ThemeMode.dark)
            }
            .pickerStyle(.segmented)
        }
        .neoCard()
    }

    private func languageCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.language"))
            // Autonyms are shown in their own language by convention.
            Picker(String(localized: "settings.section.language"), selection: settings.language) {
                Text(String(localized: "settings.language.system")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.en)
                Text("မြန်မာ").tag(AppLanguage.my)
            }
            .pickerStyle(.segmented)
            Text(String(localized: "settings.language.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    private func downloadsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.downloads"))
            ForEach(DownloadCategory.allCases, id: \.self) { category in
                folderRow(for: category, settings: settings)
            }
            Divider()
            speedLimitRow(settings: settings)
            Toggle(String(localized: "settings.clipboard"), isOn: settings.clipboardMonitorEnabled)
            Toggle(String(localized: "settings.autoResume"), isOn: settings.autoResumeOnLaunch)
            Toggle(String(localized: "settings.autoClear"), isOn: settings.autoClearFinished)
            Text(String(localized: "settings.autoClear.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    private func torrentsCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.torrents"))
            Toggle(String(localized: "settings.vpnKillSwitch"), isOn: settings.vpnKillSwitchEnabled)
            Text(String(localized: "settings.vpnKillSwitch.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(String(localized: "settings.vpnInterface"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TextField(
                    "utun3",
                    text: settings.vpnInterfaceName,
                    prompt: Text(String(localized: "settings.vpnInterface")))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .disabled(!settings.wrappedValue.vpnKillSwitchEnabled)
            }
            Divider()
            seedRatioRow(settings: settings)
            seedTimeRow(settings: settings)
            Divider()
            Toggle(
                String(localized: "settings.trackers.autoUpdate"),
                isOn: settings.autoUpdateTrackers
            )
            Text(String(localized: "settings.trackers.autoUpdate.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            magnetHandlerRow()
        }
        .neoCard()
    }

    // MARK: - Magnet link handler

    /// Which app macOS opens magnet: links with. Registering the scheme in
    /// Info.plist isn't enough when another app (e.g. Motrix) already owns
    /// it — the user picks the winner here.
    private func magnetHandlerRow() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.magnetHandler"))
                    .font(.subheadline.weight(.semibold))
                Text(magnetHandlerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "settings.magnetHandler.setDefault")) {
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
            return String(localized: "settings.magnetHandler.current")
        }
        let current = magnetAppName.isEmpty
            ? String(localized: "settings.magnetHandler.none")
            : magnetAppName
        return String(
            format: String(localized: "settings.magnetHandler.note"), current)
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
            Text(String(localized: "settings.seedRatio"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Stepper(value: ratio, in: 0...10, step: 0.5) {
                Text(ratio.wrappedValue == 0
                     ? String(localized: "settings.unlimited")
                     : String(format: "%.1f", ratio.wrappedValue))
                    .font(.subheadline)
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
            Text(String(localized: "settings.seedTime"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Stepper(value: minutes, in: 0...10080, step: 30) {
                Text(minutes.wrappedValue == 0
                     ? String(localized: "settings.unlimited")
                     : "\(minutes.wrappedValue)")
                    .font(.subheadline)
            }
        }
    }

    private func updatesCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.updates"))
            Toggle(String(localized: "settings.autoUpdate"), isOn: settings.autoUpdateEnabled)
            Button(String(localized: "settings.checkNow")) {
                checkForUpdates()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
        }
        .neoCard()
    }

    private func generalCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "settings.section.general"))
            Toggle(String(localized: "settings.notifications"), isOn: settings.notificationsEnabled)
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
            Button(String(localized: "add.destination.choose")) {
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
            Text(String(localized: "settings.speedLimit"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Stepper(value: mb, in: 0...2000) {
                Text(mb.wrappedValue == 0
                     ? String(localized: "settings.speedLimit.unlimited")
                     : "\(mb.wrappedValue) MB/s")
                    .font(.subheadline)
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
