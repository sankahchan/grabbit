import XCTest
@testable import Grabbit

/// MediaFire share-page resolution + the HTML-content guards that stop
/// bogus "complete" downloads (the engine used to download the ~300KB
/// HTML share page, name it *.zip, and report success).
final class MediaFireTests: XCTestCase {
    func testIsSharePage() {
        XCTAssertTrue(MediaFireResolver.isSharePage(URL(
            string: "https://www.mediafire.com/file/gch55j616mzrvql/Crypto_Research_Tool.zip")!))
        XCTAssertTrue(MediaFireResolver.isSharePage(URL(
            string: "https://mediafire.com/file/abc/def.zip")!))
        // Direct file links are not share pages.
        XCTAssertFalse(MediaFireResolver.isSharePage(URL(
            string: "https://download1474.mediafire.com/abc/def.zip")!))
        XCTAssertFalse(MediaFireResolver.isSharePage(URL(
            string: "https://www.dropbox.com/s/abc/def.zip")!))
        XCTAssertFalse(MediaFireResolver.isSharePage(URL(
            string: "https://www.mediafire.com/")!))
    }

    func testExtractDirectURL() {
        let html = """
            <html><body>
            <a aria-label="Download file" \
            href="https://download1474.mediafire.com/abc123/gch55j616mzrvql/Crypto_Research_Tool.zip">\
            Download</a>
            </body></html>
            """
        XCTAssertEqual(
            MediaFireResolver.extractDirectURL(from: html),
            "https://download1474.mediafire.com/abc123/gch55j616mzrvql/Crypto_Research_Tool.zip")
        XCTAssertNil(
            MediaFireResolver.extractDirectURL(
                from: "<html><body>no link here</body></html>"))
    }

    func testIsHTMLPage() {
        XCTAssertTrue(DownloadEngine.isHTMLPage(
            contentType: "text/html; charset=utf-8", filename: "file.zip"))
        XCTAssertTrue(DownloadEngine.isHTMLPage(
            contentType: "text/html", filename: "movie.mp4"))
        // Real web pages are fine.
        XCTAssertFalse(DownloadEngine.isHTMLPage(
            contentType: "text/html", filename: "page.html"))
        XCTAssertFalse(DownloadEngine.isHTMLPage(
            contentType: "application/zip", filename: "file.zip"))
        XCTAssertFalse(DownloadEngine.isHTMLPage(
            contentType: nil, filename: "file.zip"))
    }

    func testFileLooksLikeHTML() throws {
        let dir = FileManager.default.temporaryDirectory

        let htmlURL = dir.appendingPathComponent(
            "grabbit-test-\(UUID().uuidString).zip")
        try "  \n<!DOCTYPE html><html><head></head></html>".write(
            to: htmlURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(DownloadEngine.fileLooksLikeHTML(htmlURL))
        try? FileManager.default.removeItem(at: htmlURL)

        // A real zip is never flagged.
        let zipURL = dir.appendingPathComponent(
            "grabbit-test-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: zipURL)
        XCTAssertFalse(DownloadEngine.fileLooksLikeHTML(zipURL))
        try? FileManager.default.removeItem(at: zipURL)

        // An actual .html download is never flagged.
        let pageURL = dir.appendingPathComponent(
            "grabbit-test-\(UUID().uuidString).html")
        try "<html></html>".write(to: pageURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(DownloadEngine.fileLooksLikeHTML(pageURL))
        try? FileManager.default.removeItem(at: pageURL)
    }
}
