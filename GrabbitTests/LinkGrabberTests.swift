import XCTest
@testable import Grabbit

/// Backlog #1 (LinkGrabber staging): pure staging logic with stubbed probe
/// and commit — no network, no download engine.
@MainActor
final class LinkGrabberTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeStore(
        prober: LinkGrabberStore.Prober? = nil,
        committer: LinkGrabberStore.Committer? = nil
    ) -> LinkGrabberStore {
        LinkGrabberStore(directory: tempDir(), prober: prober, committer: committer)
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Waits until no staged link is still `.checking` (probes settled).
    private func settle(_ store: LinkGrabberStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !store.links.contains(where: { $0.status == .checking }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Staging

    func testStageCreatesPackageAndLinks() {
        let store = makeStore()
        store.stage(
            urls: [url("https://a.com/1.zip"), url("https://a.com/2.zip")],
            packageName: "P")
        XCTAssertEqual(store.packages.count, 1)
        XCTAssertEqual(store.packages[0].name, "P")
        XCTAssertEqual(store.links.count, 2)
        XCTAssertTrue(store.links.allSatisfy { $0.status == .checking })
        XCTAssertTrue(store.links.allSatisfy(\.selected))
    }

    func testStageDedupsWithinBatch() {
        let store = makeStore()
        store.stage(
            urls: [
                url("https://a.com/1.zip"),
                url("https://a.com/1.zip"),
                url("https://a.com/2.zip"),
            ],
            packageName: "P")
        XCTAssertEqual(store.links.count, 3)
        let dups = store.links.filter { $0.status == .duplicate }
        XCTAssertEqual(dups.count, 1)
        // Duplicates start unselected so commit-all can't double-add.
        XCTAssertFalse(dups[0].selected)
    }

    func testStageDedupsAgainstAlreadyStaged() {
        let store = makeStore()
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P1")
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P2")
        XCTAssertEqual(store.packages.count, 2)
        XCTAssertEqual(store.links.filter { $0.status == .duplicate }.count, 1)
    }

    func testStageIgnoresEmpty() {
        let store = makeStore()
        store.stage(urls: [], packageName: "P")
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "  ")
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertTrue(store.links.isEmpty)
    }

    // MARK: - Probing

    func testProbeSetsOnlineOfflineAndSize() async {
        let store = makeStore(prober: { u in
            if u.absoluteString.contains("good") {
                return DownloadEngine.LinkProbe(online: true, totalBytes: 1234, filename: "real.zip")
            }
            return DownloadEngine.LinkProbe(online: false)
        })
        store.stage(
            urls: [url("https://a.com/good.zip"), url("https://a.com/bad.zip")],
            packageName: "P")
        await settle(store)
        let good = store.links.first { $0.url.absoluteString.contains("good") }!
        let bad = store.links.first { $0.url.absoluteString.contains("bad") }!
        XCTAssertEqual(good.status, .online)
        XCTAssertEqual(good.totalBytes, 1234)
        XCTAssertEqual(good.filename, "real.zip")
        XCTAssertEqual(bad.status, .offline)
        XCTAssertNil(bad.totalBytes)
    }

    func testProbeDoesNotClobberCustomizedFilename() {
        let store = makeStore()
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P")
        let id = store.links[0].id
        store.setFilename("mine.zip", for: id)
        XCTAssertEqual(store.links[0].filename, "mine.zip")
        XCTAssertTrue(store.links[0].filenameCustomized)
    }

    func testDisplayName() {
        XCTAssertEqual(
            LinkGrabberStore.displayName(for: url("https://a.com/files/a%20b.zip")),
            "a b.zip")
        XCTAssertEqual(
            LinkGrabberStore.displayName(for: url("https://a.com/")),
            "a.com")
    }

    // MARK: - Commit

    func testCommitCallsCommitterAndRemovesLinks() async {
        var committed: [URL] = []
        let store = makeStore(
            prober: { _ in DownloadEngine.LinkProbe(online: true, totalBytes: 10) },
            committer: { committed.append($0.url) })
        store.stage(
            urls: [url("https://a.com/1.zip"), url("https://a.com/2.zip")],
            packageName: "P")
        await settle(store)
        let ids = await store.commitSelected()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(committed.map(\.absoluteString)),
                       Set(["https://a.com/1.zip", "https://a.com/2.zip"]))
        XCTAssertTrue(store.links.isEmpty)
        // Empty packages are pruned after commit.
        XCTAssertTrue(store.packages.isEmpty)
    }

    func testCommitSkipsDuplicates() async {
        var committed: [URL] = []
        let store = makeStore(
            prober: { _ in DownloadEngine.LinkProbe(online: true) },
            committer: { committed.append($0.url) })
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P1")
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P2")
        await settle(store)
        // Force-select the duplicate the way a user could.
        let dup = store.links.first { $0.status == .duplicate }!
        store.setSelected(true, for: dup.id)
        let ids = await store.commitSelected()
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(committed.count, 1)
        // The duplicate stays staged for inspection.
        XCTAssertEqual(store.links.count, 1)
        XCTAssertEqual(store.links[0].status, .duplicate)
    }

    func testCommitWithoutCommitterIsNoOp() async {
        let store = makeStore()
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P")
        let ids = await store.commitSelected()
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(store.links.count, 1)
    }

    // MARK: - Editing

    func testRemovePackageRemovesItsLinks() {
        let store = makeStore()
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P1")
        store.stage(urls: [url("https://b.com/2.zip")], packageName: "P2")
        store.removePackage(store.packages[0].id)
        XCTAssertEqual(store.packages.count, 1)
        XCTAssertEqual(store.links.count, 1)
        XCTAssertEqual(store.links[0].url.host, "b.com")
    }

    func testSelectAllSkipsDuplicates() {
        let store = makeStore()
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P1")
        store.stage(urls: [url("https://a.com/1.zip")], packageName: "P2")
        store.setAllSelected(false)
        XCTAssertTrue(store.links.allSatisfy { !$0.selected })
        store.setAllSelected(true)
        XCTAssertEqual(store.links.filter(\.selected).count, 1)
        XCTAssertEqual(store.links.first(where: \.selected)?.status, .checking)
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() {
        let dir = tempDir()
        let first = LinkGrabberStore(directory: dir)
        first.stage(urls: [url("https://a.com/1.zip")], packageName: "P")
        first.renamePackage(first.packages[0].id, to: "Renamed")
        let second = LinkGrabberStore(directory: dir)
        XCTAssertEqual(second.packages.count, 1)
        XCTAssertEqual(second.packages[0].name, "Renamed")
        XCTAssertEqual(second.links.count, 1)
        XCTAssertEqual(second.links[0].url.absoluteString, "https://a.com/1.zip")
    }
}
