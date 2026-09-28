import XCTest
@testable import Grabbit

/// Phase 5 named queues: QueueStore persistence + QueuePlanner capacity logic.
final class QueueTests: XCTestCase {

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(
        id: UUID = UUID(),
        state: DownloadState = .queued,
        queueID: UUID? = nil
    ) -> DownloadItem {
        DownloadItem(
            id: id,
            url: URL(string: "https://example.com/file")!,
            filename: "file",
            destinationURL: URL(fileURLWithPath: "/tmp/file"),
            state: state,
            queueID: queueID)
    }

    // MARK: - QueueStore

    func testSeedsDefaultQueue() {
        let store = QueueStore(directory: tmp())
        XCTAssertEqual(store.queues.count, 1)
        XCTAssertTrue(store.queues[0].isDefault)
        XCTAssertEqual(store.queues[0].maxConcurrent, 5)
        XCTAssertEqual(store.defaultQueue.id, store.queues[0].id)
    }

    func testAddRemoveUpdatePersist() {
        let dir = tmp()
        let store = QueueStore(directory: dir)
        store.add(name: "Slow", maxConcurrent: 1)
        store.add(name: "  ", maxConcurrent: 2) // blank names are ignored
        XCTAssertEqual(store.queues.count, 2)

        let slow = store.queues.first(where: { $0.name == "Slow" })!
        var renamed = slow
        renamed.name = "Slower"
        renamed.maxConcurrent = 2
        store.update(renamed)

        let reloaded = QueueStore(directory: dir)
        XCTAssertEqual(reloaded.queues.count, 2)
        XCTAssertEqual(reloaded.queue(for: slow.id).name, "Slower")
        XCTAssertEqual(reloaded.queue(for: slow.id).maxConcurrent, 2)

        XCTAssertTrue(reloaded.remove(id: slow.id))
        XCTAssertEqual(QueueStore(directory: dir).queues.count, 1)
    }

    func testCannotRemoveDefaultOrUnknown() {
        let store = QueueStore(directory: tmp())
        XCTAssertFalse(store.remove(id: store.defaultQueue.id))
        XCTAssertFalse(store.remove(id: UUID()))
        XCTAssertEqual(store.queues.count, 1)
    }

    func testUpdateClampsAndPreservesDefault() {
        let store = QueueStore(directory: tmp())
        var def = store.defaultQueue
        def.maxConcurrent = 0
        def.name = "Hacked"
        store.update(def)
        XCTAssertEqual(store.defaultQueue.maxConcurrent, 1)
        XCTAssertTrue(store.defaultQueue.isDefault)
        XCTAssertEqual(store.defaultQueue.name, "")
    }

    func testQueueForFallsBackToDefault() {
        let store = QueueStore(directory: tmp())
        store.add(name: "Q", maxConcurrent: 2)
        let custom = store.queues.first(where: { !$0.isDefault })!
        XCTAssertEqual(store.queue(for: nil).id, store.defaultQueue.id)
        XCTAssertEqual(store.queue(for: UUID()).id, store.defaultQueue.id) // deleted
        XCTAssertEqual(store.queue(for: custom.id).id, custom.id)
    }

    func testCorruptFileFallsBackToDefault() throws {
        let dir = tmp()
        try "not json".write(
            to: dir.appendingPathComponent("queues.json"),
            atomically: true, encoding: .utf8)
        let store = QueueStore(directory: dir)
        XCTAssertEqual(store.queues.count, 1)
        XCTAssertTrue(store.queues[0].isDefault)
    }

    // MARK: - QueuePlanner

    func testPerQueueCapRespected() {
        let def = DownloadQueue(maxConcurrent: 10, isDefault: true)
        let slow = DownloadQueue(name: "Slow", maxConcurrent: 1)
        let a = makeItem(queueID: slow.id)
        let b = makeItem(queueID: slow.id)
        let plan = QueuePlanner.startable(
            items: [a, b], queues: [def, slow],
            defaultQueue: def, globalMaxActive: 10)
        XCTAssertEqual(plan.map(\.id), [a.id])
    }

    func testGlobalCapRespected() {
        let def = DownloadQueue(maxConcurrent: 10, isDefault: true)
        let q2 = DownloadQueue(name: "Q2", maxConcurrent: 10)
        let a = makeItem()
        let b = makeItem(queueID: q2.id)
        let plan = QueuePlanner.startable(
            items: [a, b], queues: [def, q2],
            defaultQueue: def, globalMaxActive: 1)
        // Store order: the default queue drains first.
        XCTAssertEqual(plan.map(\.id), [a.id])
    }

    func testOldestFirstAndNoStarvation() {
        let def = DownloadQueue(maxConcurrent: 1, isDefault: true)
        let q2 = DownloadQueue(name: "Q2", maxConcurrent: 1)
        let a1 = makeItem()
        let a2 = makeItem()
        let b1 = makeItem(queueID: q2.id)
        let plan = QueuePlanner.startable(
            items: [a1, a2, b1], queues: [def, q2],
            defaultQueue: def, globalMaxActive: 5)
        // a1 fills the default queue; b1 still gets its own queue's slot.
        XCTAssertEqual(plan.map(\.id), [a1.id, b1.id])
    }

    func testActiveDownloadsCountAgainstCaps() {
        let def = DownloadQueue(maxConcurrent: 2, isDefault: true)
        let active = makeItem(state: .downloading)
        let q1 = makeItem()
        let q2 = makeItem()
        let plan = QueuePlanner.startable(
            items: [active, q1, q2], queues: [def],
            defaultQueue: def, globalMaxActive: 10)
        XCTAssertEqual(plan.map(\.id), [q1.id])
    }

    func testUnknownQueueIDFallsBackToDefault() {
        let def = DownloadQueue(maxConcurrent: 1, isDefault: true)
        let active = makeItem(state: .downloading)
        let orphan = makeItem(queueID: UUID()) // queue was deleted
        let plan = QueuePlanner.startable(
            items: [active, orphan], queues: [def],
            defaultQueue: def, globalMaxActive: 10)
        XCTAssertTrue(plan.isEmpty)
    }

    func testEmptyQueueListUsesDefault() {
        let def = DownloadQueue(maxConcurrent: 1, isDefault: true)
        let a = makeItem()
        let b = makeItem()
        let plan = QueuePlanner.startable(
            items: [a, b], queues: [],
            defaultQueue: def, globalMaxActive: 10)
        XCTAssertEqual(plan.map(\.id), [a.id])
    }

    // MARK: - DownloadItem.queueID persistence

    func testQueueIDRoundTripAndLegacyDefault() throws {
        var item = makeItem()
        item.queueID = UUID()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)
        XCTAssertEqual(decoded.queueID, item.queueID)

        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "queueID")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let legacy = try JSONDecoder().decode(DownloadItem.self, from: legacyData)
        XCTAssertNil(legacy.queueID)
    }
}
