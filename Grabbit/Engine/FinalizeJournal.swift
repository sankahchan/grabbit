import Foundation

/// Lightweight durable-finalize journal (Motrix-inspired, without the
/// plugin machinery).
///
/// Crash window it closes: the finished file has been moved into place but
/// the app died before the completion was persisted/recorded. Without the
/// journal, relaunch sees a `.downloading` item whose partial file is gone
/// and re-downloads from scratch.
///
/// Flow: `finalize` writes the record BEFORE moving the file into place,
/// marks `historyRecorded` after the history entry is written, and deletes
/// the record once the item is persisted or removed. `allRecords()` is
/// scanned at launch (`reconcileFinalizeJournals`) to complete any leftover
/// records instead of re-downloading.
///
/// Each record is one atomic JSON file: `<States>/finalize/<uuid>.json`.
public struct FinalizeRecord: Codable, Sendable {
    public var itemID: UUID
    public var destinationPath: String
    public var filename: String
    public var totalBytes: Int64?
    public var historyRecorded: Bool
    public var extractRequested: Bool
    public var extractDone: Bool

    public init(
        itemID: UUID,
        destinationPath: String,
        filename: String,
        totalBytes: Int64? = nil,
        historyRecorded: Bool = false,
        extractRequested: Bool = false,
        extractDone: Bool = false
    ) {
        self.itemID = itemID
        self.destinationPath = destinationPath
        self.filename = filename
        self.totalBytes = totalBytes
        self.historyRecorded = historyRecorded
        self.extractRequested = extractRequested
        self.extractDone = extractDone
    }
}

public final class FinalizeJournal: Sendable {
    private let directory: URL

    public init(resumeDirectory: URL) {
        let dir = resumeDirectory.appendingPathComponent("finalize", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Atomic write (tmp + move on the same volume — a crash can only leave
    /// a stale or complete record, never a torn one).
    public func write(_ record: FinalizeRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let dest = url(for: record.itemID)
        let tmp = dest.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            do {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } catch {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    public func update(_ id: UUID, mutate: (inout FinalizeRecord) -> Void) {
        guard let data = try? Data(contentsOf: url(for: id)),
              var record = try? JSONDecoder().decode(FinalizeRecord.self, from: data)
        else { return }
        mutate(&record)
        write(record)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Every leftover record (corrupt files are skipped — one bad record
    /// must never block the rest).
    public func allRecords() -> [FinalizeRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(FinalizeRecord.self, from: data)
                else { return nil }
                return record
            }
    }
}
