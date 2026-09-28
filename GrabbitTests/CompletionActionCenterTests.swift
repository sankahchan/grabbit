import XCTest
@testable import Grabbit

/// CompletionActionCenter: fires the configured action exactly when the
/// queue drains (something settled, nothing still running).
@MainActor
final class CompletionActionCenterTests: XCTestCase {
    func testNoneNeverFires() {
        let (center, fired) = makeCenter(action: .none, active: 0)
        center.taskDidSettle()
        XCTAssertTrue(fired.isEmpty)
    }

    func testDoesNotFireWhileTasksActive() {
        let (center, fired) = makeCenter(action: .sleep, active: 2)
        center.taskDidSettle()
        center.taskDidSettle()
        XCTAssertTrue(fired.isEmpty)
    }

    func testFiresWhenLastTaskSettles() {
        var active = 1
        let settings = SettingsStore()
        settings.settings.completionAction = .sleep
        var fired: [(CompletionAction, String)] = []
        let center = CompletionActionCenter(
            settings: settings,
            activeTaskCount: { active },
            executor: { fired.append(($0, $1)) })
        center.taskDidSettle()
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].0, .sleep)
    }

    func testFiresAgainOnNextDrain() {
        var active = 1
        let settings = SettingsStore()
        settings.settings.completionAction = .quitGrabbit
        var fired = 0
        let center = CompletionActionCenter(
            settings: settings,
            activeTaskCount: { active },
            executor: { _, _ in fired += 1 })
        active = 0
        center.taskDidSettle()
        XCTAssertEqual(fired, 1)
        // A later download drains the queue again -> fires again.
        active = 1
        center.taskDidSettle()
        active = 0
        center.taskDidSettle()
        XCTAssertEqual(fired, 2)
    }

    func testRunCommandPassesCommandThrough() {
        let settings = SettingsStore()
        settings.settings.completionAction = .runCommand
        settings.settings.completionCommand = "echo hi"
        var received: [(CompletionAction, String)] = []
        let center = CompletionActionCenter(
            settings: settings,
            activeTaskCount: { 0 },
            executor: { received.append(($0, $1)) })
        center.taskDidSettle()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].0, .runCommand)
        XCTAssertEqual(received[0].1, "echo hi")
    }

    // MARK: - Helpers

    private func makeCenter(
        action: CompletionAction, active: Int
    ) -> (CompletionActionCenter, [(CompletionAction, String)]) {
        let settings = SettingsStore()
        settings.settings.completionAction = action
        var fired: [(CompletionAction, String)] = []
        let center = CompletionActionCenter(
            settings: settings,
            activeTaskCount: { active },
            executor: { fired.append(($0, $1)) })
        return (center, fired)
    }
}
