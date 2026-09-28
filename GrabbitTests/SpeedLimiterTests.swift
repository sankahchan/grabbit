import XCTest
@testable import Grabbit

/// Phase 5 speed limiter: TokenBucket unit tests.
final class SpeedLimiterTests: XCTestCase {

    // MARK: - TokenBucket

    func testUnlimitedBucketNeverBlocks() {
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
        let bucket = TokenBucket(rate: 1000)
        let start = Date()
        bucket.consume(0)
        bucket.consume(-10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testAverageRateApproximatelyLimited() {
        // 200 KB/s. Initial burst = 1s of rate (200_000 tokens), so the
        // first 200_000 bytes pass instantly; the next 200_000 take ~1s.
        let bucket = TokenBucket(rate: 200_000)
        let start = Date()
        for _ in 0..<8 { bucket.consume(50_000) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.5, "pacing should add ~1s for the post-burst bytes")
        XCTAssertLessThan(elapsed, 3.0, "pacing must not stall far beyond the limit")
    }

    func testLoweringRateClampsStoredBurst() {
        // Fill the bucket at a high rate, then slam the limit down: the
        // stored burst must shrink to the new capacity immediately.
        let now = Date()
        let bucket = TokenBucket(rate: 1_000_000, now: { now })
        bucket.rate = 1000
        // Capacity is now max(1000, 64KiB) = 65536; with a frozen clock no
        // refill happens, so 65536 bytes must pass without sleeping.
        let start = Date()
        bucket.consume(65_536)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        // The 65537th byte needs (1/1000)s of pacing.
        bucket.consume(1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.0005)
    }

    func testSharedBucketSerializesAcrossThreads() {
        // The global bucket is shared by every segment: concurrent
        // consumers must still observe the aggregate limit.
        let bucket = TokenBucket(rate: 100_000)
        let group = DispatchGroup()
        let start = Date()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<5 { bucket.consume(25_000) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        // 500_000 bytes at 100 KB/s with a 100_000 burst ≈ 4s of pacing.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 2.0)
        XCTAssertLessThan(elapsed, 10.0)
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
