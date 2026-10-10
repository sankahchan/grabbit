import XCTest
@testable import Grabbit

final class NotchMoodPickerTests: XCTestCase {
    func testIdleDefaults() {
        let mood = NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false)
        XCTAssertEqual(mood, .idle)
    }

    func testIdleOfferWins() {
        let mood = NotchMoodPicker.idleMood(
            offer: true, vpnBlocked: true, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true)
        XCTAssertEqual(mood, .excited)
    }

    func testIdlePriority() {
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: true, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true), .alert)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true), .seeding)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: true, diskLow: true, allPausedWithTasks: true), .thinking)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: true, allPausedWithTasks: true), .worried)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: true), .sleeping)
    }

    func testActiveMoods() {
        XCTAssertEqual(NotchMoodPicker.activeMood(
            vpnBlocked: true, speed: 0, progress: 0.4), .alert)
        XCTAssertEqual(NotchMoodPicker.activeMood(
            vpnBlocked: false, speed: NotchMoodPicker.turboThreshold, progress: 0.4),
            .turbo)
        XCTAssertEqual(NotchMoodPicker.activeMood(
            vpnBlocked: false, speed: 1_000_000, progress: 0.4),
            .working(0.4))
    }
}
