import XCTest
@testable import Grabbit

final class TaskActionTests: XCTestCase {

    // MARK: - Download action visibility

    private let fullTail: [TaskAction] = [.delete, .openFolder, .copyLink, .details]

    func testDownloadActionsWhileDownloading() {
        XCTAssertEqual(
            TaskAction.actions(forDownload: .downloading),
            [.pause] + fullTail)
    }

    func testDownloadActionsWhilePaused() {
        XCTAssertEqual(
            TaskAction.actions(forDownload: .paused),
            [.resume] + fullTail)
    }

    func testDownloadActionsWhileInterrupted() {
        XCTAssertEqual(
            TaskAction.actions(forDownload: .interrupted),
            [.resume] + fullTail)
    }

    func testDownloadActionsWhileQueued() {
        XCTAssertEqual(
            TaskAction.actions(forDownload: .queued),
            [.resume] + fullTail)
    }

    func testDownloadActionsWhileFailed() {
        XCTAssertEqual(
            TaskAction.actions(forDownload: .failed),
            [.resume] + fullTail)
    }

    func testDownloadActionsWhenCompletedHidesResume() {
        XCTAssertEqual(TaskAction.actions(forDownload: .completed), fullTail)
    }

    // MARK: - Torrent action visibility

    func testTorrentActionsWhileDownloading() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .downloading, copyLinkAvailable: true),
            [.pause, .delete, .openFolder, .copyLink, .details])
    }

    func testTorrentActionsWhileSeeding() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .seeding, copyLinkAvailable: true),
            [.pause, .delete, .openFolder, .copyLink, .details])
    }

    func testTorrentActionsWhilePaused() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .paused, copyLinkAvailable: true),
            [.resume, .delete, .openFolder, .copyLink, .details])
    }

    func testTorrentActionsWhileFailedOffersRetry() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .failed, copyLinkAvailable: true),
            [.resume, .delete, .openFolder, .copyLink, .details])
    }

    func testTorrentActionsWhenCompletedHidesResume() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .completed, copyLinkAvailable: true),
            [.delete, .openFolder, .copyLink, .details])
    }

    func testTorrentActionsHideCopyLinkWhenNothingToCopy() {
        XCTAssertEqual(
            TaskAction.actions(forTorrentState: .downloading, copyLinkAvailable: false),
            [.pause, .delete, .openFolder, .details])
    }

    // MARK: - Copyable link

    private func torrentItem(magnet: String, source: String) -> TorrentItem {
        TorrentItem(
            name: "t", magnetURI: magnet, sourceURI: source,
            savePath: URL(fileURLWithPath: "/tmp"))
    }

    func testCopyableLinkPrefersMagnet() {
        let item = torrentItem(magnet: "magnet:?xt=urn:btih:aaa", source: "https://x/y.torrent")
        XCTAssertEqual(TaskAction.copyableLink(for: item), "magnet:?xt=urn:btih:aaa")
    }

    func testCopyableLinkFallsBackToSourceURI() {
        let item = torrentItem(magnet: "", source: "https://x/y.torrent")
        XCTAssertEqual(TaskAction.copyableLink(for: item), "https://x/y.torrent")
    }

    func testCopyableLinkNilWhenEmpty() {
        let item = torrentItem(magnet: "", source: "")
        XCTAssertNil(TaskAction.copyableLink(for: item))
    }

    // MARK: - FinderReveal.plan

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFinderRevealSelectsExistingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))

        let plan = FinderReveal.plan(directory: dir, named: "a.bin")
        XCTAssertTrue(plan.select)
        XCTAssertEqual(plan.target, file)
    }

    func testFinderRevealSelectsExistingDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let plan = FinderReveal.plan(directory: dir, named: "sub")
        XCTAssertTrue(plan.select)
        XCTAssertEqual(plan.target, sub)
    }

    func testFinderRevealOpensDirectoryWhenFileMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = FinderReveal.plan(directory: dir, named: "missing.bin")
        XCTAssertFalse(plan.select)
        XCTAssertEqual(plan.target, dir)
    }

    func testFinderRevealOpensDirectoryWhenUnnamed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = FinderReveal.plan(directory: dir, named: nil)
        XCTAssertFalse(plan.select)
        XCTAssertEqual(plan.target, dir)
    }
}
