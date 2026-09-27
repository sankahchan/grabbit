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
        .navigationTitle(String(localized: "media.title"))
        .onAppear(perform: refreshRuntime)
    }

    // MARK: - Runtime status

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "media.runtime.title"))
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
                    Label(String(localized: "media.runtime.checkUpdate"),
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
            updateNote = String(localized: "media.runtime.updated")
        } catch MediaComponentUpdater.UpdateError.upToDate {
            updateNote = String(localized: "media.runtime.upToDate")
        } catch {
            updateNote = error.localizedDescription
        }
        refreshRuntime()
    }

    // MARK: - URL entry

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "media.url.title"))
                .font(.headline.weight(.heavy))
                .textCase(.uppercase)
            HStack(spacing: 10) {
                TextField(String(localized: "media.url.placeholder"), text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { probe() }
                Button(String(localized: "media.url.paste")) { pasteURL() }
                    .neoButton(bg: Neo.paper(scheme))
                Button(String(localized: "media.url.probe")) { probe() }
                    .neoButton(bg: Neo.yellow)
                    .disabled(!canProbe)
            }
            Text(String(localized: "media.url.hint"))
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
            Text(String(localized: "media.probing"))
                .font(.subheadline.weight(.bold))
        }
        .neoCard()
    }

    // MARK: - Probe result

    private func resultCard(_ probed: ProbedMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(probed.title)
                .font(.headline.weight(.heavy))
            if let duration = probed.duration {
                Text(Self.formatDuration(duration))
                    .font(.caption)
            }
            Picker(String(localized: "media.quality"), selection: $selectedPresetID) {
                ForEach(probed.presets) { preset in
                    Text(presetLabel(preset)).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 10) {
                Button(String(localized: "media.download")) { startDownload() }
                    .neoButton(bg: Neo.green)
                    .disabled(selectedPreset == nil)
                Button(String(localized: "media.clear")) {
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
                Button(String(localized: "media.cancel")) {
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
                Text(String(localized: "media.completed"))
                    .lineLimit(1)
            }
            .font(.headline.weight(.heavy))
            .foregroundStyle(Neo.ink(scheme))
            Button(String(localized: "media.new")) {
                urlText = ""
                Task { await media.reset() }
            }
            .neoButton(bg: Neo.paper(scheme))
        }
        .neoCard(bg: Neo.green.opacity(0.25))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "media.failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Neo.ink(scheme))
            Text(message)
                .font(.subheadline)
            Button(String(localized: "media.retry")) { probe() }
                .neoButton(bg: Neo.yellow)
        }
        .neoCard(bg: Neo.red.opacity(0.2))
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
