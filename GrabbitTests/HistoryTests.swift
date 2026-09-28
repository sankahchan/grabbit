import XCTest
@testable import Grabbit

final class HistoryTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleEntry(
        id: UUID = UUID(), kind: HistoryKind = .download,
        status: HistoryStatus = .completed, name: String = "file.zip"
    ) -> HistoryEntry {
        HistoryEntry(
            id: id, name: name, kind: kind, status: status,
            totalBytes: 1024, sourceURL: "https://example.com/file.zip",
            savePath: "/tmp/file.zip")
    }

    // MARK: - Persistence round-trip

    func testRecordPersistsAndReloads() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        let entry = sampleEntry(name: "roundtrip.bin")
        store.record(entry)

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].id, entry.id)
        XCTAssertEqual(reloaded.entries[0].name, "roundtrip.bin")
        XCTAssertEqual(reloaded.entries[0].kind, .download)
        XCTAssertEqual(reloaded.entries[0].sourceURL, "https://example.com/file.zip")
    }

    func testCorruptFileFallsBackToEmpty() {
        let dir = tempDir()
        let url = dir.appendingPathComponent("history.json")
        try! "not json at all{{{".write(to: url, atomically: true, encoding: .utf8)

        let store = HistoryStore(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Cap and ordering

    func testEntriesAreNewestFirst() {
        let store = HistoryStore(directory: tempDir())
        store.record(sampleEntry(name: "first"))
        store.record(sampleEntry(name: "second"))
        XCTAssertEqual(store.entries.map(\.name), ["second", "first"])
    }

    func testCapPrunesOldest() {
        let store = HistoryStore(directory: tempDir())
        for i in 0..<(HistoryStore.maxEntries + 10) {
            store.record(sampleEntry(name: "file-\(i)"))
        }
        XCTAssertEqual(store.entries.count, HistoryStore.maxEntries)
        // Newest survives, oldest is gone.
        XCTAssertEqual(store.entries.first?.name, "file-\(HistoryStore.maxEntries + 9)")
        XCTAssertFalse(store.entries.contains { $0.name == "file-0" })
    }

    func testRecordUpsertsByIdInsteadOfDuplicating() {
        let store = HistoryStore(directory: tempDir())
        let id = UUID()
        store.record(sampleEntry(id: id, status: .failed, name: "retry.bin"))
        store.record(sampleEntry(id: id, status: .completed, name: "retry.bin"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].status, .completed)
    }

    func testRemoveAndClear() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        let a = sampleEntry(), b = sampleEntry()
        store.record(a)
        store.record(b)
        store.remove(id: a.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, b.id)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        // Clear persists across reload.
        XCTAssertTrue(HistoryStore(directory: dir).entries.isEmpty)
    }

    // MARK: - Filtering

    func testEntriesForKindFilters() {
        let store = HistoryStore(directory: tempDir())
        store.record(sampleEntry(kind: .download))
        store.record(sampleEntry(kind: .torrent))
        store.record(sampleEntry(kind: .media))
        XCTAssertEqual(store.entries(for: nil).count, 3)
        XCTAssertEqual(store.entries(for: .download).count, 1)
        XCTAssertEqual(store.entries(for: .torrent).count, 1)
        XCTAssertEqual(store.entries(for: .media).count, 1)
        XCTAssertEqual(store.count(for: .download), 1)
        XCTAssertEqual(store.count(for: nil), 3)
    }

    // MARK: - Backfill

    private func downloadItem(state: DownloadState) -> DownloadItem {
        DownloadItem(
            url: URL(string: "https://example.com/a.zip")!,
            filename: "a.zip",
            totalBytes: 2048,
            state: state,
            destinationURL: URL(fileURLWithPath: "/tmp/a.zip"),
            errorMessage: state == .failed ? "boom" : nil)
    }

    private func torrentItem(state: TorrentState) -> TorrentItem {
        TorrentItem(
            name: "t",
            magnetURI: "magnet:?xt=urn:btih:abc",
            state: state,
            errorMessage: state == .failed ? "tracker down" : nil,
            savePath: URL(fileURLWithPath: "/tmp"))
    }

    func testBackfillImportsTerminalItemsOnly() {
        let store = HistoryStore(directory: tempDir())
        store.backfillIfNeeded(
            downloads: [
                downloadItem(state: .completed),
                downloadItem(state: .failed),
                downloadItem(state: .downloading),
            ],
            torrents: [
                torrentItem(state: .completed),
                torrentItem(state: .paused),
            ])
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries(for: .download).count, 2)
        XCTAssertEqual(store.entries(for: .torrent).count, 1)
    }

    func testBackfillOnlyRunsWhenEmpty() {
        let store = HistoryStore(directory: tempDir())
        store.record(sampleEntry(name: "live"))
        store.backfillIfNeeded(
            downloads: [downloadItem(state: .completed)],
            torrents: [])
        // The live entry stays alone — no duplication, no import.
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].name, "live")
    }

    func testBackfillMapsFields() {
        let store = HistoryStore(directory: tempDir())
        let failed = downloadItem(state: .failed)
        store.backfillIfNeeded(downloads: [failed], torrents: [])
        let entry = store.entries[0]
        XCTAssertEqual(entry.id, failed.id)
        XCTAssertEqual(entry.name, "a.zip")
        XCTAssertEqual(entry.kind, .download)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.totalBytes, 2048)
        XCTAssertEqual(entry.sourceURL, "https://example.com/a.zip")
        XCTAssertEqual(entry.errorMessage, "boom")
        XCTAssertNil(
            store.entries(for: nil).first(where: { $0.status == .completed })?.errorMessage)
    }

    // MARK: - Entry mapping

    func testTorrentEntryPrefersMagnet() {
        let item = torrentItem(state: .completed)
        let entry = HistoryEntry.from(torrent: item, status: .completed)
        XCTAssertEqual(entry.kind, .torrent)
        XCTAssertEqual(entry.sourceURL, "magnet:?xt=urn:btih:abc")
        XCTAssertEqual(entry.sourceHost, NSLocalizedString("history.source.magnet", comment: ""))
        XCTAssertNil(entry.errorMessage)
    }

    func testMediaEntryMapping() {
        let entry = HistoryEntry.media(
            name: "video title",
            sourceURL: "https://youtube.com/watch?v=x",
            saveDirectory: URL(fileURLWithPath: "/tmp/media"),
            status: .failed,
            errorMessage: "nope")
        XCTAssertEqual(entry.kind, .media)
        XCTAssertEqual(entry.name, "video title")
        XCTAssertEqual(entry.savePath, "/tmp/media")
        XCTAssertEqual(entry.errorMessage, "nope")
        XCTAssertEqual(entry.sourceHost, "youtube.com")
    }

    func testSourceHostFallsBackToRawString() {
        let entry = sampleEntry()
        var copy = entry
        copy.sourceURL = "not a url"
        XCTAssertEqual(copy.sourceHost, "not a url")
    }

    func testFailedEntryKeepsMessageCompletedDoesNot() {
        let ok = HistoryEntry.from(download: downloadItem(state: .completed), status: .completed)
        XCTAssertNil(ok.errorMessage)
        let bad = HistoryEntry.from(download: downloadItem(state: .failed), status: .failed)
        XCTAssertEqual(bad.errorMessage, "boom")
    }

    // MARK: - Retry feedback (HistoryRetry)

    private func retryEntry(kind: HistoryKind, sourceURL: String, name: String = "vid.mp4") -> HistoryEntry {
        HistoryEntry(
            name: name, kind: kind, status: .completed,
            sourceURL: sourceURL)
    }

    private struct BoomError: LocalizedError {
        var errorDescription: String? { "daemon is down" }
    }

    func testRetryBuildsTorrentRequest() {
        let folder = URL(fileURLWithPath: "/tmp/torrents")
        let req = HistoryRetry.request(
            for: retryEntry(kind: .torrent, sourceURL: "magnet:?xt=urn:btih:abc"),
            torrentSaveFolder: folder)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.kind, .torrent)
        XCTAssertEqual(req?.sourceURL, "magnet:?xt=urn:btih:abc")
        XCTAssertEqual(req?.name, "vid.mp4")
        XCTAssertEqual(req?.torrentSaveFolder, folder)
    }

    func testRetryBuildsDownloadRequest() {
        let req = HistoryRetry.request(
            for: retryEntry(kind: .download, sourceURL: "https://example.com/f.zip"),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp"))
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.kind, .download)
        XCTAssertNil(req?.torrentSaveFolder)
    }

    func testRetryRejectsEmptyTorrentSource() {
        XCTAssertNil(HistoryRetry.request(
            for: retryEntry(kind: .torrent, sourceURL: ""),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp")))
    }

    func testRetryRejectsNonHttpDownloadSource() {
        XCTAssertNil(HistoryRetry.request(
            for: retryEntry(kind: .download, sourceURL: "ftp://example.com/f.zip"),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp")))
    }

    func testRetryLeavesMediaToTheMediaTab() {
        // Media re-download copies the URL and jumps tabs instead.
        XCTAssertNil(HistoryRetry.request(
            for: retryEntry(kind: .media, sourceURL: "https://example.com/v"),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp")))
    }

    func testRetryStartedToastIsSilentInfo() {
        let req = HistoryRetry.request(
            for: retryEntry(kind: .torrent, sourceURL: "magnet:?xt=urn:btih:abc"),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp"))!
        let toast = HistoryRetry.startedToast(for: req)
        XCTAssertEqual(toast.kind, .info)
        XCTAssertEqual(toast.source, .torrent)
        XCTAssertEqual(toast.message, "vid.mp4")
        XCTAssertFalse(toast.title.isEmpty)
        XCTAssertNil(toast.taskID)
    }

    func testRetryFailedToastNamesEntryAndError() {
        let req = HistoryRetry.request(
            for: retryEntry(kind: .torrent, sourceURL: "magnet:?xt=urn:btih:abc"),
            torrentSaveFolder: URL(fileURLWithPath: "/tmp"))!
        let toast = HistoryRetry.failedToast(for: req, error: BoomError())
        XCTAssertEqual(toast.kind, .failed)
        XCTAssertEqual(toast.source, .torrent)
        XCTAssertTrue(toast.message.contains("vid.mp4"))
        XCTAssertTrue(toast.message.contains("daemon is down"))
    }
}
