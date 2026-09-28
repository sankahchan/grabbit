import XCTest
@testable import Grabbit

/// Durable finalize: a crash between "file moved into place" and
/// "completion persisted/recorded" must reconcile at launch instead of
/// re-downloading from scratch.
final class FinalizeJournalTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testJournalRoundTrip() {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = FinalizeJournal(resumeDirectory: dir)
        let id = UUID()
        journal.write(FinalizeRecord(
            itemID: id, destinationPath: "/tmp/f.zip", filename: "f.zip"))
        XCTAssertEqual(journal.allRecords().count, 1)
        journal.update(id) { $0.historyRecorded = true }
        XCTAssertEqual(journal.allRecords().first?.historyRecorded, true)
        journal.delete(id)
        XCTAssertTrue(journal.allRecords().isEmpty)
    }

    @MainActor
    func testReconcileCompletesWithoutRedownload() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The finished file made it to its destination...
        let dest = dir.appendingPathComponent("f.zip")
        try Data("done".utf8).write(to: dest)
        // ...but the app crashed mid-finalize (journal left behind).
        let id = UUID()
        let store = ResumeStore(directory: dir)
        try store.save(DownloadItem(
            id: id,
            url: URL(string: "https://example.com/f.zip")!,
            filename: "f.zip",
            state: .interrupted,
            destinationURL: dest))
        let historyDir = dir.appendingPathComponent("history", isDirectory: true)
        let history = HistoryStore(directory: historyDir)
        FinalizeJournal(resumeDirectory: dir).write(FinalizeRecord(
            itemID: id,
            destinationPath: dest.path,
            filename: "f.zip",
            totalBytes: 4))
        let settings = SettingsStore()
        settings.settings.autoClearFinished = false
        let engine = DownloadEngine(
            resumeStore: store, history: history, settings: settings)

        engine.reconcileFinalizeJournals()

        XCTAssertEqual(engine.items.first?.state, .completed)
        XCTAssertEqual(engine.items.first?.downloadedBytes, 4)
        XCTAssertEqual(history.entries.count, 1)
        // Journal consumed.
        XCTAssertTrue(FinalizeJournal(resumeDirectory: dir).allRecords().isEmpty)
    }

    @MainActor
    func testReconcileDoesNotDuplicateHistory() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("g.zip")
        try Data("done".utf8).write(to: dest)
        let id = UUID()
        let store = ResumeStore(directory: dir)
        try store.save(DownloadItem(
            id: id,
            url: URL(string: "https://example.com/g.zip")!,
            filename: "g.zip",
            state: .interrupted,
            destinationURL: dest))
        let history = HistoryStore(
            directory: dir.appendingPathComponent("history", isDirectory: true))
        // Crash happened AFTER history.record but before journal delete.
        FinalizeJournal(resumeDirectory: dir).write(FinalizeRecord(
            itemID: id,
            destinationPath: dest.path,
            filename: "g.zip",
            historyRecorded: true))
        let settings = SettingsStore()
        settings.settings.autoClearFinished = false
        let engine = DownloadEngine(
            resumeStore: store, history: history, settings: settings)

        engine.reconcileFinalizeJournals()

        XCTAssertEqual(engine.items.first?.state, .completed)
        XCTAssertTrue(history.entries.isEmpty)
    }

    @MainActor
    func testReconcileDropsJournalWhenFileNeverArrived() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Crash BEFORE the move: no file at the destination.
        let dest = dir.appendingPathComponent("h.zip")
        let id = UUID()
        let store = ResumeStore(directory: dir)
        try store.save(DownloadItem(
            id: id,
            url: URL(string: "https://example.com/h.zip")!,
            filename: "h.zip",
            state: .interrupted,
            destinationURL: dest))
        let history = HistoryStore(
            directory: dir.appendingPathComponent("history", isDirectory: true))
        FinalizeJournal(resumeDirectory: dir).write(FinalizeRecord(
            itemID: id, destinationPath: dest.path, filename: "h.zip"))
        let settings = SettingsStore()
        settings.settings.autoClearFinished = false
        let engine = DownloadEngine(
            resumeStore: store, history: history, settings: settings)

        engine.reconcileFinalizeJournals()

        // Item untouched (normal resume path owns it); journal dropped.
        XCTAssertEqual(engine.items.first?.state, .interrupted)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(FinalizeJournal(resumeDirectory: dir).allRecords().isEmpty)
    }

    // MARK: - Extraction journal lifecycle

    /// A kill mid-extract leaves extractRequested && !extractDone. The
    /// reconcile retry must keep the journal when extraction fails, so the
    /// NEXT launch retries again — never silently dropping the retry.
    @MainActor
    func testReconcileKeepsJournalWhenExtractRetryFails() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Garbage bytes named .zip — ditto will fail on this.
        let dest = dir.appendingPathComponent("f.zip")
        try Data("not a zip".utf8).write(to: dest)
        let id = UUID()
        FinalizeJournal(resumeDirectory: dir).write(FinalizeRecord(
            itemID: id,
            destinationPath: dest.path,
            filename: "f.zip",
            totalBytes: 9,
            historyRecorded: true,
            extractRequested: true,
            extractDone: false))
        let settings = SettingsStore()
        settings.settings.autoClearFinished = false
        settings.settings.autoExtractArchives = true
        let engine = DownloadEngine(
            resumeStore: ResumeStore(directory: dir),
            history: HistoryStore(directory: dir.appendingPathComponent("history", isDirectory: true)),
            settings: settings)

        engine.reconcileFinalizeJournals()

        // Give the detached retry a moment to attempt (and fail).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        // The failed retry must NOT have consumed the journal.
        XCTAssertEqual(FinalizeJournal(resumeDirectory: dir).allRecords().count, 1)
    }

    /// ...and must consume the journal once the retry succeeds.
    @MainActor
    func testReconcileDeletesJournalAfterSuccessfulExtractRetry() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Build a real zip with ditto.
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: srcDir.appendingPathComponent("a.txt"))
        let dest = dir.appendingPathComponent("f.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", srcDir.path, dest.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let id = UUID()
        FinalizeJournal(resumeDirectory: dir).write(FinalizeRecord(
            itemID: id,
            destinationPath: dest.path,
            filename: "f.zip",
            historyRecorded: true,
            extractRequested: true,
            extractDone: false))
        let settings = SettingsStore()
        settings.settings.autoClearFinished = false
        settings.settings.autoExtractArchives = true
        let engine = DownloadEngine(
            resumeStore: ResumeStore(directory: dir),
            history: HistoryStore(directory: dir.appendingPathComponent("history", isDirectory: true)),
            settings: settings)

        engine.reconcileFinalizeJournals()

        // The detached retry should extract and then consume the journal.
        let deadline = Date().addingTimeInterval(15)
        var journalEmpty = false
        while Date() < deadline, !journalEmpty {
            Thread.sleep(forTimeInterval: 0.2)
            journalEmpty = FinalizeJournal(resumeDirectory: dir).allRecords().isEmpty
        }
        XCTAssertTrue(journalEmpty, "journal should be consumed after a successful extract retry")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("f/a.txt").path))
    }
}
