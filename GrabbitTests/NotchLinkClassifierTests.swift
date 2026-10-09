import XCTest
@testable import Grabbit

final class NotchLinkClassifierTests: XCTestCase {

    func testClassifyMagnet() {
        let magnet = "magnet:?xt=urn:btih:ABC123&dn=Movie"
        XCTAssertEqual(
            NotchLinkClassifier.classify(droppedText: magnet),
            .magnet(magnet))
    }

    func testClassifyTorrentURL() {
        let url = URL(string: "https://nyaa.si/download/123.torrent")!
        XCTAssertEqual(
            NotchLinkClassifier.classify(url: url), .torrentURL(url))
    }

    func testClassifyMediaHosts() {
        let cases: [(String, SourceSite)] = [
            ("https://youtube.com/watch?v=x", .youtube),
            ("https://youtu.be/x", .youtube),
            ("https://www.youtube.com/watch?v=x", .youtube),
            ("https://x.com/user/status/1", .x),
            ("https://twitter.com/user/status/1", .x),
            ("https://t.co/abc", .x),
            ("https://tiktok.com/@u/video/1", .tiktok),
            ("https://instagram.com/reel/x", .instagram),
            ("https://t.me/channel/123", .telegram),
        ]
        for (text, site) in cases {
            guard case .mediaPage(let url, let detected) =
                NotchLinkClassifier.classify(droppedText: text)
            else {
                XCTFail("expected mediaPage for \(text)")
                continue
            }
            XCTAssertEqual(url.absoluteString, text)
            XCTAssertEqual(detected, site, text)
        }
    }

    func testClassifyDirectDownload() {
        let url = URL(string: "https://cdn.example.com/movie.mp4")!
        XCTAssertEqual(NotchLinkClassifier.classify(url: url), .direct(url))
    }

    func testClassifyTextExtractsFirstURL() {
        guard case .direct(let url) = NotchLinkClassifier.classify(
            droppedText: "check this out https://example.com/file.zip thanks")
        else {
            XCTFail("expected direct")
            return
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/file.zip")
    }

    func testClassifyInvalid() {
        XCTAssertEqual(
            NotchLinkClassifier.classify(droppedText: "hello world"),
            .invalid)
        XCTAssertEqual(
            NotchLinkClassifier.classify(droppedText: ""),
            .invalid)
        XCTAssertEqual(
            NotchLinkClassifier.classify(url: URL(string: "ftp://x/y")!),
            .invalid)
    }

    func testClassifyDroppedFiles() {
        let torrent = URL(fileURLWithPath: "/tmp/thing.torrent")
        XCTAssertEqual(
            NotchLinkClassifier.classify(droppedFileURL: torrent),
            .torrentFile(torrent))
        XCTAssertEqual(
            NotchLinkClassifier.classify(
                droppedFileURL: URL(fileURLWithPath: "/tmp/movie.mp4")),
            .invalid)
    }
}
