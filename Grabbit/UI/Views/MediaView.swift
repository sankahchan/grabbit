import SwiftUI
import AppKit

/// Media tab: paste a video/page URL (YouTube, X, TikTok, IG, …), probe it
/// with yt-dlp, pick a quality preset, and download. Also shows the media
/// runtime status (yt-dlp / ffmpeg / deno) with install hints and the
/// independent yt-dlp updater.
struct MediaView: View {
    @Environment(MediaEngine.self) private var media
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
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("media.title", comment: ""))
        .onAppear(perform: refreshRuntime)
    }

    // MARK: - Runtime status

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("media.runtime.title", comment: ""))
                .font(.headline.weight(.heavy))
                .textCase(.uppercase)
            ForEach(runtime, id: \.0) { component, found in
                HStack(spacing: 8) {
                    Circle()
                        .fill(found ? Neo.green : Neo.red)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Neo.ink(scheme), lineWidth: 2))
                    Text(component.rawValue)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    if !found {
                        Text(component.installHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    Task { await checkForUpdate() }
                } label: {
                    Label(NSLocalizedString("media.runtime.checkUpdate", comment: ""),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .neoButton(bg: Neo.paper(scheme))
                .disabled(checkingUpdate)
                if let note = updateNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .neoCard()
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
                .font(.headline.weight(.heavy))
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .neoCard()
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
            ProgressView()
            Text(NSLocalizedString("media.probing", comment: ""))
                .font(.subheadline.weight(.bold))
        }
        .neoCard()
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
                .font(.headline.weight(.heavy))
            if let duration = probed.duration {
                Text(Self.formatDuration(duration))
                    .font(.caption)
            }
            Picker(NSLocalizedString("media.quality", comment: ""), selection: $selectedPresetID) {
                ForEach(probed.presets) { preset in
                    Text(presetLabel(preset)).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
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
            Text(media.probed?.title ?? "")
                .font(.headline.weight(.heavy))
                .lineLimit(1)
            NeoLinearBar(progress: media.progress)
            HStack {
                Text("\(Int(media.progress * 100))%")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button(NSLocalizedString("media.cancel", comment: "")) {
                    Task { await media.cancel() }
                }
                .neoButton(bg: Neo.red)
            }
            if !media.statusLine.isEmpty {
                Text(media.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .neoCard()
    }

    private var completedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text(NSLocalizedString("media.completed", comment: ""))
                    .lineLimit(1)
            }
            .font(.headline.weight(.heavy))
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
            Label(NSLocalizedString("media.failed", comment: ""), systemImage: "exclamationmark.triangle.fill")
                .font(.headline.weight(.heavy))
            Text(message)
                .font(.subheadline)
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
