import Foundation

public enum TorrentState: String, Codable, CaseIterable {
    case downloading
    case seeding
    case paused
    case completed
    case failed

    /// Static-key lookup — see DownloadState.localizedName.
    public var localizedName: String {
        switch self {
        case .downloading: String(localized: "state.downloading")
        case .seeding: String(localized: "state.seeding")
        case .paused: String(localized: "state.paused")
        case .completed: String(localized: "state.completed")
        case .failed: String(localized: "state.failed")
        }
    }
}

public struct TorrentItem: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var magnetURI: String
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var seeds: Int
    public var peers: Int
    public var ratio: Double
    public var state: TorrentState
    public var savePath: URL
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        magnetURI: String,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        seeds: Int = 0,
        peers: Int = 0,
        ratio: Double = 0,
        state: TorrentState = .paused,
        savePath: URL,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.magnetURI = magnetURI
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.seeds = seeds
        self.peers = peers
        self.ratio = ratio
        self.state = state
        self.savePath = savePath
        self.addedAt = addedAt
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}
