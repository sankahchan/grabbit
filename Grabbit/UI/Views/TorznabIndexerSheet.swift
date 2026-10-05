import SwiftUI

/// Add a Torznab indexer (Jackett, Prowlarr, …): display name, the torznab
/// endpoint URL, and the API key. Name/URL land in settings.json; the key
/// goes to the Keychain via `TorznabVault`.
struct TorznabIndexerSheet: View {
    @Environment(SettingsStore.self) private var store: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("settings.indexers.add", comment: ""))
                .font(NeoFont.f(.title2, .heavy))

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.indexers.name", comment: ""))
                    .font(NeoFont.f(.headline))
                TextField(
                    "",
                    text: $name,
                    prompt: Text("Prowlarr"))
                    .neoTextField()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.indexers.url", comment: ""))
                    .font(NeoFont.f(.headline))
                TextField(
                    "",
                    text: $urlString,
                    prompt: Text(
                        "http://localhost:9117/api/v2.0/indexers/all/results/torznab"))
                    .neoTextField()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.indexers.apiKey", comment: ""))
                    .font(NeoFont.f(.headline))
                SecureField("", text: $apiKey)
                    .neoTextField()
            }

            Text(NSLocalizedString("settings.indexers.note", comment: ""))
                .font(NeoFont.f(.caption2))
                .foregroundStyle(.secondary)

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("common.save", comment: "")) {
                    save()
                }
                .neoButton(bg: Neo.green)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: trimmedURL) != nil
    }

    private func save() {
        let indexer = TorznabIndexer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: trimmedURL)
        store.settings.torznabIndexers.append(indexer)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            TorznabVault.saveKey(key, for: indexer.id)
        }
        store.save()
        dismiss()
    }
}
