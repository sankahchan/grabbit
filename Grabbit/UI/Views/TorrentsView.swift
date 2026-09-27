import SwiftUI

/// Torrents tab: one neo card per torrent with a linear progress bar,
/// seeds/peers/ratio stats, and pause/resume/remove actions.
struct TorrentsView: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 12) {
            if torrentEngine.torrents.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                HStack {
                    Spacer()
                    Button(String(localized: "torrents.add")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(torrentEngine.torrents) { item in
                            torrentCard(for: item)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .padding(12)
        .navigationTitle(String(localized: "torrents.title"))
        .sheet(isPresented: $showingAdd) {
            TorrentAddSheet()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnet")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(String(localized: "torrents.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "torrents.add")) {
                showingAdd = true
            }
            .neoButton(bg: Neo.yellow)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Torrent card

    private func torrentCard(for item: TorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.name)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Spacer()
                Text(item.state.localizedName)
                    .neoBadge(bg: badgeColor(for: item.state))
            }

            NeoLinearBar(progress: item.progress, fill: Neo.purple)

            HStack(spacing: 12) {
                Text("\(String(localized: "torrents.seeds")): \(item.seeds)")
                Text("\(String(localized: "torrents.peers")): \(item.peers)")
                Text("\(String(localized: "torrents.ratio")): \(String(format: "%.2f", item.ratio))")
                Spacer()
                Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                switch item.state {
                case .downloading, .seeding:
                    Button(String(localized: "downloads.pause")) {
                        torrentEngine.pause(item.id)
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                case .paused:
                    Button(String(localized: "downloads.resume")) {
                        torrentEngine.resume(item.id)
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                case .completed, .failed:
                    EmptyView()
                }
                // NOTE: currently removes the entry but keeps downloaded data.
                // A "delete data" toggle can be added to a confirmation dialog later.
                Button(String(localized: "common.delete")) {
                    torrentEngine.remove(item.id, deleteData: false)
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
            }
        }
        .neoCard()
    }

    private func badgeColor(for state: TorrentState) -> Color {
        switch state {
        case .downloading: Neo.blue
        case .seeding: Neo.green
        case .paused: Neo.yellow
        case .completed: Neo.green
        case .failed: Neo.red
        }
    }
}

// MARK: - Add torrent sheet

struct TorrentAddSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "torrents.add"))
                .font(.title2.weight(.heavy))

            TextField(
                String(localized: "torrents.add"),
                text: $input,
                prompt: Text(String(localized: "torrents.add.placeholder"))
            )
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Neo.red)
            }

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "torrents.add")) {
                    addTorrent()
                }
                .neoButton(bg: Neo.green)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func addTorrent() {
        let magnet = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let savePath = settings.folderURL(for: .other)
        let engine = torrentEngine
        Task {
            do {
                try await engine.add(magnetOrURL: magnet, savePath: savePath)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
