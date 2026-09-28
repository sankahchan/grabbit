import XCTest
@testable import Grabbit

/// Phase 5 scheduler backend: firing predicate + store persistence.
final class SchedulerTests: XCTestCase {

    private func entry(
        at time: Date,
        weekdays: Int = ScheduleEntry.allWeekdays,
        isEnabled: Bool = true,
        lastFired: Date? = nil
    ) -> ScheduleEntry {
        var e = ScheduleEntry(time: time, action: .download, weekdays: weekdays)
        e.isEnabled = isEnabled
        e.lastFired = lastFired
        return e
    }

    /// Builds a `now` on a known Sunday (2026-10-04) at the given time so
    /// weekday assertions are deterministic regardless of the real date.
    private func sunday(atHour hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 4 // a Sunday
        comps.hour = hour; comps.minute = minute
        let date = cal.date(from: comps)!
        XCTAssertEqual(cal.component(.weekday, from: date), 1)
        return date
    }

    // MARK: - isDue

    func testFiresWhenTimeAndWeekdayMatch() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = sunday(atHour: 2, minute: 30)
        let entry = entry(at: now, weekdays: 1 << 0) // Sunday bit
        XCTAssertTrue(SchedulerStore.isDue(entry, now: now, calendar: cal))
    }

    func testDoesNotFireWhenDisabled() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = sunday(atHour: 2, minute: 30)
        XCTAssertFalse(SchedulerStore.isDue(
            entry(at: now, isEnabled: false), now: now, calendar: cal))
    }

    func testDoesNotFireOnUnselectedWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = sunday(atHour: 2, minute: 30)
        // Monday bit only.
        XCTAssertFalse(SchedulerStore.isDue(
            entry(at: now, weekdays: 1 << 1), now: now, calendar: cal))
    }

    func testDoesNotFireAtWrongMinute() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = sunday(atHour: 2, minute: 30)
        let entryTime = cal.date(byAdding: .minute, value: 1, to: now)!
        XCTAssertFalse(SchedulerStore.isDue(
            entry(at: entryTime), now: now, calendar: cal))
    }

    func testFiresAtMostOncePerDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = sunday(atHour: 2, minute: 30)
        // Fired an hour ago today -> not due again.
        let firedToday = cal.date(byAdding: .hour, value: -1, to: now)!
        XCTAssertFalse(SchedulerStore.isDue(
            entry(at: now, lastFired: firedToday), now: now, calendar: cal))
        // Fired yesterday -> due again.
        let firedYesterday = cal.date(byAdding: .day, value: -1, to: now)!
        XCTAssertTrue(SchedulerStore.isDue(
            entry(at: now, lastFired: firedYesterday), now: now, calendar: cal))
    }

    // MARK: - Persistence

    func testEntriesPersistAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SchedulerStore(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
        var e = ScheduleEntry(time: Date(), action: .stop)
        e.isEnabled = false
        store.add(e)
        let reloaded = SchedulerStore(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].id, e.id)
        XCTAssertEqual(reloaded.entries[0].action, .stop)
        XCTAssertFalse(reloaded.entries[0].isEnabled)
    }

    func testUpdateAndRemovePersist() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SchedulerStore(directory: dir)
        let e = ScheduleEntry(time: Date(), action: .download)
        store.add(e)
        var updated = e
        updated.weekdays = 1 << 1
        store.update(updated)
        XCTAssertEqual(store.entries[0].weekdays, 1 << 1)
        store.remove(id: e.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(SchedulerStore(directory: dir).entries.isEmpty)
    }

    // MARK: - Backlog #8: speed profiles

    func testSpeedLimitEntryPersists() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SchedulerStore(directory: dir)
        var e = ScheduleEntry(time: Date(), action: .speedLimit)
        e.speedLimitBytesPerSec = 512 * 1_024
        store.add(e)
        let reloaded = SchedulerStore(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].action, .speedLimit)
        XCTAssertEqual(reloaded.entries[0].speedLimitBytesPerSec, 512 * 1_024)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(
            to: dir.appendingPathComponent("schedule.json"),
            atomically: true, encoding: .utf8)
        XCTAssertTrue(SchedulerStore(directory: dir).entries.isEmpty)
    }
}
