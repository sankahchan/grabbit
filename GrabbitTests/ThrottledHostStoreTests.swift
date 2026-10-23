import XCTest
@testable import Grabbit

final class ThrottledHostStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-\(UUID().uuidString)", isDirectory: true)
    }

    func testSeedMatchesSubdomains() {
        let store = ThrottledHostStore(directory: tempDir())
        XCTAssertTrue(store.isThrottled(host: "datatransfer.to"))
        XCTAssertTrue(store.isThrottled(host: "d8177.datatransfer.to"))
        XCTAssertTrue(store.isThrottled(host: "D8177.DataTransfer.TO"))
        XCTAssertTrue(store.isThrottled(host: "blue01.clicknupload.net"))
        XCTAssertTrue(store.isThrottled(host: "Clicknupload.NET"))
        XCTAssertFalse(store.isThrottled(host: "example.com"))
        XCTAssertFalse(store.isThrottled(host: nil))
    }

    func testDomainParsing() {
        XCTAssertEqual(ThrottledHostStore.domain("d8177.datatransfer.to"), "datatransfer.to")
        XCTAssertEqual(ThrottledHostStore.domain("a.b.c.example.com"), "example.com")
        XCTAssertEqual(ThrottledHostStore.domain("example.com"), "example.com")
        XCTAssertEqual(ThrottledHostStore.domain("localhost"), "localhost")
        XCTAssertEqual(ThrottledHostStore.domain("127.0.0.1"), "127.0.0.1")
        XCTAssertNil(ThrottledHostStore.domain(nil))
        XCTAssertNil(ThrottledHostStore.domain("  "))
    }

    func testLearnPersists() {
        let dir = tempDir()
        let store = ThrottledHostStore(directory: dir)
        XCTAssertFalse(store.isThrottled(host: "files.example.com"))
        XCTAssertTrue(store.learn(host: "files.example.com"))
        // Second learn is a no-op (already known).
        XCTAssertFalse(store.learn(host: "files.example.com"))
        XCTAssertTrue(store.isThrottled(host: "files.example.com"))
        XCTAssertTrue(store.isThrottled(host: "cdn.files.example.com"))

        // A fresh store from the same directory still knows the learned host.
        let reloaded = ThrottledHostStore(directory: dir)
        XCTAssertTrue(reloaded.isThrottled(host: "files.example.com"))
    }

    func testCorruptFileFallsBackToSeed() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("throttledhosts.json"))
        let store = ThrottledHostStore(directory: dir)
        XCTAssertTrue(store.isThrottled(host: "datatransfer.to"))
        XCTAssertFalse(store.isThrottled(host: "files.example.com"))
    }
}
