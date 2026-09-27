import SwiftUI

/// Settings tab: neo-styled cards for appearance, language, downloads,
/// torrents, updates, and general. Everything binds to `SettingsStore` and persists
/// via `save()` on change.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                // Small cards pair up side-by-side; the wide cards
                // (downloads/torrents) get the full row. Content is capped
                // so the cards don't stretch across ultra-wide windows.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16),
                              GridItem(.flexible(), spacing: 16)],
                    spacing: 16
                ) {
                    appearanceCard(settings: settings)
                    languageCard(settings: settings)
                }
                downloadsCard(settings: settings)
                torrentsCard(settings: settings)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16),
                              GridItem(.flexible(), spacing: 16)],
                    spacing: 16
                ) {
                    // The updates card only exists when Sparkle can actually
                    // run (signed Release build + real SUPublicEDKey).
                    if GrabbitApp.isUpdaterConfigured {
                        updatesCard(settings: settings)
                    }
                    generalCard(settings: settings)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(String(localized: "settings.title"))
        .onChange(of: store.settings.theme) { _, _ in store.save() }
        .onChange(of: store.settings.language, handleLanguageChange)
        .onChange(of: store.settings.speedLimitBytesPerSec) { _, _ in store.save() }
        .onChange(of: store.settings.clipboardMonitorEnabled) { _, _ in store.save() }
        .onChange(of: store.settings.autoResumeOnLaunch) { _, _ in store.save() }
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
        }
        .neoCard()
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
