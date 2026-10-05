import Foundation

/// A user-added Torznab-compatible indexer: Jackett, Prowlarr, or any
/// service exposing the Torznab API. The API key lives in the Keychain
/// (per indexer id), never in settings.json.
public struct TorznabIndexer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Display name shown in the search-source menu.
    public var name: String
    /// The indexer's Torznab endpoint, e.g.
    /// "http://localhost:9117/api/v2.0/indexers/all/results/torznab".
    public var urlString: String

    public init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }
}

/// Keychain storage for per-indexer API keys. Keys never touch settings.
enum TorznabVault {
    static func account(for id: UUID) -> String {
        "torznab.\(id.uuidString)"
    }

    @discardableResult
    static func saveKey(_ key: String, for id: UUID) -> Bool {
        KeychainStore.save(key, account: account(for: id))
    }

    static func loadKey(for id: UUID) -> String? {
        guard case .success(let value) = KeychainStore.load(
            account: account(for: id))
        else { return nil }
        return value.isEmpty ? nil : value
    }

    static func deleteKey(for id: UUID) {
        KeychainStore.delete(account: account(for: id))
    }
}
