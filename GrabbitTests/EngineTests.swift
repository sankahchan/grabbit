import XCTest
@testable import Grabbit

final class EngineTests: XCTestCase {

    // MARK: - DownloadItem.makeSegments

    func testMakeSegmentsEvenSplit() {
        let segments = DownloadItem.makeSegments(totalBytes: 1000, connections: 4)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.map(\.byteCount), [250, 250, 250, 250])
        XCTAssertEqual(segments.first?.startByte, 0)
        XCTAssertEqual(segments.last?.endByte, 999)
        // Contiguous, non-overlapping, in order.
        for (i, segment) in segments.enumerated() {
            XCTAssertEqual(segment.index, i)
            if i > 0 {
                XCTAssertEqual(segment.startByte, segments[i - 1].endByte + 1)
            }
        }
    }

    func testMakeSegmentsRemainderGoesToLastSegment() {
        let segments = DownloadItem.makeSegments(totalBytes: 1003, connections: 4)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.map(\.byteCount), [250, 250, 250, 253])
        XCTAssertEqual(segments.last?.endByte, 1002)
    }

    func testMakeSegmentsSingleConnection() {
        let segments = DownloadItem.makeSegments(totalBytes: 500, connections: 1)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startByte, 0)
        XCTAssertEqual(segments[0].endByte, 499)
    }

    func testMakeSegmentsOneByteFile() {
        // More connections than bytes: clamps to a single 1-byte segment.
        let segments = DownloadItem.makeSegments(totalBytes: 1, connections: 8)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].byteCount, 1)
        XCTAssertEqual(segments[0].startByte, 0)
        XCTAssertEqual(segments[0].endByte, 0)
    }

    func testMakeSegmentsEmptyFile() {
        XCTAssertTrue(DownloadItem.makeSegments(totalBytes: 0, connections: 4).isEmpty)
    }

    func testMakeSegmentsCoverFullRange() {
        for total in [Int64(1), 7, 100, 1023, 1_000_000] {
            for connections in [1, 2, 3, 8, 16] {
                let segments = DownloadItem.makeSegments(totalBytes: total, connections: connections)
                XCTAssertFalse(segments.isEmpty)
                XCTAssertEqual(segments.first?.startByte, 0)
                XCTAssertEqual(segments.last?.endByte, total - 1)
                XCTAssertEqual(segments.reduce(0) { $0 + $1.byteCount }, total)
            }
        }
    }

    // MARK: - Segment

    func testSegmentIsComplete() {
        var segment = Segment(index: 0, startByte: 0, endByte: 99, receivedBytes: 100)
        XCTAssertTrue(segment.isComplete)
        segment.receivedBytes = 99
        XCTAssertFalse(segment.isComplete)
        segment.receivedBytes = 0
        XCTAssertFalse(segment.isComplete)
    }

    func testSegmentByteCount() {
        XCTAssertEqual(Segment(index: 2, startByte: 200, endByte: 299).byteCount, 100)
        // Degenerate range never goes negative.
        XCTAssertEqual(Segment(index: 0, startByte: 50, endByte: 49).byteCount, 0)
    }

    // MARK: - DownloadItem.progress

    private func makeItem(
        totalBytes: Int64?,
        downloadedBytes: Int64,
        segments: [Segment] = []
    ) -> DownloadItem {
        DownloadItem(
            url: URL(string: "https://example.com/file.zip")!,
            filename: "file.zip",
            totalBytes: totalBytes,
            downloadedBytes: downloadedBytes,
            segments: segments,
            destinationURL: URL(fileURLWithPath: "/tmp/file.zip")
        )
    }

    func testProgressFromByteCounts() {
        XCTAssertEqual(makeItem(totalBytes: 1000, downloadedBytes: 250).progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(makeItem(totalBytes: 1000, downloadedBytes: 1000).progress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(makeItem(totalBytes: 1000, downloadedBytes: 0).progress, 0.0, accuracy: 0.0001)
    }

    func testProgressClampsAboveOne() {
        XCTAssertEqual(makeItem(totalBytes: 1000, downloadedBytes: 1500).progress, 1.0, accuracy: 0.0001)
    }

    func testProgressFallsBackToSegmentsWhenTotalUnknown() {
        let segments = [
            Segment(index: 0, startByte: 0, endByte: 99, receivedBytes: 50),
            Segment(index: 1, startByte: 100, endByte: 199, receivedBytes: 50),
        ]
        XCTAssertEqual(
            makeItem(totalBytes: nil, downloadedBytes: 100, segments: segments).progress,
            0.5,
            accuracy: 0.0001
        )
    }

    func testProgressIsZeroWithoutSizeInfo() {
        XCTAssertEqual(makeItem(totalBytes: nil, downloadedBytes: 0).progress, 0)
    }

    func testEtaSeconds() {
        var item = makeItem(totalBytes: 1000, downloadedBytes: 500)
        item.state = .downloading
        item.speedBytesPerSec = 100
        XCTAssertEqual(item.etaSeconds ?? -1, 5.0, accuracy: 0.0001)

        var paused = item
        paused.state = .paused
        XCTAssertNil(paused.etaSeconds)

        var stalled = item
        stalled.speedBytesPerSec = 0
        XCTAssertNil(stalled.etaSeconds)
    }

    // MARK: - ChunkedDecoder

    func testChunkedDecoderSingleFeed() {
        var decoder = ChunkedDecoder()
        let pieces = decoder.feed(Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(pieces.map { String(data: $0, encoding: .utf8) }, ["Wiki", "pedia"])
        XCTAssertTrue(decoder.isFinished)
    }

    func testChunkedDecoderSplitFeeds() {
        var decoder = ChunkedDecoder()
        var out: [Data] = []
        // Deliberately awkward splits: mid-size-line, mid-chunk, mid-terminator.
        for part in ["4\r\nWi", "ki\r\n5\r\npedi", "a\r\n0\r", "\n\r\n"] {
            out += decoder.feed(Data(part.utf8))
        }
        XCTAssertEqual(out.map { String(data: $0, encoding: .utf8) }, ["Wiki", "pedia"])
        XCTAssertTrue(decoder.isFinished)
    }

    func testChunkedDecoderIncompleteWaits() {
        var decoder = ChunkedDecoder()
        XCTAssertEqual(decoder.feed(Data("4\r\nWi".utf8)).count, 0)
        XCTAssertFalse(decoder.isFinished)
        let pieces = decoder.feed(Data("ki\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(pieces.map { String(data: $0, encoding: .utf8) }, ["Wiki"])
        XCTAssertTrue(decoder.isFinished)
    }

    func testChunkedDecoderWithTrailers() {
        var decoder = ChunkedDecoder()
        let pieces = decoder.feed(Data("3\r\nabc\r\n0\r\nX-Trailer: yes\r\n\r\n".utf8))
        XCTAssertEqual(pieces.map { String(data: $0, encoding: .utf8) }, ["abc"])
        XCTAssertTrue(decoder.isFinished)
    }

    func testChunkedDecoderSplitTerminator() {
        var decoder = ChunkedDecoder()
        var out: [Data] = []
        for part in ["2\r\nhi\r\n0\r\n", "\r\n"] {
            out += decoder.feed(Data(part.utf8))
        }
        XCTAssertEqual(out.map { String(data: $0, encoding: .utf8) }, ["hi"])
        XCTAssertTrue(decoder.isFinished)
    }

    // MARK: - ShareURLRewriter

    func testRewriteDropboxLink() {
        let rewritten = ShareURLRewriter.rewrite(URL(string: "https://www.dropbox.com/s/abc123/file.zip?dl=0")!)
        XCTAssertEqual(rewritten.absoluteString, "https://www.dropbox.com/s/abc123/file.zip?dl=1")
    }

    func testRewriteDropboxAddsDlParam() {
        let rewritten = ShareURLRewriter.rewrite(URL(string: "https://www.dropbox.com/s/abc123/file.zip")!)
        XCTAssertTrue(rewritten.absoluteString.contains("dl=1"))
    }

    func testRewriteGoogleDriveLink() {
        let rewritten = ShareURLRewriter.rewrite(URL(string: "https://drive.google.com/file/d/1ABCxyz/view?usp=sharing")!)
        XCTAssertEqual(rewritten.absoluteString, "https://drive.google.com/uc?id=1ABCxyz&export=download")
    }

    func testRewriteOneDriveLink() {
        let rewritten = ShareURLRewriter.rewrite(URL(string: "https://contoso.sharepoint.com/:u:/g/xyz?e=abc")!)
        XCTAssertTrue(rewritten.absoluteString.contains("download=1"))
    }

    func testRewriteLeavesPlainURLsAlone() {
        let url = URL(string: "https://example.com/file.zip")!
        XCTAssertEqual(ShareURLRewriter.rewrite(url), url)
    }

    // MARK: - SignedURLDetector

    func testDetectsAWSStyleSignedURL() {
        XCTAssertTrue(SignedURLDetector.isSigned(URL(
            string: "https://cdn.example.com/f.zip?X-Amz-Algorithm=AWS4&X-Amz-Signature=abc&X-Amz-Expires=3600")!))
    }

    func testDetectsAzureStyleSignedURL() {
        XCTAssertTrue(SignedURLDetector.isSigned(URL(
            string: "https://blob.example.com/f.zip?se=2026-01-01&sig=abc123")!))
    }

    func testPlainURLIsNotSigned() {
        XCTAssertFalse(SignedURLDetector.isSigned(URL(string: "https://example.com/file.zip?foo=bar")!))
    }

    func testNameParameterIsNotSigned() {
        // Naive substring matching on "e=" would false-positive here.
        XCTAssertFalse(SignedURLDetector.isSigned(URL(string: "https://example.com/file.zip?name=x")!))
    }

    // MARK: - growthSplitPoint

    func testGrowthSplitsLargestUntouchedSegment() {
        let mb: Int64 = 1_048_576
        let segments = [
            Segment(index: 0, startByte: 0, endByte: 100 * mb - 1, receivedBytes: 10 * mb), // started
            Segment(index: 1, startByte: 100 * mb, endByte: 200 * mb - 1), // 100 MiB untouched
            Segment(index: 2, startByte: 200 * mb, endByte: 250 * mb - 1), // 50 MiB untouched
        ]
        let split = DownloadItem.growthSplitPoint(segments: segments, maxConnections: 16, minSplitBytes: 8 * mb)
        XCTAssertEqual(split?.index, 1)
        XCTAssertEqual(split?.mid, 150 * mb)
    }

    func testGrowthSkipsSegmentsBelowMinSplit() {
        let mb: Int64 = 1_048_576
        let segments = [Segment(index: 0, startByte: 0, endByte: 4 * mb - 1)]
        XCTAssertNil(DownloadItem.growthSplitPoint(segments: segments, maxConnections: 16, minSplitBytes: 8 * mb))
    }

    func testGrowthStopsAtMaxConnections() {
        let mb: Int64 = 1_048_576
        let segments = (0..<16).map { i in
            Segment(index: i, startByte: Int64(i) * 100 * mb, endByte: Int64(i + 1) * 100 * mb - 1)
        }
        XCTAssertNil(DownloadItem.growthSplitPoint(segments: segments, maxConnections: 16, minSplitBytes: 8 * mb))
    }

    // MARK: - reconciledSegments

    func testReconcileClampsToFileSize() {
        let segments = [
            Segment(index: 0, startByte: 0, endByte: 99, receivedBytes: 100),
            Segment(index: 1, startByte: 100, endByte: 199, receivedBytes: 80),
        ]
        // Only 150 bytes actually on disk: segment 1 keeps 50.
        let out = DownloadItem.reconciledSegments(segments, fileSize: 150)
        XCTAssertEqual(out[0].receivedBytes, 100)
        XCTAssertEqual(out[1].receivedBytes, 50)
    }

    // MARK: - totalFromContentRange

    func testTotalFromContentRange() {
        XCTAssertEqual(DownloadItem.totalFromContentRange("bytes 0-0/12345"), 12345)
        XCTAssertEqual(DownloadItem.totalFromContentRange("bytes 100-199/12345"), 12345)
        XCTAssertEqual(DownloadItem.totalFromContentRange("bytes */12345"), 12345)
        XCTAssertNil(DownloadItem.totalFromContentRange("bytes 0-0/*"))
        XCTAssertNil(DownloadItem.totalFromContentRange("garbage"))
    }

    // MARK: - filenameFromContentDisposition

    func testFilenameQuoted() {
        XCTAssertEqual(
            DownloadItem.filenameFromContentDisposition("attachment; filename=\"report final.zip\""),
            "report final.zip")
    }

    func testFilenameBare() {
        XCTAssertEqual(
            DownloadItem.filenameFromContentDisposition("attachment; filename=setup.exe"),
            "setup.exe")
    }

    func testFilenameRFC5987() {
        XCTAssertEqual(
            DownloadItem.filenameFromContentDisposition("attachment; filename*=UTF-8''%E1%80%A1%E1%80%AC.zip"),
            "အာ.zip")
    }

    func testFilenameMissing() {
        XCTAssertNil(DownloadItem.filenameFromContentDisposition("attachment"))
    }

    // MARK: - validatorsChanged

    func testValidatorsChangedOnETagMismatch() {
        XCTAssertTrue(DownloadItem.validatorsChanged(
            storedETag: "\"abc\"", storedLastModified: nil, headers: ["etag": "\"def\""]))
    }

    func testValidatorsUnchangedWhenMatching() {
        XCTAssertFalse(DownloadItem.validatorsChanged(
            storedETag: "\"abc\"", storedLastModified: "Mon, 01 Jan 2026 00:00:00 GMT",
            headers: ["etag": "\"abc\"", "last-modified": "Mon, 01 Jan 2026 00:00:00 GMT"]))
    }

    func testValidatorsIgnoredWhenAbsent() {
        // Server stopped sending validators: not a change, just missing data.
        XCTAssertFalse(DownloadItem.validatorsChanged(
            storedETag: "\"abc\"", storedLastModified: nil, headers: [:]))
    }

    // MARK: - GrabbitURLScheme

    func testSchemeParsesFullURL() {
        let raw = "grabbit://download?url=" + "https://cdn.example.com/f.zip".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            + "&filename=" + "my file.zip".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            + "&cookie=" + "a=b; c=d".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            + "&referer=" + "https://example.com/p".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            + "&userAgent=TestAgent/1.0"
        let req = GrabbitURLScheme.parse(URL(string: raw)!)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.url.absoluteString, "https://cdn.example.com/f.zip")
        XCTAssertEqual(req?.filename, "my file.zip")
        XCTAssertEqual(req?.headers["Cookie"], "a=b; c=d")
        XCTAssertEqual(req?.headers["Referer"], "https://example.com/p")
        XCTAssertEqual(req?.headers["User-Agent"], "TestAgent/1.0")
    }

    func testSchemeParsesMinimalURL() {
        let req = GrabbitURLScheme.parse(URL(string: "grabbit://download?url=https://example.com/a.bin")!)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.url.absoluteString, "https://example.com/a.bin")
        XCTAssertNil(req?.filename)
        XCTAssertTrue(req?.headers.isEmpty ?? false)
    }

    func testSchemeRejectsNonGrabbit() {
        XCTAssertNil(GrabbitURLScheme.parse(URL(string: "https://example.com/a.bin")!))
        XCTAssertNil(GrabbitURLScheme.parse(URL(string: "grabbit://open?url=https://example.com/a.bin")!))
    }

    func testSchemeRejectsNonHTTPTarget() {
        XCTAssertNil(GrabbitURLScheme.parse(URL(string: "grabbit://download?url=ftp://example.com/a.bin")!))
        XCTAssertNil(GrabbitURLScheme.parse(URL(string: "grabbit://download?url=blob:https://example.com/123")!))
        XCTAssertNil(GrabbitURLScheme.parse(URL(string: "grabbit://download")!))
    }

    // MARK: - Request headers plumbing

    func testRequestHeadersStoredOnItem() {
        let item = DownloadItem(
            url: URL(string: "https://example.com/a.bin")!,
            filename: "a.bin",
            destinationURL: URL(fileURLWithPath: "/tmp/a.bin"),
            requestHeaders: ["Cookie": "a=b", "Referer": "https://example.com/"])
        XCTAssertEqual(item.requestHeaders?["Cookie"], "a=b")
        // Backward compatible: missing key decodes to nil.
        let data = try! JSONEncoder().encode(item)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["requestHeaders"])
    }

    func testNativeMessageLenientPageUrl() throws {
        let host = NativeMessagingHost()
        XCTAssertNotNil(host)
        let json = """
        {"url":"https://example.com/a.bin","source":"context-menu","pageUrl":"","headers":{"Cookie":"a=b"}}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(NativeMessagingHost.NativeMessage.self, from: json)
        XCTAssertEqual(msg.url.absoluteString, "https://example.com/a.bin")
        XCTAssertNil(msg.pageUrl)
        XCTAssertEqual(msg.headers?["Cookie"], "a=b")
    }
}
