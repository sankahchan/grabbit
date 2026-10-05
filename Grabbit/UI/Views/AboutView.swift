import SwiftUI
import AppKit

/// About tab: app identity + version, Sparkle update controls, and project
/// links. Update controls live here (not in Settings) so "what version am I
/// running / how do I update" is one glance.
struct AboutView: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(\.colorScheme) private var scheme
    /// Shown under the "Check Now" button when the updater is unavailable
    /// (dev builds / unsigned Release builds).
    @State private var updaterNote: String?

    private static let licensesURL = URL(string: "https://github.com/sankahchan/grabbit/blob/main/THIRD-PARTY-LICENSES.md")!
    private static let githubURL = URL(string: "https://github.com/sankahchan/grabbit")!
    private static let issuesURL = URL(string: "https://github.com/sankahchan/grabbit/issues")!
    private static let releasesURL = URL(string: "https://github.com/sankahchan/grabbit/releases")!

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                NeoPageHeader(
                    sticker: NSLocalizedString("page.about.sticker", comment: ""),
                    title: NSLocalizedString("nav.about", comment: ""),
                    accent: Neo.yellow)
                identityCard
                updatesCard(settings: settings)
                linksCard
                creditsCard
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("nav.about", comment: ""))
    }

    // MARK: - Identity

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = short.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let buildNumber = build.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return String(
            format: NSLocalizedString("about.versionFormat", comment: ""),
            version, buildNumber)
    }

    private var identityCard: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Grabbit")
                .font(NeoFont.f(.largeTitle, .heavy))
            Text(versionText)
                .font(NeoFont.f(.subheadline, .semibold))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("about.tagline", comment: ""))
                .font(NeoFont.f(.subheadline))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .neoCard(accent: Neo.yellow)
    }

    // MARK: - Updates

    private func updatesCard(settings: Binding<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("settings.section.updates", comment: ""))
            Toggle(NSLocalizedString("settings.autoUpdate", comment: ""), isOn: settings.autoUpdateEnabled)
                .toggleStyle(NeoToggleStyle())
                .onChange(of: settings.wrappedValue.autoUpdateEnabled) { _, newValue in
                    store.save()
                    UpdaterBridge.applyAutomaticChecks(newValue)
                }
            HStack(spacing: 10) {
                Button(NSLocalizedString("settings.checkNow", comment: "")) {
                    checkForUpdates()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                if let updaterNote {
                    Text(updaterNote)
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Text(NSLocalizedString("about.updates.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.green)
    }

    /// Sparkle hookup: the controller is created by `GrabbitApp` (signed
    /// Release builds with a real SUPublicEDKey) and published through
    /// `UpdaterBridge`.
    private func checkForUpdates() {
        guard UpdaterBridge.isAvailable else {
            updaterNote = NSLocalizedString("settings.updates.unavailable", comment: "")
            return
        }
        updaterNote = nil
        UpdaterBridge.checkForUpdates()
    }

    // MARK: - Project links

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("about.section.links", comment: ""))
            HStack(spacing: 10) {
                Button(NSLocalizedString("about.link.github", comment: "")) {
                    NSWorkspace.shared.open(Self.githubURL)
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                Button(NSLocalizedString("about.link.issues", comment: "")) {
                    NSWorkspace.shared.open(Self.issuesURL)
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.orange, compact: true))
                Button(NSLocalizedString("about.link.releases", comment: "")) {
                    NSWorkspace.shared.open(Self.releasesURL)
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.blue)
    }

    // MARK: - Credits

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("about.section.credits", comment: ""))
            Text(NSLocalizedString("about.credits.runtime", comment: ""))
                .font(NeoFont.f(.subheadline))
            Button(NSLocalizedString("about.link.licenses", comment: "")) {
                NSWorkspace.shared.open(Self.licensesURL)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.purple)
    }

    // MARK: - Shared styling

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(NeoFont.f(.headline, .heavy))
            .textCase(.uppercase)
    }
}
