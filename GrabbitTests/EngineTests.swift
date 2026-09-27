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
}
