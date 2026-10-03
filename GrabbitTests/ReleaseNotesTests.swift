import XCTest
@testable import Grabbit

/// "What's New": commit-message parsing and the show-once-per-update rule.
final class ReleaseNotesTests: XCTestCase {
    func testParseCommitMessage() {
        let text = """
        Release v1.5.0: media post-processing, RSS subscriptions, cookies import

        - Media downloads embed metadata, thumbnail, chapters and subtitles.
        - New RSS tab: feeds are polled every 30 minutes.

        387 tests / 0 failures.
        """
        let digest = ReleaseNotes.parse(text)
        XCTAssertEqual(
            digest.title,
            "v1.5.0: media post-processing, RSS subscriptions, cookies import")
        XCTAssertEqual(digest.bullets.count, 2)
        XCTAssertTrue(digest.bullets[0].hasPrefix("Media downloads embed"))
        XCTAssertTrue(digest.paragraphs.isEmpty)
        XCTAssertFalse(digest.isEmpty)
    }

    func testParseKeepsParagraphsAndDropsTestCount() {
        let text = """
        Release v1.4.2: remove the sidebar appearance row

        The theme cycle belongs to Settings only.

        406 tests / 0 failures.
        """
        let digest = ReleaseNotes.parse(text)
        XCTAssertEqual(digest.paragraphs, ["The theme cycle belongs to Settings only."])
        XCTAssertTrue(digest.bullets.isEmpty)
    }

    func testParseEmptyTextIsEmpty() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
    }

    func testShouldPresentOnlyAfterVersionChange() {
        XCTAssertFalse(ReleaseNotes.shouldPresent(lastSeen: nil, current: "1.5.0"))
        XCTAssertFalse(ReleaseNotes.shouldPresent(lastSeen: "", current: "1.5.0"))
        XCTAssertFalse(ReleaseNotes.shouldPresent(lastSeen: "1.5.0", current: "1.5.0"))
        XCTAssertTrue(ReleaseNotes.shouldPresent(lastSeen: "1.4.2", current: "1.5.0"))
    }
}
