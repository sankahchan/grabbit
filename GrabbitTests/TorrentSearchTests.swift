import XCTest
@testable import Grabbit

final class TorrentSearchTests: XCTestCase {

    // MARK: - HTMLEntities

    func testEntityDecodeNamedNumericAndPassthrough() {
        XCTAssertEqual(HTMLEntities.decode("Fun &amp; Games"), "Fun & Games")
        XCTAssertEqual(HTMLEntities.decode("It&#39;s"), "It's")
        XCTAssertEqual(HTMLEntities.decode("A &#x26; B"), "A & B")
        XCTAssertEqual(HTMLEntities.decode("plain text"), "plain text")
        XCTAssertEqual(HTMLEntities.decode("bad &nope; entity"), "bad &nope; entity")
        XCTAssertEqual(HTMLEntities.decode("trailing &"), "trailing &")
    }

    // MARK: - HumanSize

    func testHumanSizeParsing() {
        XCTAssertEqual(HumanSize.parse("1.2 GiB"), Int64((1.2 * 1_073_741_824).rounded()))
        XCTAssertEqual(HumanSize.parse("700 MiB"), 700 * 1_048_576)
        XCTAssertEqual(HumanSize.parse("1.5 kB"), 1500)
        XCTAssertEqual(HumanSize.parse("12 B"), 12)
        XCTAssertEqual(HumanSize.parse("2 TB"), 2_000_000_000_000)
        XCTAssertNil(HumanSize.parse(""))
        XCTAssertNil(HumanSize.parse("not a size"))
        XCTAssertNil(HumanSize.parse("12 parsecs"))
    }

    // MARK: - MagnetLink

    func testMagnetBuildCarriesHashNameAndTrackers() throws {
        let hash = String(repeating: "a", count: 40)
        let magnet = try XCTUnwrap(MagnetLink.build(
            infoHash: hash, name: "Big Buck Bunny",
            trackers: ["udp://tracker.example:1337/announce"]))
        XCTAssertTrue(magnet.hasPrefix("magnet:?"))
        XCTAssertTrue(magnet.contains(hash))
        XCTAssertTrue(magnet.contains("dn=Big%20Buck%20Bunny"))
        XCTAssertTrue(magnet.contains("tr=udp://tracker.example:1337/announce"))
    }

    func testMagnetRejectsInvalidHashes() {
        XCTAssertNil(MagnetLink.build(infoHash: "xyz", name: "n", trackers: []))
        XCTAssertNil(MagnetLink.build(
            infoHash: String(repeating: "0", count: 40), name: "n", trackers: []))
        XCTAssertFalse(MagnetLink.isInfoHash("abc"))
        XCTAssertFalse(MagnetLink.isInfoHash(String(repeating: "g", count: 40)))
        XCTAssertTrue(MagnetLink.isInfoHash(String(repeating: "B", count: 40)))
    }

    // MARK: - apibay

    func testParseApibayFiltersSentinelAndDecodes() throws {
        let hash = String(repeating: "a", count: 40)
        let json = """
        [
          {"id":"123","name":"Big Buck Bunny 1080p &amp; More",
           "info_hash":"\(hash)","leechers":"12","seeders":"34",
           "num_files":"3","size":"734003200","username":"x",
           "added":"1","status":"vip","category":"200","imdb":""},
          {"id":"0","name":"No results returned",
           "info_hash":"0000000000000000000000000000000000000000",
           "leechers":"0","seeders":"0","num_files":"0","size":"0",
           "username":"","added":"0","status":"","category":"0","imdb":""}
        ]
        """
        let results = TorrentSearch.parseApibay(data: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.name, "Big Buck Bunny 1080p & More")
        XCTAssertEqual(result.sizeBytes, 734_003_200)
        XCTAssertEqual(result.seeders, 34)
        XCTAssertEqual(result.leechers, 12)
        XCTAssertEqual(result.provider, .apibay)
        XCTAssertEqual(result.id, hash)
        XCTAssertTrue(result.source.contains(hash))
    }

    func testParseApibayGarbageYieldsNoResults() {
        XCTAssertTrue(TorrentSearch.parseApibay(data: Data("not json".utf8)).isEmpty)
    }

    // MARK: - Nyaa

    func testParseNyaaBuildsMagnetAndFallsBackToTorrentLink() {
        let hash = String(repeating: "b", count: 40)
        let rss = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
        <channel><title>Nyaa</title>
        <item>
        <title>Show - 01 [1080p]</title>
        <link>https://nyaa.si/download/123.torrent</link>
        <guid isPermaLink="true">https://nyaa.si/view/123</guid>
        <pubDate>Mon, 05 Oct 2026 10:00:00 -0000</pubDate>
        <nyaa:seeders>120</nyaa:seeders>
        <nyaa:leechers>8</nyaa:leechers>
        <nyaa:downloads>1000</nyaa:downloads>
        <nyaa:infoHash>\(hash)</nyaa:infoHash>
        <nyaa:category>Anime</nyaa:category>
        <nyaa:size>1.2 GiB</nyaa:size>
        </item>
        <item>
        <title>No hash item</title>
        <link>https://nyaa.si/download/124.torrent</link>
        <nyaa:seeders>3</nyaa:seeders>
        <nyaa:leechers>1</nyaa:leechers>
        <nyaa:size>700 MiB</nyaa:size>
        </item>
        </channel></rss>
        """
        let results = TorrentSearch.parseNyaa(data: Data(rss.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "Show - 01 [1080p]")
        XCTAssertEqual(results[0].seeders, 120)
        XCTAssertEqual(results[0].leechers, 8)
        XCTAssertEqual(results[0].sizeBytes, Int64((1.2 * 1_073_741_824).rounded()))
        XCTAssertEqual(results[0].provider, .nyaa)
        XCTAssertEqual(results[0].id, hash)
        XCTAssertTrue(results[0].source.hasPrefix("magnet:?"))
        // No usable info hash: the .torrent link is handed over instead.
        XCTAssertEqual(
            results[1].source, "https://nyaa.si/download/124.torrent")
    }

    // MARK: - URL builders

    func testURLBuilders() throws {
        let apibay = try XCTUnwrap(TorrentSearch.apibayURL(query: "big bunny"))
        XCTAssertEqual(apibay.host, "apibay.org")
        let apibayQuery = try XCTUnwrap(apibay.query)
        XCTAssertTrue(apibayQuery.contains("big%20bunny")
            || apibayQuery.contains("big+bunny"))

        let nyaa = try XCTUnwrap(TorrentSearch.nyaaURL(query: "big bunny"))
        XCTAssertEqual(nyaa.host, "nyaa.si")
        let nyaaQuery = try XCTUnwrap(nyaa.query)
        XCTAssertTrue(nyaaQuery.contains("page=rss"))
        XCTAssertTrue(nyaaQuery.contains("q=big%20bunny")
            || nyaaQuery.contains("q=big+bunny"))
    }
}
