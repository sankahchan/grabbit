import XCTest
@testable import Grabbit

/// Backlog #7 drag-reorder: a torn-down drag (Escape, released over empty
/// space) must never leave dirty in-memory ordering — hover-reordered
/// ranks with no commit coming. The engine snapshots the pre-drag order
/// on beginDragReorder; cancelDragReorder restores it.
@MainActor
final class DragReorderTests: XCTestCase {

    private func engine(withFilenames names: [String], state: DownloadState = .queued) throws -> (DownloadEngine, ResumeStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ResumeStore(directory: dir)
        for name in names {
            let item = DownloadItem(
                url: URL(string: "https://example.com/\(name)")!,
                filename: name,
                state: state,
                destinationURL: URL(fileURLWithPath: "/tmp/\(name)"))
            try store.save(item)
        }
        let engine = DownloadEngine(resumeStore: store)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (engine, store)
    }

    private func filenames(of engine: DownloadEngine) -> [String] {
        engine.items.map(\.filename)
    }

    func testMoveReordersLive() throws {
        let (engine, _) = try engine(withFilenames: ["a", "b", "c"])
        let ids = engine.items.map(\.id)
        engine.beginDragReorder()
        engine.moveItem(draggedID: ids[0], to: ids[2])
        XCTAssertEqual(filenames(of: engine), ["b", "c", "a"])
        XCTAssertEqual(engine.items.map(\.sortRank), [0, 1, 2])
    }

    func testCancelRestoresPreDragOrder() throws {
        let (engine, _) = try engine(withFilenames: ["a", "b", "c"])
        let ids = engine.items.map(\.id)
        engine.beginDragReorder()
        engine.moveItem(draggedID: ids[0], to: ids[2])
        engine.moveItem(draggedID: ids[2], to: ids[1])
        XCTAssertEqual(filenames(of: engine), ["c", "b", "a"])
        engine.cancelDragReorder()
        XCTAssertEqual(filenames(of: engine), ["a", "b", "c"])
        XCTAssertEqual(engine.items.map(\.sortRank), [0, 1, 2])
    }

    func testCancelIsNoOpWithoutDragSession() throws {
        let (engine, _) = try engine(withFilenames: ["a", "b"])
        engine.cancelDragReorder()
        XCTAssertEqual(filenames(of: engine), ["a", "b"])
    }

    func testCommitClearsSnapshotSoLaterCancelCannotRevertIt() throws {
        let (engine, _) = try engine(withFilenames: ["a", "b", "c"])
        let ids = engine.items.map(\.id)
        engine.beginDragReorder()
        engine.moveItem(draggedID: ids[0], to: ids[2])
        engine.commitItemOrder()
        // A stray cancel after the commit must not resurrect the old order.
        engine.cancelDragReorder()
        XCTAssertEqual(filenames(of: engine), ["b", "c", "a"])
    }

    func testCommitPersistsReorderedRanks() throws {
        // .completed items: commitItemOrder's kickQueue is a no-op for them
        // (start() early-returns), so this test performs no network I/O.
        let (engine, store) = try engine(withFilenames: ["a", "b", "c"], state: .completed)
        let ids = engine.items.map(\.id)
        engine.beginDragReorder()
        engine.moveItem(draggedID: ids[2], to: ids[0])
        engine.commitItemOrder()
        let reloaded = DownloadEngine(resumeStore: store)
        XCTAssertEqual(reloaded.items.map(\.filename), ["c", "a", "b"])
    }

    func testMoveItemWithoutExplicitBeginStillRevertable() throws {
        // moveItem lazily opens the session, so even a caller that never
        // called beginDragReorder gets a working cancel.
        let (engine, _) = try engine(withFilenames: ["a", "b", "c"])
        let ids = engine.items.map(\.id)
        engine.moveItem(draggedID: ids[0], to: ids[1])
        XCTAssertEqual(filenames(of: engine), ["b", "a", "c"])
        engine.cancelDragReorder()
        XCTAssertEqual(filenames(of: engine), ["a", "b", "c"])
    }

    func testSecondBeginKeepsOriginalSnapshot() throws {
        let (engine, _) = try engine(withFilenames: ["a", "b", "c"])
        let ids = engine.items.map(\.id)
        engine.beginDragReorder()
        engine.moveItem(draggedID: ids[0], to: ids[2])
        // A redundant begin mid-drag must NOT re-snapshot the hover order.
        engine.beginDragReorder()
        engine.cancelDragReorder()
        XCTAssertEqual(filenames(of: engine), ["a", "b", "c"])
    }
}
