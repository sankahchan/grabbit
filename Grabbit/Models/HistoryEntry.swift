import Foundation

/// Which engine produced a history entry.
public enum HistoryKind: String, Codable, CaseIterable, Sendable {
    case download
    case torrent
    case media

    /// SF Symbol used for the kind icon in the History tab.
    public var systemImage: String {
        switch self {
        case .download: "tray.and.arrow.down"
        case .torrent: "magnet"
        case .media: "play.rectangle"
        }
    }

    /// Localized filter-chip label. Static-key lookup (same pattern as
    /// `DownloadState.localizedName`).
    public var filterLabel: String {
        switch self {
        case .download: String(localized: "history.filter.downloads")
        case .torrent: String(localized: "history.filter.torrents")
        case .media: String(localized: "history.filter.media")
        }
    }
}

/// Terminal outcome of a finished task. Only these two are ever recorded —
/// user-cancelled or removed tasks are an explicit discard, not history.
public enum HistoryStatus: String, Codable, Sendable {
    case completed
    case failed

    /// Reuses the shared state strings so the badge reads identically to
    /// the task cards.
    public var localizedName: String {
        switch self {
        case .completed: String(localized: "state.completed")
        case .failed: String(localized: "state.failed")
        }
    }
}

/// One finished download task, persisted to history.json.
///
/// Privacy invariant: like `DownloadItem.CodingKeys`, this never carries
/// request headers, cookies, or any other secret — only the source URL the
/// user already sees in the UI.
public struct HistoryEntry: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: HistoryKind
    public var status: HistoryStatus
    public var totalBytes: Int64?
    /// Source URL (http/https) or magnet URI.
    public var sourceURL: String
    /// Full save path of the finished file, when known.
    public var savePath: String?
    public var finishedAt: Date
    /// Failure reason; only set when `status == .failed`.
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: HistoryKind,
        status: HistoryStatus,
        totalBytes: Int64? = nil,
        sourceURL: String,
        savePath: String? = nil,
        finishedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.totalBytes = totalBytes
        self.sourceURL = sourceURL
        self.savePath = savePath
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    /// Short source label for the row: host of an http(s) URL, "magnet"
    /// for magnets, the raw string otherwise.
    public var sourceHost: String {
        if sourceURL.hasPrefix("magnet:") {
            return String(localized: "history.source.magnet")
        }
        if let host = URL(string: sourceURL)?.host, !host.isEmpty {
            return host
        }
        return sourceURL
    }

    // MARK: - Mapping from live items

    static func from(download item: DownloadItem, status: HistoryStatus) -> HistoryEntry {
        HistoryEntry(
            id: item.id,
            name: item.filename,
            kind: .download,
            status: status,
            totalBytes: item.totalBytes,
            sourceURL: item.url.absoluteString,
            savePath: item.destinationURL.path,
            errorMessage: status == .failed ? item.errorMessage : nil)
    }

    static func from(torrent item: TorrentItem, status: HistoryStatus) -> HistoryEntry {
        let link = item.magnetURI.isEmpty ? item.sourceURI : item.magnetURI
        return HistoryEntry(
            id: item.id,
            name: item.name,
            kind: .torrent,
            status: status,
            totalBytes: item.totalBytes > 0 ? item.totalBytes : nil,
            sourceURL: link,
            savePath: nil,
            errorMessage: status == .failed ? item.errorMessage : nil)
    }

    static func media(
        name: String,
        sourceURL: String,
        saveDirectory: URL?,
        status: HistoryStatus,
        errorMessage: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            name: name,
            kind: .media,
            status: status,
            sourceURL: sourceURL,
            savePath: saveDirectory?.path,
            errorMessage: status == .failed ? errorMessage : nil)
    }
}
