import XCTest
@testable import Grabbit

final class NotchConflictTests: XCTestCase {
    func testDetectsNotchNamedApps() {
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["boringNotch"]))
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["NotchNook", "Finder"]))
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["notchy"]))
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["NotchDrop"]))
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["Grabbit", "Alcove"]))
        XCTAssertTrue(NotchController.hasConflictingNotchApp(["MediaMate"]))
    }

    func testIgnoresOrdinaryApps() {
        XCTAssertFalse(NotchController.hasConflictingNotchApp([]))
        XCTAssertFalse(NotchController.hasConflictingNotchApp(
            ["Safari", "Grabbit", "Finder", "Xcode", "Terminal"]))
        XCTAssertFalse(NotchController.hasConflictingNotchApp(["Snitch"]))
        XCTAssertFalse(NotchController.hasConflictingNotchApp(["Kindle"]))
    }
}
