import Foundation

/// One parsed feed entry (RSS 2.0 `<item>` or Atom `<entry>`).
public struct RSSItem: Equatable, Sendable {
    /// Stable identity: guid/id, else the link.
    public var id: String
    public var title: String
    /// Page URL (alternate link).
    public var link: String
    /// Podcast-style media enclosure, when the feed provides one.
    public var enclosureURL: String?
    public var enclosureType: String?
    public var publishedAt: Date?

    public init(
        id: String,
        title: String,
        link: String,
        enclosureURL: String? = nil,
        enclosureType: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.link = link
        self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType
        self.publishedAt = publishedAt
    }
}

/// One RSS/Atom subscription. New items are polled on a timer; matching
/// items are handed to the download engines (enclosures go to the direct
/// engine, page links to yt-dlp).
public struct RSSFeed: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var url: String
    /// Last-known feed title (falls back to the host while unchecked).
    public var title: String
    public var isEnabled: Bool
    /// Enqueue new matching items automatically. Off = items are still
    /// marked seen (manual review isn't implemented yet).
    public var autoDownload: Bool
    /// Only the single newest matching item per check.
    public var latestOnly: Bool
    /// Comma-separated keywords; empty = every item matches. An item
    /// matches when its title contains any keyword (case-insensitive).
    public var keywordFilter: String
    /// Safety cap: at most this many items enqueued per check.
    public var maxItemsPerCheck: Int
    public var lastCheckedAt: Date?
    public var lastError: String?
    /// Item ids already handled — new ones are what gets downloaded.
    public var seenItemIDs: [String]

    public init(
        id: UUID = UUID(),
        url: String = "",
        title: String = "",
        isEnabled: Bool = true,
        autoDownload: Bool = true,
        latestOnly: Bool = false,
        keywordFilter: String = "",
        maxItemsPerCheck: Int = 5,
        lastCheckedAt: Date? = nil,
        lastError: String? = nil,
        seenItemIDs: [String] = []
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.isEnabled = isEnabled
        self.autoDownload = autoDownload
        self.latestOnly = latestOnly
        self.keywordFilter = keywordFilter
        self.maxItemsPerCheck = maxItemsPerCheck
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.seenItemIDs = seenItemIDs
    }

    /// Display name: the feed's own title once fetched, else the host.
    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let host = URL(string: url)?.host, !host.isEmpty {
            return host
        }
        return url
    }

    // MARK: - Item filtering

    /// New, matching items in feed order. `isFirstCheck` marks the whole
    /// current feed as seen without enqueueing anything — adding a
    /// subscription must not download the entire back catalogue.
    public static func newItems(
        from items: [RSSItem], feed: RSSFeed, isFirstCheck: Bool
    ) -> [RSSItem] {
        guard !isFirstCheck else { return [] }
        let seen = Set(feed.seenItemIDs)
        let keywords = feed.keywordFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var fresh = items.filter { !seen.contains($0.id) }
        if !keywords.isEmpty {
            fresh = fresh.filter { item in
                let haystack = item.title.lowercased()
                return keywords.contains { haystack.contains($0) }
            }
        }
        if feed.latestOnly, let newest = fresh.max(by: { lhs, rhs in
            (lhs.publishedAt ?? .distantPast) < (rhs.publishedAt ?? .distantPast)
        }) {
            fresh = [newest]
        }
        let cap = max(1, feed.maxItemsPerCheck)
        return Array(fresh.prefix(cap))
    }

    /// Ids to remember after a check (capped so the list cannot grow
    /// unbounded across years of episodes).
    public static func mergedSeenIDs(
        existing: [String], checked: [RSSItem], cap: Int = 500
    ) -> [String] {
        var merged = existing
        for item in checked where !merged.contains(item.id) {
            merged.append(item.id)
        }
        if merged.count > cap {
            merged.removeFirst(merged.count - cap)
        }
        return merged
    }
}
