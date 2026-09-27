import Foundation
import Observation

/// Unified, persistent log of finished tasks across the three engines
/// (direct downloads, torrents, media).
///
/// Entries are appended only on terminal *transitions* (completed/failed),
/// so app-restart recovery of already-finished items never double-records.
/// Persisted as JSON at `~/Library/Application Support/Grabbit/history.json`
/// with atomic writes; a corrupt file falls back to an empty history.
///
/// Recorded entries carry no secrets: `HistoryEntry` never stores request
/// headers or cookies (same invariant as `DownloadItem.CodingKeys`).
@Observable
public final class HistoryStore {
    /// Hard cap — oldest entries are pruned first.
    public static let maxEntries = 500

    public private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    /// `directory` is a test hook; production uses the app-support dir.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.entries = Self.load(from: fileURL)
    }

    // MARK: - Queries

    /// Entries for one kind, newest first; `nil` returns everything.
    public func entries(for kind: HistoryKind?) -> [HistoryEntry] {
        guard let kind else { return entries }
        return entries.filter { $0.kind == kind }
    }

    public func count(for kind: HistoryKind?) -> Int {
        entries(for: kind).count
    }

    // MARK: - Mutations

    /// Records an entry, newest-first. Upserts by id: a retried task that
    /// finishes again replaces its earlier outcome instead of duplicating.
    public func record(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Backfill

    /// One-time import of tasks that already finished before history
    /// existed. Only runs when the store is empty, so it can never
    /// duplicate entries recorded live. Oldest-first insertion keeps the
    /// newest-first order.
    public func backfillIfNeeded(downloads: [DownloadItem], torrents: [TorrentItem]) {
        guard entries.isEmpty else { return }
        var imported: [HistoryEntry] = []
        for item in downloads {
            switch item.state {
            case .completed: imported.append(.from(download: item, status: .completed))
            case .failed: imported.append(.from(download: item, status: .failed))
            default: break
            }
        }
        for item in torrents {
            switch item.state {
            case .completed: imported.append(.from(torrent: item, status: .completed))
            case .failed: imported.append(.from(torrent: item, status: .failed))
            default: break
            }
        }
        // MediaEngine is single-shot with no persisted task list — nothing
        // to backfill from.
        guard !imported.isEmpty else { return }
        entries = Array(imported.prefix(Self.maxEntries))
        save()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A corrupt file must never crash launch — fall back to empty.
        guard let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            NSLog("Grabbit: history.json corrupt, starting with empty history")
            return []
        }
        return Array(decoded.prefix(maxEntries))
    }

    /// Atomic write: tmp file on the same volume, then swapped into place
    /// (same pattern as `ResumeStore.save`).
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            do {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } catch {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            NSLog("Grabbit: failed to save history.json: \(error.localizedDescription)")
        }
    }
}
