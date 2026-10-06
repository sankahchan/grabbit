import XCTest
import Foundation
@testable import Grabbit

/// RSS: feed parsing (RSS 2.0 + Atom), new-item filtering, and store
/// persistence.
final class RSSFeedTests: XCTestCase {
    // MARK: - Parser

    private let rssXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example Podcast</title>
        <item>
          <title>Episode 12 — Waterfront</title>
          <link>https://example.com/ep12</link>
          <guid>ep-12</guid>
          <pubDate>Mon, 22 Sep 2026 10:00:00 +0000</pubDate>
          <enclosure url="https://cdn.example.com/ep12.mp3" type="audio/mpeg" length="123"/>
        </item>
        <item>
          <title>Episode 11 — Encore</title>
          <link>https://example.com/ep11</link>
          <guid>ep-11</guid>
        </item>
      </channel>
    </rss>
    """

    private let atomXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Example Channel</title>
      <entry>
        <title>Live set</title>
        <link rel="alternate" href="https://example.com/live"/>
        <link rel="enclosure" href="https://cdn.example.com/live.mp4" type="video/mp4"/>
        <id>yt:video:abc123</id>
        <updated>2026-09-23T12:30:00Z</updated>
      </entry>
    </feed>
    """

    func testParsesRSSItems() {
        let result = RSSFeedParser.parse(data: Data(rssXML.utf8))
        XCTAssertEqual(result.title, "Example Podcast")
        XCTAssertEqual(result.items.count, 2)
        let first = result.items[0]
        XCTAssertEqual(first.id, "ep-12")
        XCTAssertEqual(first.title, "Episode 12 — Waterfront")
        XCTAssertEqual(first.link, "https://example.com/ep12")
        XCTAssertEqual(first.enclosureURL, "https://cdn.example.com/ep12.mp3")
        XCTAssertEqual(first.enclosureType, "audio/mpeg")
        XCTAssertNotNil(first.publishedAt)
        XCTAssertNil(result.items[1].enclosureURL)
    }

    func testParsesAtomEntries() {
        let result = RSSFeedParser.parse(data: Data(atomXML.utf8))
        XCTAssertEqual(result.title, "Example Channel")
        XCTAssertEqual(result.items.count, 1)
        let entry = result.items[0]
        XCTAssertEqual(entry.id, "yt:video:abc123")
        XCTAssertEqual(entry.link, "https://example.com/live")
        XCTAssertEqual(entry.enclosureURL, "https://cdn.example.com/live.mp4")
        XCTAssertNotNil(entry.publishedAt)
    }

    // MARK: - Filtering

    private func item(
        _ id: String, _ title: String, at date: Date? = nil
    ) -> RSSItem {
        RSSItem(
            id: id, title: title,
            link: "https://example.com/\(id)", publishedAt: date)
    }

    func testFirstCheckNeverDownloads() {
        let items = [item("a", "One"), item("b", "Two")]
        XCTAssertTrue(RSSFeed.newItems(
            from: items, feed: RSSFeed(), isFirstCheck: true).isEmpty)
    }

    func testSeenItemsAreSkipped() {
        var feed = RSSFeed()
        feed.seenItemIDs = ["a"]
        let fresh = RSSFeed.newItems(
            from: [item("a", "One"), item("b", "Two")],
            feed: feed, isFirstCheck: false)
        XCTAssertEqual(fresh.map(\.id), ["b"])
    }

    func testKeywordFilter() {
        var feed = RSSFeed()
        feed.keywordFilter = "live, encore"
        let fresh = RSSFeed.newItems(
            from: [
                item("a", "Studio session"),
                item("b", "Live at the Waterfront"),
                item("c", "Encore!"),
            ],
            feed: feed, isFirstCheck: false)
        XCTAssertEqual(fresh.map(\.id), ["b", "c"])
    }

    func testLatestOnlyKeepsNewest() {
        var feed = RSSFeed()
        feed.latestOnly = true
        let older = item("a", "Old", at: Date(timeIntervalSince1970: 100))
        let newer = item("b", "New", at: Date(timeIntervalSince1970: 200))
        let undated = item("c", "Undated")
        let fresh = RSSFeed.newItems(
            from: [older, newer, undated], feed: feed, isFirstCheck: false)
        XCTAssertEqual(fresh.map(\.id), ["b"])
    }

    func testPerCheckCap() {
        var feed = RSSFeed()
        feed.maxItemsPerCheck = 2
        let items = (1...5).map { item("\($0)", "Item \($0)") }
        XCTAssertEqual(
            RSSFeed.newItems(from: items, feed: feed, isFirstCheck: false).count, 2)
    }

    func testMergedSeenIDsIsCapped() {
        let items = (1...10).map { item("\($0)", "Item \($0)") }
        let merged = RSSFeed.mergedSeenIDs(
            existing: ["old-1", "old-2"], checked: items, cap: 5)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(Array(merged.suffix(4)), ["7", "8", "9", "10"])
        XCTAssertFalse(merged.contains("old-2"))
    }

    // MARK: - Store

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-rss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RSSStore(directory: dir)
        XCTAssertTrue(store.feeds.isEmpty)
        let feed = try XCTUnwrap(store.add(url: "https://example.com/feed.xml"))
        XCTAssertNil(store.add(url: "https://example.com/feed.xml")) // duplicate
        XCTAssertEqual(store.feeds.count, 1)

        var updated = feed
        updated.title = "Example"
        updated.keywordFilter = "live"
        store.update(updated)

        let reloaded = RSSStore(directory: dir)
        XCTAssertEqual(reloaded.feeds.first?.title, "Example")
        XCTAssertEqual(reloaded.feeds.first?.keywordFilter, "live")

        store.remove(id: feed.id)
        XCTAssertTrue(RSSStore(directory: dir).feeds.isEmpty)
    }

    // MARK: - Torrent routing classifier

    func testTorrentClassifierMatchesTorznabAndNyaaAndMagnet() {
        // Jackett/Prowlarr torznab enclosures: no .torrent suffix, but the
        // bittorrent MIME marks them.
        XCTAssertTrue(RSSMonitor.isTorrentItem(
            enclosureType: "application/x-bittorrent",
            url: URL(string: "http://localhost:9117/dl/1337x/?path=abc&file=show.1080p")!))
        // Nyaa-style .torrent link.
        XCTAssertTrue(RSSMonitor.isTorrentItem(
            enclosureType: nil,
            url: URL(string: "https://nyaa.si/download/123.torrent")!))
        // Magnet links.
        XCTAssertTrue(RSSMonitor.isTorrentItem(
            enclosureType: nil,
            url: URL(string: "magnet:?xt=urn:btih:abc")!))
    }

    func testTorrentClassifierRejectsPodcastsAndPages() {
        XCTAssertFalse(RSSMonitor.isTorrentItem(
            enclosureType: "audio/mpeg",
            url: URL(string: "https://example.com/episode-01.mp3")!))
        XCTAssertFalse(RSSMonitor.isTorrentItem(
            enclosureType: nil,
            url: URL(string: "https://youtube.com/watch?v=abc")!))
        XCTAssertFalse(RSSMonitor.isTorrentItem(
            enclosureType: "video/mp4",
            url: URL(string: "https://example.com/movie.torrent.mp4")!))
    }
}
