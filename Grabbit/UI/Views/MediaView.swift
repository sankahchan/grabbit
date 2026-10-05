import SwiftUI
import AppKit

/// Media tab: paste a video/page URL (YouTube, X, TikTok, IG, …), probe it
/// with yt-dlp, pick a quality preset, and download. Also shows the media
/// runtime status (yt-dlp / ffmpeg / deno) with install hints and the
/// independent yt-dlp updater.
struct MediaView: View {
    @Environment(MediaEngine.self) private var media
    @Environment(HistoryStore.self) private var historyStore: HistoryStore
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    @State private var urlText = ""
    @State private var selectedPresetID = "best"
    @State private var runtime: [(MediaRuntimeResolver.Component, Bool)] = []
    @State private var updateNote: String?
    @State private var checkingUpdate = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NeoPageHeader(
                    sticker: NSLocalizedString("page.media.sticker", comment: ""),
                    title: NSLocalizedString("media.title", comment: ""),
                    accent: Neo.blue)
                statsStrip
                runtimeCard
                urlCard
                switch media.state {
                case .ready:
                    if let probed = media.probed { resultCard(probed) }
                case .downloading:
                    progressCard
                case .completed:
                    completedCard
                case .failed:
                    if let error = media.errorMessage { errorCard(error) }
                case .probing:
                    probingCard
                case .idle:
                    EmptyView()
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("media.title", comment: ""))
        .onAppear(perform: refreshRuntime)
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: 12) {
            NeoStatCard(
                label: NSLocalizedString("media.stats.active", comment: ""),
                value: media.state == .downloading ? "1" : "0",
                unit: nil,
                subtitle: media.state == .downloading
                    ? (media.statusLine.isEmpty
                        ? NSLocalizedString("state.downloading", comment: "")
                        : media.statusLine)
                    : NSLocalizedString("media.stats.active.idle", comment: ""),
                accent: Neo.blue,
                chart: MiniBarChart(
                    values: media.state == .downloading ? [media.progress] : [],
                    slots: 14,
                    accent: Neo.blue))

            NeoStatCard(
                label: NSLocalizedString("downloads.stats.completed", comment: ""),
                value: "\(completedToday)",
                unit: nil,
                subtitle: NeoStats.lastCompletedText(
                    entries: historyStore.entries, kind: .media),
                accent: Neo.green,
                chart: MiniBarChart(
                    values: NeoStats.completedBuckets(
                        entries: historyStore.entries, kind: .media),
                    slots: 8,
                    accent: Neo.green))

            NeoStatCard(
                label: NSLocalizedString("media.stats.data", comment: ""),
                value: dataDigits.value,
                unit: dataDigits.unit,
                subtitle: NSLocalizedString(
                    "media.stats.data.subtitle", comment: ""),
                accent: Neo.yellow,
                chart: MiniBarChart(
                    values: NeoStats.byteBuckets(
                        entries: historyStore.entries, kind: .media),
                    slots: 8,
                    accent: Neo.yellow))
        }
    }

    private var completedToday: Int {
        NeoStats.completedTodayCount(
            entries: historyStore.entries, kind: .media)
    }

    private var dataDigits: (value: String, unit: String) {
        let bytes = NeoStats.todayBytes(
            entries: historyStore.entries, kind: .media)
        if bytes >= 1_000_000_000 {
            return (String(format: "%.1f", Double(bytes) / 1_000_000_000), "GB")
        }
        if bytes >= 1_000_000 {
            return (String(format: "%.0f", Double(bytes) / 1_000_000), "MB")
        }
        if bytes >= 1_000 {
            return (String(format: "%.0f", Double(bytes) / 1_000), "KB")
        }
        return ("0", "KB")
    }

    // MARK: - Runtime status

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("media.runtime.title", comment: ""))
                .font(NeoFont.f(.headline, .heavy))
                .textCase(.uppercase)
            ForEach(runtime, id: \.0) { component, found in
                HStack(spacing: 8) {
                    Circle()
                        .fill(found ? Neo.green : Neo.red)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Neo.ink(scheme), lineWidth: 2))
                    Text(component.rawValue)
                        .font(NeoFont.f(.subheadline, .bold))
                    Spacer()
                    if !found {
                        Text(component.installHint)
                            .font(NeoFont.f(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    Task { await checkForUpdate() }
                } label: {
                    Label {
                        Text(NSLocalizedString("media.runtime.checkUpdate", comment: ""))
                    } icon: {
                        AppIcon("arrow.triangle.2.circlepath", size: 13)
                    }
                }
                .neoButton(bg: Neo.paper(scheme))
                .disabled(checkingUpdate)
                if let note = updateNote {
                    Text(note).font(NeoFont.f(.caption)).foregroundStyle(.secondary)
                }
            }
        }
        .neoCard(accent: Neo.blue)
    }

    private func refreshRuntime() {
        runtime = MediaRuntimeResolver.Component.allCases.map {
            ($0, (try? MediaRuntimeResolver.resolve($0).get()) != nil)
        }
    }

    private func checkForUpdate() async {
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            try await MediaComponentUpdater.updateYtDlp()
            updateNote = NSLocalizedString("media.runtime.updated", comment: "")
        } catch MediaComponentUpdater.UpdateError.upToDate {
            updateNote = NSLocalizedString("media.runtime.upToDate", comment: "")
        } catch {
            updateNote = error.localizedDescription
        }
        refreshRuntime()
    }

    // MARK: - URL entry

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("media.url.title", comment: ""))
                .font(NeoFont.f(.headline, .heavy))
                .textCase(.uppercase)
            HStack(spacing: 10) {
                TextField(NSLocalizedString("media.url.placeholder", comment: ""), text: $urlText)
                    .neoTextField()
                    .onSubmit { probe() }
                Button(NSLocalizedString("common.paste", comment: "")) { pasteURL() }
                    .neoButton(bg: Neo.paper(scheme))
                Button(NSLocalizedString("media.url.probe", comment: "")) { probe() }
                    .neoButton(bg: Neo.yellow)
                    .disabled(!canProbe)
            }
            Text(NSLocalizedString("media.url.hint", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
        }
        .neoCard(accent: Neo.yellow)
    }

    private var canProbe: Bool {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else { return false }
        return media.state != .probing && media.state != .downloading
    }

    private func pasteURL() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func probe() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        selectedPresetID = "best"
        Task { await media.probe(url: url) }
    }

    private var probingCard: some View {
        HStack(spacing: 10) {
            NeoSpinner()
            Text(NSLocalizedString("media.probing", comment: ""))
                .font(NeoFont.f(.subheadline, .bold))
        }
        .neoCard(accent: Neo.blue)
    }

    // MARK: - Probe result

    private func resultCard(_ probed: ProbedMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Backlog #10: video thumbnail on the probe result card.
            if let thumb = probed.thumbnailURL {
                AsyncImage(url: thumb) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Neo.ink(scheme).opacity(0.15)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Neo.ink(scheme), lineWidth: 2)
                )
            }
            Text(probed.title)
                .font(NeoFont.f(.headline, .heavy))
            if let duration = probed.duration {
                Text(Self.formatDuration(duration))
                    .font(NeoFont.f(.caption))
            }
            HStack(spacing: 10) {
                Text(NSLocalizedString("media.quality", comment: ""))
                    .font(NeoFont.f(.headline))
                Spacer()
                NeoMenuPicker(
                    selection: $selectedPresetID,
                    options: probed.presets.map { (value: $0.id, title: presetLabel($0)) },
                    maxWidth: 320
                )
            }
            HStack(spacing: 10) {
                Button(NSLocalizedString("media.download", comment: "")) { startDownload() }
                    .neoButton(bg: Neo.green)
                    .disabled(selectedPreset == nil)
                Button(NSLocalizedString("media.clear", comment: "")) {
                    Task { await media.reset() }
                }
                .neoButton(bg: Neo.paper(scheme))
            }
        }
        .foregroundStyle(Neo.onAccent(Neo.yellow, scheme: scheme))
        .neoCard(bg: Neo.yellow)
    }

    private var selectedPreset: MediaPreset? {
        media.probed?.presets.first { $0.id == selectedPresetID }
            ?? media.probed?.presets.first
    }

    private func presetLabel(_ preset: MediaPreset) -> String {
        if let size = preset.estimatedSize {
            return "\(preset.label) · \(Self.formatBytes(size))"
        }
        return preset.label
    }

    private func startDownload() {
        guard let preset = selectedPreset else { return }
        // Auto-save into the category download folder (user-changeable in
        // Settings) — no save dialog.
        let directory = settings.folderURL(for: preset.isAudioOnly ? .audio : .video)
        // Phase 5 speed limiter: push the current global cap into yt-dlp.
        media.speedLimitBytesPerSec = settings.settings.speedLimitBytesPerSec
        Task { await media.download(preset: preset, to: directory) }
    }

    // MARK: - Progress / completion / error

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(media.displayTitle ?? media.probed?.title ?? "")
                .font(NeoFont.f(.headline, .heavy))
                .lineLimit(1)
            NeoLinearBar(progress: media.progress)
            HStack {
                Text("\(Int(media.progress * 100))%")
                    .font(NeoFont.f(.subheadline, .bold))
                Spacer()
                Button(NSLocalizedString("media.cancel", comment: "")) {
                    Task { await media.cancel() }
                }
                .neoButton(bg: Neo.red)
            }
            if !media.statusLine.isEmpty {
                Text(media.statusLine)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .neoCard(accent: Neo.blue)
    }

    private var completedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppIcon("checkmark.circle.fill", size: 14)
                Text(NSLocalizedString("media.completed", comment: ""))
                    .lineLimit(1)
            }
            .font(NeoFont.f(.headline, .heavy))
            Button(NSLocalizedString("media.new", comment: "")) {
                urlText = ""
                Task { await media.reset() }
            }
            .neoButton(bg: Neo.paper(scheme))
        }
        // Solid fill + onAccent: the old translucent fill composited to a
        // dark tone with dark text on it (unreadable).
        .foregroundStyle(Neo.onAccent(Neo.green, scheme: scheme))
        .neoCard(bg: Neo.green)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(NSLocalizedString("media.failed", comment: ""))
            } icon: {
                AppIcon("exclamationmark.triangle.fill", size: 15)
            }
                .font(NeoFont.f(.headline, .heavy))
            Text(message)
                .font(NeoFont.f(.subheadline))
            Button(NSLocalizedString("media.retry", comment: "")) { probe() }
                .neoButton(bg: Neo.yellow)
        }
        // Solid fill + onAccent: the old translucent fill composited to a
        // dark tone with dark text on it (unreadable).
        .foregroundStyle(Neo.onAccent(Neo.red, scheme: scheme))
        .neoCard(bg: Neo.red)
    }

    // MARK: - Formatting

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
