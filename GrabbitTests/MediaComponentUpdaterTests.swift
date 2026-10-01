import XCTest
@testable import Grabbit

/// The in-app yt-dlp updater verifies the downloaded binary against the
/// release's published SHA2-256SUMS — these cover the parser it relies on.
final class MediaComponentUpdaterTests: XCTestCase {
    func testExpectedHashParsesStandardLines() {
        let sums = """
        abc123def  yt-dlp_linux
        F00BAAR  yt-dlp_macos
        99887766  yt-dlp_windows.zip
        """
        XCTAssertEqual(
            MediaComponentUpdater.expectedHash(for: "yt-dlp_macos", in: sums),
            "f00baar")
    }

    func testExpectedHashHandlesBinaryMarkerAndTabs() {
        XCTAssertEqual(
            MediaComponentUpdater.expectedHash(
                for: "yt-dlp_macos",
                in: "deadbeef  *yt-dlp_macos\n"),
            "deadbeef")
        XCTAssertEqual(
            MediaComponentUpdater.expectedHash(
                for: "yt-dlp_macos",
                in: "deadbeef\tyt-dlp_macos"),
            "deadbeef")
    }

    func testExpectedHashMissingAssetIsNil() {
        XCTAssertNil(MediaComponentUpdater.expectedHash(
            for: "yt-dlp_macos", in: "abc  yt-dlp_linux\n"))
        XCTAssertNil(MediaComponentUpdater.expectedHash(
            for: "yt-dlp_macos", in: ""))
        XCTAssertNil(MediaComponentUpdater.expectedHash(
            for: "yt-dlp_macos", in: "garbage-line\n"))
    }
}
