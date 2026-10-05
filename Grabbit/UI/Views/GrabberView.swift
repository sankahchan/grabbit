import SwiftUI
import AppKit

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
/// The native-messaging host runs as a separate `--native-messaging`
/// process (the browser launches it), so the main app can't observe a live
/// handshake. Instead the status card reflects whether the host manifest is
/// installed for any supported browser (what `install-host.sh` sets up) —
/// a truthful "the extension can reach Grabbit" signal. "Grab" enqueues
/// the media URL via `DownloadEngine.add(...)`.
struct GrabberView: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme

    /// True when the native-host manifest is installed for at least one
    /// supported browser. Refreshed whenever the tab appears / the app
    /// becomes active (the user installs the host outside the app).
    @State private var extensionConnected = false

    // Populated by the native-messaging host once it exists; empty for now.
    @State private var detected: [DetectedMedia] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NeoPageHeader(
                    sticker: NSLocalizedString("page.grabber.sticker", comment: ""),
                    title: NSLocalizedString("grabber.title", comment: ""),
                    accent: Neo.pink)
                statusStrip
                detectedCard
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .navigationTitle(NSLocalizedString("grabber.title", comment: ""))
        .onAppear { refreshConnectionStatus() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in refreshConnectionStatus() }
    }

    private func refreshConnectionStatus() {
        extensionConnected = Self.hostManifestInstalled()
    }

    /// The browser can reach Grabbit iff `install-host.sh` has placed our
    /// native-messaging manifest in one of the known browser dirs.
    private static func hostManifestInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/Mozilla/NativeMessagingHosts",
        ]
        return dirs.contains { dir in
            FileManager.default.fileExists(atPath:
                home.appendingPathComponent(
                    dir + "/com.sankahchan.grabbit.json").path)
        }
    }

    // MARK: - Status

    /// Extension update flow state (direct download + install).
    enum ExtensionUpdateState: Equatable {
        case idle
        case working
        case updated
        case saved(path: String)
        case failed(String)
    }

    @State private var updateState: ExtensionUpdateState = .idle

    /// One-click extension update: downloads the latest package straight
    /// from the GitHub release (no browsing) and installs it over the
    /// unpacked copy the browser loads; fresh installs are saved to
    /// ~/Downloads/Grabbit with the bundled install guide.
    private func runExtensionUpdate() {
        updateState = .working
        Task { @MainActor in
            do {
                let zip = try await ExtensionUpdater.downloadLatest()
                defer { try? FileManager.default.removeItem(at: zip) }
                let copies = ExtensionUpdater.findUnpackedCopies()
                if copies.isEmpty {
                    let base = try ExtensionUpdater.saveForManualInstall(zip: zip)
                    updateState = .saved(path: base.path)
                } else {
                    for copy in copies {
                        try ExtensionUpdater.install(zip: zip, into: copy.folder)
                    }
                    updateState = .updated
                }
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                NeoSpinner(size: 16)
                Text(NSLocalizedString("grabber.extension.working", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
            }
        case .updated:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("grabber.extension.updated", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Button(NSLocalizedString("grabber.extension.openExtensions", comment: "")) {
                    ExtensionUpdater.openExtensionsPage()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            }
        case .saved(let path):
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("grabber.extension.saved", comment: ""))
                    .font(NeoFont.f(.subheadline, .semibold))
                Button(NSLocalizedString("grabber.extension.openFolder", comment: "")) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)])
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            }
        case .failed(let message):
            Text("\(NSLocalizedString("grabber.extension.failed", comment: "")) \(message)")
                .font(NeoFont.f(.subheadline, .semibold))
                .foregroundStyle(Neo.red)
        }
    }

    private var statusColor: Color {
        extensionConnected ? Neo.green : Neo.red
    }

    /// Compact strip like the Torrents daemon / Media runtime rows: state
    /// dot, state name, and the one action that fits the state.
    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.8), radius: 3)
                Text(extensionConnected
                     ? NSLocalizedString("grabber.status.connected", comment: "")
                     : NSLocalizedString("grabber.status.disconnected", comment: ""))
                    .font(NeoFont.f(.caption, .semibold))
                    .foregroundStyle(Neo.ink(scheme))
                Spacer()
                Button(extensionConnected
                       ? NSLocalizedString("grabber.updateExtension", comment: "")
                       : NSLocalizedString("grabber.getExtension", comment: "")) {
                    runExtensionUpdate()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                .disabled(updateState == .working)
            }
            updateStatusView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: statusColor, inset: 10)
    }

    // MARK: - Detected media

    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("grabber.detected.title", comment: ""))
                .font(NeoFont.f(.headline, .heavy))
                .textCase(.uppercase)

            if detected.isEmpty {
                Text(NSLocalizedString("grabber.detected.empty", comment: ""))
                    .font(NeoFont.f(.subheadline))
                    .foregroundStyle(Neo.ink2(scheme))
                if !extensionConnected {
                    // The only place the install hint belongs: no host yet.
                    Text(NSLocalizedString("grabber.hint", comment: ""))
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(detected) { media in
                    detectedRow(for: media)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.purple)
    }

    private func detectedRow(for media: DetectedMedia) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(NeoFont.f(.subheadline, .semibold))
                    .lineLimit(1)
                SourceBadge(site: media.site)
            }
            Spacer()
            Button(NSLocalizedString("grabber.grab", comment: "")) {
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
}
