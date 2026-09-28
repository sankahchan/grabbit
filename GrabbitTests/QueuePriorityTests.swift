import XCTest
@testable import Grabbit

/// Backlog #7: queue drag-reorder (persisted sortRank) + per-task priority
/// (QueuePlanner starts higher priority first).
final class QueuePriorityTests: XCTestCase {

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(
        state: DownloadState = .queued,
        priority: Int = 0,
        sortRank: Int = 0
    ) -> DownloadItem {
        DownloadItem(
            url: URL(string: "https://example.com/file")!,
            filename: "file",
            state: state,
            destinationURL: URL(fileURLWithPath: "/tmp/file"),
            priority: priority,
            sortRank: sortRank)
    }

    // MARK: - QueuePlanner priority

    func testPriorityWinsOverListPosition() {
        let store = QueueStore(directory: tmp())
        let a = makeItem(priority: 0)
        let b = makeItem(priority: 3)
        let c = makeItem(priority: 0)
        let plan = QueuePlanner.startable(
            items: [a, b, c],
            queues: [],
            defaultQueue: store.defaultQueue,
            globalMaxActive: 1)
        XCTAssertEqual(plan.map(\.id), [b.id])
    }

    func testPriorityTieFallsBackToListPosition() {
        let store = QueueStore(directory: tmp())
        let a = makeItem(priority: 1)
        let b = makeItem(priority: 1)
        let c = makeItem(priority: 1)
        let plan = QueuePlanner.startable(
            items: [a, b, c],
            queues: [],
            defaultQueue: store.defaultQueue,
            globalMaxActive: 2)
        XCTAssertEqual(plan.map(\.id), [a.id, b.id])
    }

    func testNegativePriorityStartsLast() {
        let store = QueueStore(directory: tmp())
        let a = makeItem(priority: -2)
        let b = makeItem(priority: 0)
        let plan = QueuePlanner.startable(
            items: [a, b],
            queues: [],
            defaultQueue: store.defaultQueue,
            globalMaxActive: 1)
        XCTAssertEqual(plan.map(\.id), [b.id])
    }

    // MARK: - Legacy decode defaults

    func testLegacyJSONDefaultsPriorityAndSortRank() throws {
        let json = """
        {"id":"\(UUID().uuidString)","url":"https://example.com/f",\
        "filename":"f","downloadedBytes":0,"segments":[],\
        "state":"queued","speedBytesPerSec":0,"category":"other",\
        "sourceSite":"direct","destinationURL":"file:///tmp/f",\
        "addedAt":789012345.0}
        """
        let item = try JSONDecoder().decode(
            DownloadItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.priority, 0)
        XCTAssertEqual(item.sortRank, 0)
    }

    // MARK: - Engine move + setPriority

    /// .paused items keep kickQueue() from launching real downloads.
    @MainActor
    func testMoveItemReordersAndRenumbers() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ResumeStore(directory: dir)
        let ids = [UUID(), UUID(), UUID()]
        for (i, id) in ids.enumerated() {
            try store.save(DownloadItem(
                id: id,
                url: URL(string: "https://example.com/\(i)")!,
                filename: "\(i)",
                state: .paused,
                destinationURL: URL(fileURLWithPath: "/tmp/\(i)"),
                sortRank: i))
        }
        let engine = DownloadEngine(resumeStore: store)
        XCTAssertEqual(engine.items.map(\.id), ids)

        engine.moveItem(draggedID: ids[0], to: ids[2])
        XCTAssertEqual(engine.items.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(engine.items.map(\.sortRank), [0, 1, 2])

        // Dragging upward lands *before* the target.
        engine.moveItem(draggedID: ids[2], to: ids[1])
        XCTAssertEqual(engine.items.map(\.id), [ids[2], ids[1], ids[0]])
        XCTAssertEqual(engine.items.map(\.sortRank), [0, 1, 2])

        // Order survives a reload.
        let reloaded = DownloadEngine(resumeStore: ResumeStore(directory: dir))
        XCTAssertEqual(reloaded.items.map(\.id), [ids[2], ids[1], ids[0]])
    }

    @MainActor
    func testSetPriorityClampsAndPersists() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ResumeStore(directory: dir)
        let id = UUID()
        try store.save(DownloadItem(
            id: id,
            url: URL(string: "https://example.com/f")!,
            filename: "f",
            state: .paused,
            destinationURL: URL(fileURLWithPath: "/tmp/f")))
        let engine = DownloadEngine(resumeStore: store)

        engine.setPriority(id: id, priority: 99)
        XCTAssertEqual(engine.items.first?.priority, 5)
        engine.setPriority(id: id, priority: -99)
        XCTAssertEqual(engine.items.first?.priority, -5)

        let reloaded = DownloadEngine(resumeStore: ResumeStore(directory: dir))
        XCTAssertEqual(reloaded.items.first?.priority, -5)
    }
}
