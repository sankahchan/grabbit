import XCTest
@testable import Grabbit

/// Phase 5 speed limiter: TokenBucket unit tests.
///
/// Timing-sensitive tests use the injectable `sleeper` (records instead of
/// sleeping) plus a frozen clock, so they're fully deterministic — thread
/// interleaving can't change the recorded delays.
final class SpeedLimiterTests: XCTestCase {

    // MARK: - TokenBucket

    func testUnlimitedReturnsImmediately() {
        let bucket = TokenBucket(rate: 0)
        let start = Date()
        // 100 MB through an unlimited bucket must return (near-)instantly.
        bucket.consume(100 * 1_048_576)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testNegativeRateTreatedAsUnlimited() {
        let bucket = TokenBucket(rate: -500)
        let start = Date()
        bucket.consume(10 * 1_048_576)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testZeroByteConsumeIsNoOp() {
        var slept: [TimeInterval] = []
        let bucket = TokenBucket(rate: 1000, sleeper: { slept.append($0) })
        bucket.consume(0)
        bucket.consume(-10)
        XCTAssertTrue(slept.isEmpty)
    }

    func testAverageRateMatchesLimit() {
        // 200 KB/s, 8 × 50 KB = 400 KB. The 1s burst (200 KB) covers the
        // first 4 chunks; the remaining 4 are paced at 0.25 s each.
        var slept: [TimeInterval] = []
        let bucket = TokenBucket(rate: 200_000, sleeper: { slept.append($0) })
        for _ in 0..<8 { bucket.consume(50_000) }
        XCTAssertEqual(slept.count, 4)
        XCTAssertEqual(slept.reduce(0, +), 1.0, accuracy: 0.05)
    }

    func testSharedBucketSerializesAcrossThreads() {
        // The global bucket is shared by every segment: 4 threads × 5 ×
        // 25 KB = 500 KB at 100 KB/s with a 100 KB burst. The recorded
        // delays must total exactly 4.0 s of rate-time — the multiset is
        // order-independent, so thread interleaving can't flake it.
        let now = Date()
        var delays: [TimeInterval] = []
        let delaysLock = NSLock()
        let bucket = TokenBucket(
            rate: 100_000,
            now: { now },
            sleeper: { delay in delaysLock.withLock { delays.append(delay) } })
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<5 { bucket.consume(25_000) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(delays.count, 16)
        XCTAssertEqual(delays.reduce(0, +), 4.0, accuracy: 0.05)
        XCTAssertEqual(delays.max() ?? 0, 0.25, accuracy: 0.01)
    }

    func testLoweringRateRescalesQueuedWait() {
        // At 1000 B/s the second consume queues a 1.0 s wait; halving the
        // rate must stretch that already-queued wait to 2.0 s instead of
        // letting it coast at the old rate.
        let now = Date()
        var slept: [TimeInterval] = []
        let bucket = TokenBucket(rate: 1000, now: { now }, sleeper: { slept.append($0) })
        bucket.consume(1000) // burst: free
        bucket.consume(1000) // queues 1.0 s
        bucket.rate = 500
        bucket.consume(1000) // must see the rescaled 2.0 s wait
        XCTAssertEqual(slept.count, 2)
        XCTAssertEqual(slept[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(slept[1], 2.0, accuracy: 0.001)
    }

    func testIdleNeverAccruesMoreThanBurst() {
        // An hour idle still only earns the 1 s burst: 5000 bytes at
        // 1000 B/s → 1000 free, 4000 paced = 4.0 s wait.
        var now = Date()
        var slept: [TimeInterval] = []
        let bucket = TokenBucket(rate: 1000, now: { now }, sleeper: { slept.append($0) })
        now = now.addingTimeInterval(3600)
        bucket.consume(5000)
        XCTAssertEqual(slept.count, 1)
        XCTAssertEqual(slept[0], 4.0, accuracy: 0.001)
    }

    func testDefaultSleeperActuallyPaces() {
        // End-to-end through the real Thread.sleep path: 300 KB at
        // 200 KB/s, 200 KB burst free → ~0.5 s of real pacing.
        let bucket = TokenBucket(rate: 200_000)
        let start = Date()
        for _ in 0..<6 { bucket.consume(50_000) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 3.0)
    }

    // MARK: - MediaEngine.rateString

    func testRateStringFormatsMegabytes() {
        XCTAssertEqual(MediaEngine.rateString(1_048_576), "1M")
        XCTAssertEqual(MediaEngine.rateString(5 * 1_048_576), "5M")
    }

    func testRateStringFormatsKilobytes() {
        XCTAssertEqual(MediaEngine.rateString(512 * 1_024), "512K")
        XCTAssertEqual(MediaEngine.rateString(100), "1K")
    }

    // MARK: - DownloadItem legacy decode

    func testDownloadItemDecodesLegacyJSONWithoutSpeedLimit() throws {
        // Resume-store JSON written before Phase 5 has no
        // speedLimitBytesPerSec key: it must decode as unlimited (0).
        let item = DownloadItem(url: URL(string: "https://example.com/f.zip")!, filename: "f.zip", destinationURL: URL(fileURLWithPath: "/tmp"))
        let data = try JSONEncoder().encode(item)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "speedLimitBytesPerSec")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: legacy)
        XCTAssertEqual(decoded.speedLimitBytesPerSec, 0)
    }

    func testDownloadItemRoundTripsSpeedLimit() throws {
        var item = DownloadItem(url: URL(string: "https://example.com/f.zip")!, filename: "f.zip", destinationURL: URL(fileURLWithPath: "/tmp"))
        item.speedLimitBytesPerSec = 2 * 1_048_576
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: try JSONEncoder().encode(item))
        XCTAssertEqual(decoded.speedLimitBytesPerSec, 2 * 1_048_576)
    }
}
