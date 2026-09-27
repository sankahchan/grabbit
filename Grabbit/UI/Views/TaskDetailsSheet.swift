import SwiftUI

/// Task Details sheet (Motrix's Task Details dialog, neo-styled): full info
/// plus extra actions for one direct download or one torrent.
struct TaskDetailsSheet: View {
    enum Subject: Identifiable {
        case download(DownloadItem)
        case torrent(TorrentItem)

        var id: UUID {
            switch self {
            case .download(let item): item.id
            case .torrent(let item): item.id
            }
        }

        var name: String {
            switch self {
            case .download(let item): item.filename
            case .torrent(let item): item.name
            }
        }
    }

    let subject: Subject

    @Environment(DownloadEngine.self) private var downloads
    @Environment(TorrentEngine.self) private var torrents
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var showingFiles = false
    @State private var showingSeeding = false

    private var torrentItem: TorrentItem? {
        if case .torrent(let item) = subject { item } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            saveToSection
            progressSection
            sourceSection
            if let error = failureMessage {
                errorSection(error)
            }
            Spacer(minLength: 0)
            actionsRow
        }
        .padding(20)
        .frame(width: 560)
        .sheet(isPresented: $showingFiles) {
            if let item = torrentItem { TorrentFilesSheet(item: item) }
        }
        .sheet(isPresented: $showingSeeding) {
            if let item = torrentItem { TorrentSeedingSheet(item: item) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "task.details.title"))
                .font(.title2.weight(.heavy))
            HStack(spacing: 8) {
                Text(subject.name)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                Spacer()
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch subject {
        case .download(let item):
            Text(item.state.localizedName)
                .neoBadge(bg: badgeColor(for: item.state))
        case .torrent(let item):
            let display = TorrentDisplayStatus.of(item)
            Text(display.localizedName)
                .neoBadge(bg: badgeColor(for: display))
        }
    }

    // MARK: - Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private var saveDirectory: URL {
        switch subject {
        case .download(let item):
            item.destinationURL.deletingLastPathComponent()
        case .torrent(let item):
            item.savePath
        }
    }

    private var saveToSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "task.details.saveTo"))
            HStack(spacing: 8) {
                Text(Self.tildePath(saveDirectory.path))
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(String(localized: "task.details.openFinder")) {
                    openFolder()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            }
        }
    }

    private func openFolder() {
        switch subject {
        case .download(let item):
            FinderReveal.reveal(
                directory: item.destinationURL.deletingLastPathComponent(),
                named: item.destinationURL.lastPathComponent)
        case .torrent(let item):
            FinderReveal.reveal(directory: item.savePath, named: item.name)
        }
    }

    private static func tildePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "task.details.progress"))
            switch subject {
            case .download(let item):
                HStack {
                    Text("\(formatBytes(item.downloadedBytes)) / \(item.totalBytes.map(formatBytes) ?? String(localized: "common.unknown"))")
                    Spacer()
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .fontWeight(.bold)
                }
                .font(.subheadline)
                SegmentedProgressBar(segments: item.segments)
                HStack(spacing: 8) {
                    Text("\(String(localized: "downloads.speed")): \(formatSpeed(item.speedBytesPerSec))")
                    Text("•")
                    Text("\(String(localized: "downloads.eta")): \(formatETA(item.etaSeconds))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .torrent(let item):
                HStack {
                    Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
                    Spacer()
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .fontWeight(.bold)
                }
                .font(.subheadline)
                NeoLinearBar(progress: item.progress, fill: Neo.purple)
                HStack(spacing: 8) {
                    Text("\(String(localized: "torrents.seeds")): \(item.numSeeders)")
                    Text("\(String(localized: "torrents.peers")): \(item.peers)")
                    Text("\(String(localized: "torrents.ratio")): \(String(format: "%.2f", item.ratio))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("↓ \(formatBytes(item.downloadSpeed))/s")
                    Text("↑ \(formatBytes(item.uploadSpeed))/s")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "task.details.source"))
            switch subject {
            case .download(let item):
                linkRow(item.url.absoluteString)
                HStack(spacing: 6) {
                    SourceBadge(site: item.sourceSite)
                    Text(item.category.localizedName)
                        .neoBadge(bg: Neo.purple)
                }
            case .torrent(let item):
                if let link = TaskAction.copyableLink(for: item) {
                    linkRow(link)
                }
                if let hash = item.infoHash, !hash.isEmpty {
                    detailRow(
                        label: String(localized: "task.details.infoHash"),
                        value: hash,
                        copy: hash)
                }
            }
        }
    }

    private func linkRow(_ link: String) -> some View {
        HStack(spacing: 8) {
            Text(link)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button {
                Clipboard.copy(link)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(NeoIconButtonStyle(bg: Neo.purple))
            .help(String(localized: "task.action.copyLink"))
            .accessibilityLabel(String(localized: "task.action.copyLink"))
        }
    }

    private func detailRow(label: String, value: String, copy: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let copy {
                Button {
                    Clipboard.copy(copy)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.purple))
                .help(String(localized: "task.action.copyLink"))
                .accessibilityLabel(String(localized: "task.action.copyLink"))
            }
        }
    }

    private var failureMessage: String? {
        switch subject {
        case .download(let item):
            item.state == .failed ? item.errorMessage : nil
        case .torrent(let item):
            item.state == .failed ? item.errorMessage : nil
        }
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "task.details.error"))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Neo.red)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsRow: some View {
        HStack(spacing: 10) {
            switch subject {
            case .download(let item):
                // Preserves the old "Cancel" capability: stop, drop the
                // partial data, and reset so it can start fresh.
                if item.state != .completed {
                    Button(String(localized: "task.details.restart")) {
                        downloads.cancel(item.id)
                        dismiss()
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.orange, compact: true))
                }
            case .torrent:
                // Preserves the old FILES / SEEDING buttons.
                Button(String(localized: "torrents.files")) {
                    showingFiles = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                Button(String(localized: "torrents.seeding")) {
                    showingSeeding = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
            }
            Spacer()
            Button(String(localized: "common.close")) {
                dismiss()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
    }
}
