import XCTest
@testable import Grabbit

final class NotchMoodPickerTests: XCTestCase {
    func testIdleDefaults() {
        let mood = NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false, hour: 12)
        XCTAssertEqual(mood, .idle)
    }

    func testIdleOfferWins() {
        let mood = NotchMoodPicker.idleMood(
            offer: true, vpnBlocked: true, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true, hour: 12)
        XCTAssertEqual(mood, .excited)
    }

    func testIdlePriority() {
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: true, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true, hour: 12), .alert)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: true,
            probing: true, diskLow: true, allPausedWithTasks: true, hour: 12), .seeding)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: true, diskLow: true, allPausedWithTasks: true, hour: 12), .thinking)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: true, allPausedWithTasks: true, hour: 12), .worried)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: true, hour: 12), .sleeping)
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

// MARK: - Time-of-day + stalled (Mochi personality)

extension NotchMoodPickerTests {
    func testNightSleepsMorningStretches() {
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false,
            hour: 23), .sleeping)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false,
            hour: 3), .sleeping)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false,
            hour: 7), .stretch)
        XCTAssertEqual(NotchMoodPicker.idleMood(
            offer: false, vpnBlocked: false, seeding: false,
            probing: false, diskLow: false, allPausedWithTasks: false,
            hour: 12), .idle)
    }

    func testStalledDownloadsWorry() {
        XCTAssertEqual(NotchMoodPicker.activeMood(
            vpnBlocked: false, speed: 0, progress: 0.5, stalled: true),
            .worried)
        XCTAssertEqual(NotchMoodPicker.activeMood(
            vpnBlocked: false, speed: 0, progress: 0.5, stalled: false),
            .working(0.5))
    }
}
