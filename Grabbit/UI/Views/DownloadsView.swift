import SwiftUI

/// Downloads tab: recovery banner, then one neo card per download with a
/// segmented per-connection progress bar and pause/resume/cancel/remove.
///
/// The global "+ Add" toolbar button lives in MainView; the empty state here
/// also offers an Add button.
struct DownloadsView: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(\.colorScheme) private var scheme
    @State private var showingAdd = false
    @State private var showingBatch = false
    @State private var deletingItem: DownloadItem?
    @State private var detailsSubject: TaskDetailsSheet.Subject?

    var body: some View {
        VStack(spacing: 12) {
            if engine.recoveredCount > 0 {
                recoveryBanner
            }
            if engine.items.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("downloads.batch", comment: "")) {
                        showingBatch = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                    Button(NSLocalizedString("downloads.add", comment: "")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(engine.items) { item in
                            downloadCard(for: item)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .padding(12)
        .navigationTitle(NSLocalizedString("downloads.title", comment: ""))
        .sheet(isPresented: $showingAdd) {
            AddDownloadSheet()
        }
        .sheet(isPresented: $showingBatch) {
            BatchAddSheet()
        }
        .alert(item: $deletingItem) { item in
            // engine.remove drops the record and deletes the partial
            // (.grabbit-part) file; a finished file on disk is kept.
            Alert(
                title: Text(NSLocalizedString("downloads.remove.title", comment: "")),
                message: Text(item.state == .completed
                    ? NSLocalizedString("downloads.remove.keepFile", comment: "")
                    : NSLocalizedString("downloads.remove.deletePartial", comment: "")),
                primaryButton: .destructive(Text(NSLocalizedString("common.delete", comment: ""))) {
                    engine.remove(item.id)
                },
                secondaryButton: .cancel(Text(NSLocalizedString("common.cancel", comment: "")))
            )
        }
        .sheet(item: $detailsSubject) { subject in
            TaskDetailsSheet(subject: subject)
        }
    }

    // MARK: - Recovery banner

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Text("\(NSLocalizedString("downloads.recovered.title", comment: "")): \(engine.recoveredCount)")
                .font(.headline.weight(.bold))
            Spacer()
            Button(NSLocalizedString("downloads.resumeAll", comment: "")) {
                engine.resumeAllInterrupted()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            Button(NSLocalizedString("common.close", comment: "")) {
                engine.dismissRecovery()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
        .foregroundStyle(Neo.onAccent(Neo.yellow, scheme: scheme))
        .neoCard(bg: Neo.yellow)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("downloads.empty.title", comment: ""))
                .font(.title2.weight(.heavy))
            Text(NSLocalizedString("downloads.empty.hint", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(NSLocalizedString("downloads.batch", comment: "")) {
                    showingBatch = true
                }
                .neoButton(bg: Neo.blue)
                Button(NSLocalizedString("downloads.add", comment: "")) {
                    showingAdd = true
                }
                .neoButton(bg: Neo.yellow)
            }
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Download card

    private func downloadCard(for item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.filename)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                stateBadge(for: item.state)
                Spacer()
                TaskActionBar(actions: TaskAction.actions(forDownload: item.state)) { action in
                    handleAction(action, for: item)
                }
            }

            HStack(spacing: 6) {
                SourceBadge(site: item.sourceSite)
                Text(item.category.localizedName)
                    .neoBadge(bg: Neo.purple)
            }

            // Surface the failure reason — without this a failed download
            // shows just "FAILED" and nobody knows why (HTTP 403? no range
            // support? connection dropped?).
            if item.state == .failed, let message = item.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Neo.red)
                    .lineLimit(2)
            }

            Text(NSLocalizedString("downloads.segments", comment: ""))
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            SegmentedProgressBar(segments: item.segments)

            HStack {
                Text("\(NSLocalizedString("downloads.speed", comment: "")): \(formatSpeed(item.speedBytesPerSec))")
                Text("•")
                Text("\(NSLocalizedString("downloads.eta", comment: "")): \(formatETA(item.etaSeconds))")
                if item.state == .downloading {
                    Text("•")
                    Text("\(item.segments.count) \(NSLocalizedString("downloads.connections", comment: ""))")
                }
                Spacer()
                Text("\(Int((item.progress * 100).rounded()))%")
                    .fontWeight(.bold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .neoCard()
    }

    private func handleAction(_ action: TaskAction, for item: DownloadItem) {
        switch action {
        case .pause:
            engine.pause(item.id)
        case .resume:
            engine.resume(item.id)
        case .delete:
            deletingItem = item
        case .openFolder:
            FinderReveal.reveal(
                directory: item.destinationURL.deletingLastPathComponent(),
                named: item.destinationURL.lastPathComponent)
        case .copyLink:
            Clipboard.copy(item.url.absoluteString)
        case .details:
            detailsSubject = .download(item)
        }
    }

    private func stateBadge(for state: DownloadState) -> some View {
        Text(state.localizedName)
            .neoBadge(bg: badgeColor(for: state))
    }
}
