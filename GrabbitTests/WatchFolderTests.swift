import XCTest
@testable import Grabbit

/// Phase 5 watch folders: store persistence + pending-file selection.
final class WatchFolderTests: XCTestCase {

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - WatchFolderStore

    func testAddRemovePersist() {
        let dir = tmp()
        let watchDir = tmp()
        let store = WatchFolderStore(directory: dir)
        XCTAssertTrue(store.folders.isEmpty)

        store.add(path: watchDir.path)
        store.add(path: watchDir.path) // duplicate ignored
        store.add(path: "/nonexistent-dir-xyz") // not a dir: ignored
        store.add(path: "") // blank: ignored
        XCTAssertEqual(store.folders.count, 1)

        let id = store.folders[0].id
        store.setEnabled(id: id, enabled: false)
        XCTAssertFalse(store.folders[0].isEnabled)

        let reloaded = WatchFolderStore(directory: dir)
        XCTAssertEqual(reloaded.folders.count, 1)
        XCTAssertEqual(reloaded.folders[0].path, watchDir.path)
        XCTAssertFalse(reloaded.folders[0].isEnabled)

        reloaded.remove(id: id)
        XCTAssertTrue(WatchFolderStore(directory: dir).folders.isEmpty)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let dir = tmp()
        try "not json".write(
            to: dir.appendingPathComponent("watchfolders.json"),
            atomically: true, encoding: .utf8)
        XCTAssertTrue(WatchFolderStore(directory: dir).folders.isEmpty)
    }

    // MARK: - WatchFolderScan.pendingFiles

    private func touch(_ dir: URL, name: String, mtime: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "https://example.com/a.zip".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func testPendingFilesSelection() throws {
        let dir = tmp()
        let old = Date(timeIntervalSinceNow: -60)
        let fresh = Date()

        let settled = try touch(dir, name: "links.txt", mtime: old)
        try touch(dir, name: "fresh.txt", mtime: fresh) // still settling: skipped
        try touch(dir, name: "notes.md", mtime: old) // not .txt: skipped
        try touch(dir, name: "UPPER.TXT", mtime: old) // case-insensitive: kept

        let pending = WatchFolderScan.pendingFiles(in: dir, processed: [])
        XCTAssertEqual(Set(pending.map(\.lastPathComponent)),
                       Set(["links.txt", "UPPER.TXT"]))
        XCTAssertTrue(pending.map(\.path).contains(settled.path))

        // Already-processed paths are excluded.
        let again = WatchFolderScan.pendingFiles(in: dir, processed: [settled.path])
        XCTAssertFalse(again.map(\.path).contains(settled.path))
    }

    func testPendingFilesMissingDir() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertTrue(WatchFolderScan.pendingFiles(in: missing, processed: []).isEmpty)
    }
}
