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
        case .downloading: NSLocalizedString("state.downloading", comment: "")
        case .seeding: NSLocalizedString("state.seeding", comment: "")
        case .paused: NSLocalizedString("state.paused", comment: "")
        case .completed: NSLocalizedString("state.completed", comment: "")
        case .failed: NSLocalizedString("state.failed", comment: "")
        }
    }
}

/// Display-level torrent status. Pure — unit-tested.
///
/// Distinguishes "waiting for metadata" (a magnet whose info hasn't
/// resolved yet) and "connecting" (no peers/seeders yet) from plain
/// downloading, so a stuck-looking torrent explains itself instead of
/// looking merely paused.
public enum TorrentDisplayStatus: Equatable {
    case downloading
    case waitingForMetadata
    case connecting
    case seeding
    case paused
    case completed
    case failed

    public static func of(_ item: TorrentItem) -> TorrentDisplayStatus {
        switch item.state {
        case .downloading:
            if !item.magnetURI.isEmpty, item.totalBytes == 0 {
                return .waitingForMetadata
            }
            if item.numSeeders == 0, item.peers == 0 {
                return .connecting
            }
            return .downloading
        case .seeding: return .seeding
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    public var localizedName: String {
        switch self {
        case .downloading: NSLocalizedString("state.downloading", comment: "")
        case .waitingForMetadata: NSLocalizedString("torrents.status.waitingMetadata", comment: "")
        case .connecting: NSLocalizedString("torrents.status.connecting", comment: "")
        case .seeding: NSLocalizedString("state.seeding", comment: "")
        case .paused: NSLocalizedString("state.paused", comment: "")
        case .completed: NSLocalizedString("state.completed", comment: "")
        case .failed: NSLocalizedString("state.failed", comment: "")
        }
    }
}

public struct TorrentItem: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var magnetURI: String
    /// Original add source (magnet, http(s) URL, or "" for .torrent files) —
    /// used to re-add the torrent if the daemon lost it.
    public var sourceURI: String
    /// aria2 GID of the live download. Migrates when a magnet resolves
    /// (see `GidLineage`).
    public var gid: String?
    /// Lowercased hex info hash — lets us re-adopt a daemon-side torrent
    /// whose GID changed across restarts.
    public var infoHash: String?
    /// Base64 of the original .torrent (file-based adds only, < 2 MB) so a
    /// lost daemon entry can be re-added without the file.
    public var torrentFileBase64: String?
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var seeds: Int
    public var peers: Int
    public var numSeeders: Int
    public var connections: Int
    public var ratio: Double
    public var state: TorrentState
    public var errorMessage: String?
    /// Per-torrent seeding overrides; nil = use the global defaults.
    public var seedRatio: Double?
    public var seedTimeMinutes: Int?
    public var savePath: URL
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        magnetURI: String,
        sourceURI: String = "",
        gid: String? = nil,
        infoHash: String? = nil,
        torrentFileBase64: String? = nil,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        uploadedBytes: Int64 = 0,
        downloadSpeed: Int64 = 0,
        uploadSpeed: Int64 = 0,
        seeds: Int = 0,
        peers: Int = 0,
        numSeeders: Int = 0,
        connections: Int = 0,
        ratio: Double = 0,
        state: TorrentState = .paused,
        errorMessage: String? = nil,
        seedRatio: Double? = nil,
        seedTimeMinutes: Int? = nil,
        savePath: URL,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.magnetURI = magnetURI
        self.sourceURI = sourceURI
        self.gid = gid
        self.infoHash = infoHash
        self.torrentFileBase64 = torrentFileBase64
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
        self.seeds = seeds
        self.peers = peers
        self.numSeeders = numSeeders
        self.connections = connections
        self.ratio = ratio
        self.state = state
        self.errorMessage = errorMessage
        self.seedRatio = seedRatio
        self.seedTimeMinutes = seedTimeMinutes
        self.savePath = savePath
        self.addedAt = addedAt
    }

    // Backward-compatible decoding: torrents persisted before these fields
    // existed still decode, with the new fields defaulted.
    private enum CodingKeys: String, CodingKey {
        case id, name, magnetURI, sourceURI, gid, infoHash, torrentFileBase64
        case totalBytes, downloadedBytes, uploadedBytes, downloadSpeed, uploadSpeed
        case seeds, peers, numSeeders, connections, ratio, state, errorMessage
        case seedRatio, seedTimeMinutes, savePath, addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        magnetURI = try c.decodeIfPresent(String.self, forKey: .magnetURI) ?? ""
        sourceURI = try c.decodeIfPresent(String.self, forKey: .sourceURI) ?? ""
        gid = try c.decodeIfPresent(String.self, forKey: .gid)
        infoHash = try c.decodeIfPresent(String.self, forKey: .infoHash)
        torrentFileBase64 = try c.decodeIfPresent(String.self, forKey: .torrentFileBase64)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        uploadedBytes = try c.decodeIfPresent(Int64.self, forKey: .uploadedBytes) ?? 0
        downloadSpeed = try c.decodeIfPresent(Int64.self, forKey: .downloadSpeed) ?? 0
        uploadSpeed = try c.decodeIfPresent(Int64.self, forKey: .uploadSpeed) ?? 0
        seeds = try c.decodeIfPresent(Int.self, forKey: .seeds) ?? 0
        peers = try c.decodeIfPresent(Int.self, forKey: .peers) ?? 0
        numSeeders = try c.decodeIfPresent(Int.self, forKey: .numSeeders) ?? 0
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? 0
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0
        state = try c.decodeIfPresent(TorrentState.self, forKey: .state) ?? .paused
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        seedRatio = try c.decodeIfPresent(Double.self, forKey: .seedRatio)
        seedTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .seedTimeMinutes)
        savePath = try c.decodeIfPresent(URL.self, forKey: .savePath)
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}
