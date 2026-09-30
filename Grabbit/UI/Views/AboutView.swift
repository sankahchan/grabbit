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

    var body: some View {
        @Bindable var store = store
        let settings = $store.settings

        ScrollView {
            VStack(spacing: 16) {
                identityCard
                updatesCard(settings: settings)
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
        let version = (short?.isEmpty == false) ? short! : "—"
        let buildNumber = (build?.isEmpty == false) ? build! : "—"
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
                .font(.largeTitle.weight(.heavy))
            Text(versionText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("about.tagline", comment: ""))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .neoCard()
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(NSLocalizedString("about.updates.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
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

    // MARK: - Credits

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(NSLocalizedString("about.section.credits", comment: ""))
            Text(NSLocalizedString("about.credits.runtime", comment: ""))
                .font(.subheadline)
            Button(NSLocalizedString("about.link.licenses", comment: "")) {
                NSWorkspace.shared.open(Self.licensesURL)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - Shared styling

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.heavy))
            .textCase(.uppercase)
    }
}
