import SwiftUI
import AppKit

/// Sheet for adding a new download: URL entry with site detection, quality /
/// format / category pickers, destination chooser, and connection count.
///
/// NOTE: quality & format pickers are UI-only for now; they will be passed to
/// the MediaExtractor (yt-dlp wrapper) once that engine lands.
struct AddDownloadSheet: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var detectedSite: SourceSite = .other
    @State private var quality = "best"
    @State private var format: MediaFormat = .video
    @State private var category: DownloadCategory = .other
    @State private var connections: Int = 8
    @State private var destinationOverride: URL?
    @State private var isAdding = false

    enum MediaFormat: String, CaseIterable {
        case video, audio
    }

    private let qualities = ["best", "1080p", "720p", "480p"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "add.title"))
                .font(.title2.weight(.heavy))

            // MARK: URL
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "add.url.label"))
                    .font(.headline)
                TextField(
                    String(localized: "add.url.label"),
                    text: $urlString,
                    prompt: Text(String(localized: "add.url.placeholder"))
                )
                .textFieldStyle(.roundedBorder)
                siteBadge
            }

            // MARK: Quality chips
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "add.quality"))
                    .font(.headline)
                HStack(spacing: 8) {
                    ForEach(qualities, id: \.self) { q in
                        Button(qualityLabel(for: q)) {
                            quality = q
                        }
                        .buttonStyle(NeoButtonStyle(
                            bg: quality == q ? Neo.yellow : Neo.paper(scheme),
                            compact: true
                        ))
                    }
                }
            }

            // MARK: Format
            Picker(String(localized: "add.format"), selection: $format) {
                Text(String(localized: "add.format.video")).tag(MediaFormat.video)
                Text(String(localized: "add.format.audio")).tag(MediaFormat.audio)
            }
            .pickerStyle(.segmented)

            // MARK: Category
            Picker(String(localized: "add.category"), selection: $category) {
                ForEach(DownloadCategory.allCases, id: \.self) { c in
                    Text(String(localized: "category.\(c.rawValue)")).tag(c)
                }
            }
            .pickerStyle(.segmented)

            // MARK: Destination
            HStack {
                Text(String(localized: "add.destination"))
                    .font(.headline)
                Spacer()
                Text(destinationURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(String(localized: "add.destination.choose")) {
                    if let url = chooseDirectory(initial: destinationURL) {
                        // Per-download override; the category default in Settings is untouched.
                        destinationOverride = url
                    }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            }

            // MARK: Connections
            // NOTE: no localization key was provided for this label, so the
            // stepper shows the bare value.
            HStack {
                Stepper(value: $connections, in: 1...16) {
                    Text("\(connections)")
                        .font(.headline)
                }
                Spacer()
            }

            Spacer()

            // MARK: Actions
            HStack {
                Button(String(localized: "add.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "add.start")) {
                    startDownload()
                }
                .neoButton(bg: Neo.green)
                .disabled(!isValidURL || isAdding)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            connections = settings.settings.defaultConnections
        }
        .onChange(of: urlString) { _, newValue in
            detectedSite = detectSourceSite(from: newValue)
        }
    }

    // MARK: - Helpers

    private var siteBadge: some View {
        Group {
            if urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(String(localized: "add.site.unknown"))
                    .neoBadge(bg: Neo.paper(scheme))
            } else {
                HStack(spacing: 6) {
                    Text(String(format: String(localized: "add.site.detected"), detectedSite.rawValue.capitalized))
                        .font(.caption.weight(.bold))
                    SourceBadge(site: detectedSite)
                }
            }
        }
    }

    private func qualityLabel(for q: String) -> String {
        q == "best" ? String(localized: "add.quality.best") : q
    }

    private var destinationURL: URL {
        destinationOverride ?? settings.folderURL(for: category)
    }

    private var isValidURL: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let urlScheme = url.scheme?.lowercased(),
              urlScheme == "http" || urlScheme == "https",
              url.host != nil
        else { return false }
        return true
    }

    private func startDownload() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let urlScheme = url.scheme?.lowercased(),
              urlScheme == "http" || urlScheme == "https"
        else { return }
        isAdding = true
        let lastComponent = url.lastPathComponent
        let filename = (lastComponent.isEmpty || lastComponent == "/")
            ? String(localized: "common.unknown")
            : lastComponent
        let site: SourceSite = detectedSite == .other ? .direct : detectedSite
        let destination = destinationURL
        let engine = engine
        Task {
            await engine.add(
                url: url,
                filename: filename,
                category: category,
                sourceSite: site,
                connections: connections,
                destination: destination
            )
            dismiss()
        }
    }
}

// MARK: - Site detection

/// Heuristic site detection on the URL host string.
private func detectSourceSite(from string: String) -> SourceSite {
    let lower = string.lowercased()
    if lower.contains("youtube.com") || lower.contains("youtu.be") { return .youtube }
    if lower.contains("x.com") || lower.contains("twitter.com") { return .x }
    if lower.contains("tiktok.com") { return .tiktok }
    if lower.contains("instagram.com") { return .instagram }
    if lower.contains("t.me") || lower.contains("telegram") { return .telegram }
    if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .other }
    return .direct
}
