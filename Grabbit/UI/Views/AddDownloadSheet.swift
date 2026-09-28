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
    @State private var customFilename = ""
    @State private var quality = "best"
    @State private var format: MediaFormat = .video
    @State private var category: DownloadCategory = .other
    @State private var connections: Int = 8
    @State private var destinationOverride: URL?
    @State private var referer = ""
    @State private var cookie = ""
    @State private var authorization = ""
    @State private var userAgent = ""
    @State private var isAdding = false

    enum MediaFormat: String, CaseIterable {
        case video, audio
    }

    private let qualities = ["best", "1080p", "720p", "480p"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("add.title", comment: ""))
                .font(.title2.weight(.heavy))

            // MARK: URL
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("add.url.label", comment: ""))
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField(
                        NSLocalizedString("add.url.label", comment: ""),
                        text: $urlString,
                        prompt: Text(NSLocalizedString("add.url.placeholder", comment: ""))
                    )
                    .neoTextField()
                    Button(NSLocalizedString("common.paste", comment: "")) { pasteURL() }
                        .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                }
                siteBadge
            }

            // MARK: Filename (optional rename)
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("add.filename.label", comment: ""))
                    .font(.headline)
                TextField(
                    NSLocalizedString("add.filename.label", comment: ""),
                    text: $customFilename,
                    prompt: Text(NSLocalizedString("add.filename.placeholder", comment: ""))
                )
                .neoTextField()
            }

            // MARK: Quality chips
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("add.quality", comment: ""))
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
            NeoSegmented(selection: $format, titles: [
                (MediaFormat.video, NSLocalizedString("add.format.video", comment: "")),
                (MediaFormat.audio, NSLocalizedString("add.format.audio", comment: "")),
            ])

            // MARK: Category
            NeoSegmented(selection: $category, titles: DownloadCategory.allCases.map {
                ($0, $0.localizedName)
            })

            // MARK: Destination
            HStack {
                Text(NSLocalizedString("add.destination", comment: ""))
                    .font(.headline)
                Spacer()
                Text(destinationURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(NSLocalizedString("add.destination.choose", comment: "")) {
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
                NeoStepper(value: $connections, in: 1...16, step: 1) { v in "\(v)" }
                Spacer()
            }

            // MARK: Request headers (optional)
            // For downloads behind a login: the browser extension captures
            // these automatically, but a manual add can supply them here.
            DisclosureGroup(NSLocalizedString("add.headers.title", comment: "")) {
                VStack(spacing: 8) {
                    headerField(label: "Referer", text: $referer)
                    headerField(label: "Cookie", text: $cookie)
                    headerField(label: "Authorization", text: $authorization)
                    headerField(label: "User-Agent", text: $userAgent)
                    Text(NSLocalizedString("add.headers.note", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }

            Spacer()

            // MARK: Actions
            HStack {
                Button(NSLocalizedString("add.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("add.start", comment: "")) {
                    startDownload()
                }
                .neoButton(bg: Neo.green)
                .disabled(!isValidURL || isAdding)
            }
        }
        .padding(20)
        // Flexible width: a fixed 560pt sheet overflows (and gets clipped)
        // when the main window is narrower, e.g. on scaled displays.
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 600)
        .onAppear {
            connections = settings.settings.defaultConnections
        }
        .onChange(of: urlString) { _, newValue in
            detectedSite = detectSourceSite(from: newValue)
        }
    }

    // MARK: - Helpers

    private func pasteURL() {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlString = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var siteBadge: some View {
        Group {
            if urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(NSLocalizedString("add.site.unknown", comment: ""))
                    .neoBadge(bg: Neo.paper(scheme))
            } else {
                HStack(spacing: 6) {
                    Text(String(format: NSLocalizedString("add.site.detected", comment: ""), detectedSite.rawValue.capitalized))
                        .font(.caption.weight(.bold))
                    SourceBadge(site: detectedSite)
                }
            }
        }
    }

    private func qualityLabel(for q: String) -> String {
        q == "best" ? NSLocalizedString("add.quality.best", comment: "") : q
    }

    private func headerField(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(width: 110, alignment: .leading)
            TextField(label, text: text)
                .neoTextField()
        }
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
        let serverName = (lastComponent.isEmpty || lastComponent == "/")
            ? NSLocalizedString("common.unknown", comment: "")
            : lastComponent
        let custom = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = custom.isEmpty ? serverName : custom
        var headers: [String: String] = [:]
        let referer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorization = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !referer.isEmpty { headers["Referer"] = referer }
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        if !authorization.isEmpty { headers["Authorization"] = authorization }
        if !userAgent.isEmpty { headers["User-Agent"] = userAgent }
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
                destination: destination,
                headers: headers.isEmpty ? nil : headers
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
