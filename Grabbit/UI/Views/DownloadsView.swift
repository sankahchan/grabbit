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
        .navigationTitle(String(localized: "downloads.title"))
        .sheet(isPresented: $showingAdd) {
            AddDownloadSheet()
        }
    }

    // MARK: - Recovery banner

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Text("\(String(localized: "downloads.recovered.title")): \(engine.recoveredCount)")
                .font(.headline.weight(.bold))
            Spacer()
            Button(String(localized: "downloads.resumeAll")) {
                engine.resumeAllInterrupted()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            Button(String(localized: "common.close")) {
                engine.dismissRecovery()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
        .neoCard(bg: Neo.yellow)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(String(localized: "downloads.empty.title"))
                .font(.title2.weight(.heavy))
            Text(String(localized: "downloads.empty.hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "downloads.add")) {
                showingAdd = true
            }
            .neoButton(bg: Neo.yellow)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Download card

    private func downloadCard(for item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.filename)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Spacer()
                stateBadge(for: item.state)
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

            Text(String(localized: "downloads.segments"))
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            SegmentedProgressBar(segments: item.segments)

            HStack {
                Text("\(String(localized: "downloads.speed")): \(formatSpeed(item.speedBytesPerSec))")
                Text("•")
                Text("\(String(localized: "downloads.eta")): \(formatETA(item.etaSeconds))")
                Spacer()
                Text("\(Int((item.progress * 100).rounded()))%")
                    .fontWeight(.bold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                actionButtons(for: item)
            }
        }
        .neoCard()
    }

    private func stateBadge(for state: DownloadState) -> some View {
        Text(state.localizedName)
            .neoBadge(bg: badgeColor(for: state))
    }

    private func badgeColor(for state: DownloadState) -> Color {
        switch state {
        case .queued: Neo.paperLight
        case .downloading: Neo.blue
        case .paused: Neo.yellow
        case .completed: Neo.green
        case .failed: Neo.red
        case .interrupted: Neo.orange
        }
    }

    @ViewBuilder
    private func actionButtons(for item: DownloadItem) -> some View {
        switch item.state {
        case .downloading:
            Button(String(localized: "downloads.pause")) {
                engine.pause(item.id)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
        case .paused, .interrupted, .queued:
            Button(String(localized: "downloads.resume")) {
                engine.resume(item.id)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
        case .failed:
            Button(String(localized: "common.retry")) {
                engine.resume(item.id)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
        case .completed:
            EmptyView()
        }
        if item.state != .completed {
            Button(String(localized: "downloads.cancel")) {
                engine.cancel(item.id)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.orange, compact: true))
        }
        Button(String(localized: "downloads.remove")) {
            engine.remove(item.id)
        }
        .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
    }
}
