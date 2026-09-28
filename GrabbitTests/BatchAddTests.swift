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
        let detailed = BatchLinkParser.parseDetailed(text)
        XCTAssertEqual(detailed.invalidCount, 3)
        XCTAssertEqual(detailed.duplicateCount, 0)
    }

    func testDeduplicates() {
        let text = """
        https://example.com/a.zip
        https://example.com/a.zip
        https://example.com/b.zip
        """
        XCTAssertEqual(BatchLinkParser.parse(text).count, 2)
    }

    func testDeduplicatesNormalizedURLs() {
        // Distinct raw lines normalizing to one absoluteString (a literal
        // space is percent-encoded by Foundation) collapse to a single row,
        // matching the per-link customization keys.
        let text = """
        https://example.com/a b.zip
        https://example.com/a%20b.zip
        """
        let urls = BatchLinkParser.parse(text)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/a%20b.zip")
    }

    func testEmptyText() {
        XCTAssertTrue(BatchLinkParser.parse("").isEmpty)
        XCTAssertTrue(BatchLinkParser.parse("   \n  \n").isEmpty)
    }

    // MARK: - Canonical dedup (URL+Canonical)

    func testDedupKeyNormalizesSchemeAndHostCase() {
        let a = URL(string: "HTTPS://EXAMPLE.COM/a.zip")!
        let b = URL(string: "https://example.com/a.zip")!
        XCTAssertEqual(a.dedupKey, b.dedupKey)
    }

    func testDedupKeyDropsDefaultPorts() {
        let a = URL(string: "https://example.com:443/a.zip")!
        let b = URL(string: "https://example.com/a.zip")!
        let c = URL(string: "http://example.com:8080/a.zip")!
        XCTAssertEqual(a.dedupKey, b.dedupKey)
        XCTAssertNotEqual(c.dedupKey, b.dedupKey)
    }

    func testDedupKeyDropsFragmentAndEmptyQuery() {
        let base = URL(string: "https://example.com/a.zip")!
        let frag = URL(string: "https://example.com/a.zip#section")!
        let emptyQ = URL(string: "https://example.com/a.zip?")!
        let realQ = URL(string: "https://example.com/a.zip?dl=1")!
        XCTAssertEqual(frag.dedupKey, base.dedupKey)
        XCTAssertEqual(emptyQ.dedupKey, base.dedupKey)
        XCTAssertNotEqual(realQ.dedupKey, base.dedupKey)
    }

    func testDedupKeyPreservesPathCase() {
        let a = URL(string: "https://example.com/A.zip")!
        let b = URL(string: "https://example.com/a.zip")!
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
    }

    func testBatchParserDedupsCanonicalVariants() {
        let text = """
        HTTPS://EXAMPLE.COM/a.zip
        https://example.com:443/a.zip
        https://example.com/a.zip#dl
        https://example.com/b.zip
        """
        let urls = BatchLinkParser.parse(text)
        XCTAssertEqual(urls.count, 2)
    }

    func testParseDetailedSplitsDuplicatesAndInvalid() {
        let text = """
        https://example.com/a.zip
        HTTPS://EXAMPLE.COM/a.zip
        not a url
        https://example.com/b.zip
        """
        let r = BatchLinkParser.parseDetailed(text)
        XCTAssertEqual(r.urls.count, 2)
        XCTAssertEqual(r.duplicateCount, 1)
        XCTAssertEqual(r.invalidCount, 1)
    }
}
