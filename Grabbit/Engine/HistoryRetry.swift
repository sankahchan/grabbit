import Foundation

/// History re-download: pure request building and toast construction.
/// The view drives the engines; this unit is fully unit-testable, so the
/// retry feedback (started / failed toasts) is pinned by tests rather
/// than by tapping through the UI.
public enum HistoryRetry {

    public struct Request: Sendable {
        public let kind: HistoryKind
        public let sourceURL: String
        public let name: String
        /// Torrent save folder; downloads resolve their own destination.
        public let torrentSaveFolder: URL?
    }

    /// Retry parameters for a history entry, or nil when the entry cannot
    /// be retried directly: media goes through the Media tab's probe flow
    /// (the view copies the URL and jumps there), empty torrent sources
    /// and non-http(s) download sources are rejected.
    public static func request(
        for entry: HistoryEntry,
        torrentSaveFolder: URL
    ) -> Request? {
        switch entry.kind {
        case .download:
            guard URL(string: entry.sourceURL)?.scheme?.hasPrefix("http") == true
            else { return nil }
            return Request(
                kind: .download,
                sourceURL: entry.sourceURL,
                name: entry.name,
                torrentSaveFolder: nil)
        case .torrent:
            guard !entry.sourceURL.isEmpty else { return nil }
            return Request(
                kind: .torrent,
                sourceURL: entry.sourceURL,
                name: entry.name,
                torrentSaveFolder: torrentSaveFolder)
        case .media:
            return nil
        }
    }

    /// "It started" feedback: without this the user taps retry on the
    /// History tab and nothing visibly happens (the task lands in the
    /// Downloads / Torrents tab).
    public static func startedToast(for request: Request) -> AppToast {
        AppToast(
            kind: .info,
            source: request.kind.toastSource,
            title: NSLocalizedString("history.retry.started", comment: ""),
            message: request.name,
            taskID: nil)
    }

    /// Failure feedback: the entry name plus the engine's error, so a bad
    /// magnet or a down daemon never fails silently.
    public static func failedToast(for request: Request, error: Error) -> AppToast {
        AppToast(
            kind: .failed,
            source: request.kind.toastSource,
            title: NSLocalizedString("toast.failed.title", comment: ""),
            message: request.name + " — " + error.localizedDescription,
            taskID: nil)
    }
}

private extension HistoryKind {
    var toastSource: ToastSource {
        switch self {
        case .download: .download
        case .torrent: .torrent
        case .media: .download
        }
    }
}
