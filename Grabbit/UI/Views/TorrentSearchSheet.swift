import SwiftUI

/// Torrents page: search public indexes (apibay, Nyaa) and add a hit in
/// one click. Results never auto-download — the user picks a row and hits
/// Add; added rows turn into a green check so several can be queued.
struct TorrentSearchSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var service = TorrentSearchService()
    @State private var query = ""
    @State private var addingID: String?
    @State private var addedIDs: Set<String> = []
    @State private var addError: String?

    var body: some View {
        @Bindable var service = service
        return VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("torrents.search.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))

            HStack(spacing: 8) {
                NeoMenuPicker(
                    selection: $service.source,
                    options: sources.map { ($0, $0.name) },
                    maxWidth: 200)
                TextField(
                    NSLocalizedString("torrents.search", comment: ""),
                    text: $query,
                    prompt: Text(NSLocalizedString(
                        "torrents.search.placeholder", comment: ""))
                )
                .neoTextField()
                .onSubmit { runSearch() }
                Button(NSLocalizedString("torrents.search", comment: "")) {
                    runSearch()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
                .disabled(
                    query.trimmingCharacters(in: .whitespaces).isEmpty
                        || service.isSearching)
            }

            if let message = addError ?? service.errorMessage {
                Text(message)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.red)
            }

            resultsArea

            Text(NSLocalizedString("torrents.search.disclaimer", comment: ""))
                .font(NeoFont.f(.caption2))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(NSLocalizedString("common.done", comment: "")) {
                    dismiss()
                }
                .neoButton(bg: Neo.blue)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    // MARK: - Results

    /// Built-ins plus the user's Torznab indexers, listed in settings
    /// order.
    private var sources: [TorrentSearchSource] {
        TorrentSearchProvider.builtIns.map { .builtin($0) }
            + settings.settings.torznabIndexers.map { .torznab($0) }
    }

    @ViewBuilder private var resultsArea: some View {
        if service.isSearching {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(height: 360)
        } else if service.results.isEmpty {
            VStack(spacing: 10) {
                AppIcon("magnifyingglass", size: 26)
                    .font(NeoFont.f(30))
                    .foregroundStyle(Neo.ink(scheme))
                Text(NSLocalizedString(
                    service.hasSearched
                        ? "torrents.search.empty"
                        : "torrents.search.prompt", comment: ""))
                    .font(NeoFont.f(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(service.results) { result in
                        resultRow(result)
                    }
                }
                .padding(2)
            }
            .frame(height: 360)
        }
    }

    private func resultRow(_ result: TorrentSearchResult) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(NeoFont.f(.subheadline, .semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let size = result.sizeBytes {
                        Text(formatBytes(size))
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(swarmColor(result.seeders ?? 0))
                            .frame(width: 7, height: 7)
                        Text("\(NSLocalizedString("torrents.seeds", comment: "")): \(result.seeders ?? 0)")
                    }
                    Text("\(NSLocalizedString("torrents.peers", comment: "")): \(result.leechers ?? 0)")
                    Text(result.providerName)
                        .neoBadge(bg: Neo.purple)
                }
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if addedIDs.contains(result.id) {
                AppIcon("checkmark.circle.fill", size: 20)
                    .foregroundStyle(Neo.green)
            } else {
                Button {
                    add(result)
                } label: {
                    if addingID == result.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(NSLocalizedString("torrents.search.add", comment: ""))
                    }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(addingID != nil)
            }
        }
        .padding(10)
        .background(
            Neo.paper(scheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func swarmColor(_ seeders: Int) -> Color {
        switch SwarmHealth.of(seeders: seeders) {
        case .healthy: Neo.green
        case .fair: Neo.orange
        case .poor: Neo.red
        }
    }

    // MARK: - Actions

    private func runSearch() {
        addError = nil
        service.search(query: query)
    }

    private func add(_ result: TorrentSearchResult) {
        addingID = result.id
        addError = nil
        Task {
            do {
                try await torrentEngine.add(
                    magnetOrURL: result.source,
                    savePath: settings.folderURL(for: .other),
                    displayName: result.name)
                addedIDs.insert(result.id)
                toastCenter.push(AppToast(
                    kind: .info,
                    source: .torrent,
                    title: NSLocalizedString("torrents.search.added", comment: ""),
                    message: result.name))
            } catch {
                addError = error.localizedDescription
            }
            addingID = nil
        }
    }
}
