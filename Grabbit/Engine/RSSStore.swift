import Foundation
import Observation

/// Persisted list of RSS subscriptions (App Support/rssfeeds.json).
@Observable
public final class RSSStore {
    public private(set) var feeds: [RSSFeed] = []

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("rssfeeds.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([RSSFeed].self, from: data)
        {
            feeds = decoded
        }
    }

    /// Adds a subscription. Returns nil for an empty/duplicate URL.
    @discardableResult
    public func add(url: String) -> RSSFeed? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !feeds.contains(where: { $0.url == trimmed })
        else { return nil }
        let feed = RSSFeed(url: trimmed)
        feeds.append(feed)
        save()
        return feed
    }

    public func update(_ feed: RSSFeed) {
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[index] = feed
        save()
    }

    public func remove(id: UUID) {
        feeds.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
