import Foundation

/// A named download queue with its own concurrency limit (Persepolis-style).
///
/// Queues only govern the direct-download engine. The global
/// `maxActiveTasks` setting remains the overall ceiling across all queues;
/// a queue's `maxConcurrent` caps how many of *its* tasks run at once.
/// The default queue always exists and can't be deleted; tasks whose queue
/// was deleted fall back to it.
public struct DownloadQueue: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    /// Display name. Empty for the default queue — its name is localized
    /// at display time so it follows language switches.
    public var name: String
    public var maxConcurrent: Int
    public var isDefault: Bool = false
    public var createdAt: Date = Date()

    public init(
        id: UUID = UUID(),
        name: String = "",
        maxConcurrent: Int = 3,
        isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.maxConcurrent = maxConcurrent
        self.isDefault = isDefault
        self.createdAt = createdAt
    }

    /// Language-current display name.
    public var displayName: String {
        isDefault ? NSLocalizedString("queue.default", comment: "") : name
    }
}
