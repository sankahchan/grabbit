import XCTest
@testable import Grabbit

/// TorrentFileTree: flat aria2 file lists become a collapsed folder tree
/// with sizes, descendant indices, and tri-state folder selection.
final class TorrentFileTreeTests: XCTestCase {
    private func sampleFiles() -> [Aria2File] {
        [
            Aria2File(index: 1, path: "/dl/T/sub/a.mkv", length: 100, completedLength: 0, selected: true),
            Aria2File(index: 2, path: "/dl/T/sub/b.mkv", length: 200, completedLength: 0, selected: true),
            Aria2File(index: 3, path: "/dl/T/c.mkv", length: 300, completedLength: 0, selected: false),
        ]
    }

    func testBuildCollapsesCommonPrefix() {
        let roots = TorrentFileTree.build(from: sampleFiles())
        // /dl/T collapses away; roots are [sub (dir), c.mkv].
        XCTAssertEqual(roots.count, 2)
        let dir = roots[0]
        XCTAssertTrue(dir.isDirectory)
        XCTAssertEqual(dir.name, "sub")
        XCTAssertEqual(dir.children.count, 2)
        XCTAssertEqual(roots[1].name, "c.mkv")
        XCTAssertEqual(roots[1].fileIndex, 3)
    }

    func testDirectorySizeIsSumOfChildren() {
        let roots = TorrentFileTree.build(from: sampleFiles())
        XCTAssertEqual(roots[0].size, 300)
    }

    func testDescendantIndices() {
        let roots = TorrentFileTree.build(from: sampleFiles())
        XCTAssertEqual(TorrentFileTree.descendantIndices(of: roots[0]), [1, 2])
        XCTAssertEqual(TorrentFileTree.descendantIndices(of: roots[1]), [3])
    }

    func testFolderSelectionStates() {
        let roots = TorrentFileTree.build(from: sampleFiles())
        let dir = roots[0]
        XCTAssertEqual(
            TorrentFileTree.selection(of: dir, selected: [1, 2, 3]), .all)
        XCTAssertEqual(
            TorrentFileTree.selection(of: dir, selected: []), .none)
        XCTAssertEqual(
            TorrentFileTree.selection(of: dir, selected: [1, 3]), .some)
    }

    func testSingleFileTorrent() {
        let files = [
            Aria2File(index: 1, path: "/dl/movie.mkv", length: 50, completedLength: 0, selected: true),
        ]
        let roots = TorrentFileTree.build(from: files)
        XCTAssertEqual(roots.count, 1)
        XCTAssertFalse(roots[0].isDirectory)
        XCTAssertEqual(roots[0].fileIndex, 1)
    }

    func testEmptyFiles() {
        XCTAssertTrue(TorrentFileTree.build(from: []).isEmpty)
    }

    func testSwarmHealth() {
        XCTAssertEqual(SwarmHealth.of(seeders: 0), .poor)
        XCTAssertEqual(SwarmHealth.of(seeders: 1), .fair)
        XCTAssertEqual(SwarmHealth.of(seeders: 4), .fair)
        XCTAssertEqual(SwarmHealth.of(seeders: 5), .healthy)
        XCTAssertEqual(SwarmHealth.of(seeders: 100), .healthy)
    }
}
