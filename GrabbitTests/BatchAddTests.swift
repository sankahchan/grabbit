import XCTest
@testable import Grabbit

/// Phase 5 batch add: multi-link parsing.
final class BatchAddTests: XCTestCase {

    func testParsesOneURLPerLine() {
        let text = """
        https://example.com/a.zip
        https://example.com/b.zip
        """
        let urls = BatchLinkParser.parse(text)
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://example.com/a.zip", "https://example.com/b.zip"])
    }

    func testSkipsBlankAndInvalidLines() {
        let text = """
        https://example.com/a.zip

        not a url
        ftp://example.com/c.zip
        https://
           https://example.com/d.zip   
        """
        let urls = BatchLinkParser.parse(text)
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://example.com/a.zip", "https://example.com/d.zip"])
        XCTAssertEqual(BatchLinkParser.invalidCount(in: text, parsed: urls), 3)
    }

    func testDeduplicates() {
        let text = """
        https://example.com/a.zip
        https://example.com/a.zip
        https://example.com/b.zip
        """
        XCTAssertEqual(BatchLinkParser.parse(text).count, 2)
    }

    func testEmptyText() {
        XCTAssertTrue(BatchLinkParser.parse("").isEmpty)
        XCTAssertTrue(BatchLinkParser.parse("   \n  \n").isEmpty)
    }
}
