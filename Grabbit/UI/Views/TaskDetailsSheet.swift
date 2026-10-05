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
            prioritySection
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
            Text(NSLocalizedString("task.details.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            HStack(spacing: 8) {
                Text(subject.name)
                    .font(NeoFont.f(.headline, .bold))
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
            .font(NeoFont.f(.caption2, .bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    /// Backlog #7: per-task priority stepper (downloads only). Reads the
    /// live value from the engine — the sheet's `subject` is a snapshot.
    @ViewBuilder
    private var prioritySection: some View {
        if case .download(let item) = subject {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(NSLocalizedString("task.details.priority", comment: ""))
                HStack(spacing: 10) {
                    NeoStepper(value: Binding(
                        get: {
                            downloads.items.first(where: { $0.id == item.id })?.priority
                                ?? item.priority
                        },
                        set: { downloads.setPriority(id: item.id, priority: $0) }
                    ), in: -5...5, step: 1) { v in "\(v)" }
                    Text(NSLocalizedString("task.details.priorityHint", comment: ""))
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            sectionTitle(NSLocalizedString("task.details.saveTo", comment: ""))
            HStack(spacing: 8) {
                Text(Self.tildePath(saveDirectory.path))
                    .font(NeoFont.mono(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(NSLocalizedString("task.details.openFinder", comment: "")) {
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
            sectionTitle(NSLocalizedString("task.details.progress", comment: ""))
            switch subject {
            case .download(let item):
                HStack {
                    Text("\(formatBytes(item.downloadedBytes)) / \(item.totalBytes.map(formatBytes) ?? NSLocalizedString("common.unknown", comment: ""))")
                    Spacer()
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .fontWeight(.bold)
                }
                .font(NeoFont.f(.subheadline))
                SegmentedProgressBar(segments: item.segments)
                HStack(spacing: 8) {
                    Text("\(NSLocalizedString("downloads.speed", comment: "")): \(formatSpeed(item.speedBytesPerSec))")
                    Text("•")
                    Text("\(NSLocalizedString("downloads.eta", comment: "")): \(formatETA(item.etaSeconds))")
                }
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            case .torrent(let item):
                HStack {
                    Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
                    Spacer()
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .fontWeight(.bold)
                }
                .font(NeoFont.f(.subheadline))
                NeoLinearBar(progress: item.progress, fill: Neo.purple)
                HStack(spacing: 8) {
                    Text("\(NSLocalizedString("torrents.seeds", comment: "")): \(item.numSeeders)")
                    Text("\(NSLocalizedString("torrents.peers", comment: "")): \(item.peers)")
                    Text("\(NSLocalizedString("torrents.ratio", comment: "")): \(String(format: "%.2f", item.ratio))")
                }
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("↓ \(formatBytes(item.downloadSpeed))/s")
                    Text("↑ \(formatBytes(item.uploadSpeed))/s")
                }
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(NSLocalizedString("task.details.source", comment: ""))
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
                        label: NSLocalizedString("task.details.infoHash", comment: ""),
                        value: hash,
                        copy: hash)
                }
            }
        }
    }

    private func linkRow(_ link: String) -> some View {
        HStack(spacing: 8) {
            Text(link)
                .font(NeoFont.mono(.caption))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button {
                Clipboard.copy(link)
            } label: {
                AppIcon("doc.on.doc", size: 14)
            }
            .buttonStyle(NeoIconButtonStyle(bg: Neo.purple))
            .help(NSLocalizedString("task.action.copyLink", comment: ""))
            .accessibilityLabel(NSLocalizedString("task.action.copyLink", comment: ""))
        }
    }

    private func detailRow(label: String, value: String, copy: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(NeoFont.f(.subheadline, .semibold))
            Text(value)
                .font(NeoFont.mono(.subheadline))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let copy {
                Button {
                    Clipboard.copy(copy)
                } label: {
                    AppIcon("doc.on.doc", size: 14)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.purple))
                .help(NSLocalizedString("task.action.copyLink", comment: ""))
                .accessibilityLabel(NSLocalizedString("task.action.copyLink", comment: ""))
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
            sectionTitle(NSLocalizedString("task.details.error", comment: ""))
            Text(message)
                .font(NeoFont.f(.subheadline))
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
                    Button(NSLocalizedString("task.details.restart", comment: "")) {
                        downloads.cancel(item.id)
                        dismiss()
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.orange, compact: true))
                }
            case .torrent:
                // Preserves the old FILES / SEEDING buttons.
                Button(NSLocalizedString("torrents.files", comment: "")) {
                    showingFiles = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                Button(NSLocalizedString("torrents.seeding", comment: "")) {
                    showingSeeding = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
            }
            Spacer()
            Button(NSLocalizedString("common.close", comment: "")) {
                dismiss()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
    }
}
