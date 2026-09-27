import SwiftUI

/// A piece of media the browser extension has spotted on a page.
struct DetectedMedia: Identifiable {
    let id = UUID()
    var title: String
    var site: SourceSite
    /// Direct media URL reported by the extension (may be a blob: URL for
    /// Telegram Web videos — the extension streams those bytes to the host).
    var mediaURL: URL
    /// Page where the media was found.
    var pageURL: URL
}

/// Grabber tab: browser-extension connection status, detected media list,
/// and an install hint.
///
/// Real data flow (future work): browser extension -> native-messaging host ->
/// app publishes detected media into this list. "Grab" enqueues the media URL
/// via `DownloadEngine.add(...)`. The `@State` flags below are placeholders
/// until `NativeMessagingHost` lands.
struct GrabberView: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    // TODO: set to true once NativeMessagingHost completes its hello handshake
    // with the browser extension.
    @State private var extensionConnected = false

    // Populated by the native-messaging host once it exists; empty for now.
    @State private var detected: [DetectedMedia] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                detectedCard
                hintCard
            }
            .padding(16)
        }
        .navigationTitle(String(localized: "grabber.title"))
    }

    // MARK: - Status

    private var statusCard: some View {
        let bg = extensionConnected ? Neo.green : Neo.paper(scheme)
        return HStack(spacing: 10) {
            Circle()
                .fill(extensionConnected ? Neo.green : Neo.red)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Neo.ink(scheme), lineWidth: 2))
            Text(extensionConnected
                 ? String(localized: "grabber.status.connected")
                 : String(localized: "grabber.status.disconnected"))
                .font(.headline.weight(.bold))
            Spacer()
        }
        .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
        .neoCard(bg: bg)
    }

    // MARK: - Detected media

    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "grabber.detected.title"))
                .font(.headline.weight(.heavy))
                .textCase(.uppercase)

            if detected.isEmpty {
                Text(String(localized: "grabber.detected.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detected) { media in
                    detectedRow(for: media)
                }
            }
        }
        .neoCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detectedRow(for media: DetectedMedia) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                SourceBadge(site: media.site)
            }
            Spacer()
            Button(String(localized: "grabber.grab")) {
                grab(media)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
        }
        .padding(8)
        .background(Neo.paper(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: 2)
        )
    }

    private func grab(_ media: DetectedMedia) {
        let engine = engine
        let destination = settings.folderURL(for: .video)
        Task {
            await engine.add(
                url: media.mediaURL,
                filename: media.title,
                category: .video,
                sourceSite: media.site,
                destination: destination
            )
        }
    }

    // MARK: - Hint

    private var hintCard: some View {
        Text(String(localized: "grabber.hint"))
            .font(.subheadline)
            .foregroundStyle(Neo.onAccent(Neo.yellow, scheme: scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .neoCard(bg: Neo.yellow)
    }
}
