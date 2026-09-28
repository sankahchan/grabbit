import Foundation
import Observation

/// Phase 5 named queues: persisted queue list + the pure capacity planner.
///
/// Entries live as JSON at `~/Library/Application Support/Grabbit/queues.json`
/// (atomic writes; a corrupt file falls back to a fresh default queue).
/// The default queue is always present and can never be deleted.
@Observable
public final class QueueStore {
    public private(set) var queues: [DownloadQueue] = []

    private let fileURL: URL

    /// `directory` is a test hook; production uses the app-support dir.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("queues.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var loaded = Self.load(from: fileURL) ?? []
        if !loaded.contains(where: \.isDefault) {
            loaded.insert(DownloadQueue(maxConcurrent: 5, isDefault: true), at: 0)
        }
        // The default queue always leads.
        loaded.sort { $0.isDefault && !$1.isDefault }
        self.queues = loaded
    }

    /// The default queue (never deleted).
    public var defaultQueue: DownloadQueue {
        queues.first(where: \.isDefault) ?? DownloadQueue(maxConcurrent: 5, isDefault: true)
    }

    /// Resolves a task's queue: nil or an unknown (deleted) id → default.
    public func queue(for id: UUID?) -> DownloadQueue {
        id.flatMap { wanted in queues.first(where: { $0.id == wanted }) } ?? defaultQueue
    }

    public func add(name: String, maxConcurrent: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queues.append(DownloadQueue(
            name: trimmed,
            maxConcurrent: max(1, maxConcurrent)))
        save()
    }

    /// Returns false when the id is unknown or is the default queue.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = queues.firstIndex(where: { $0.id == id }),
              !queues[index].isDefault
        else { return false }
        queues.remove(at: index)
        save()
        return true
    }

    public func update(_ queue: DownloadQueue) {
        guard let index = queues.firstIndex(where: { $0.id == queue.id }) else { return }
        var fixed = queue
        // The default queue keeps its identity and its localized name.
        fixed.isDefault = queues[index].isDefault
        if fixed.isDefault { fixed.name = "" }
        fixed.maxConcurrent = max(1, fixed.maxConcurrent)
        queues[index] = fixed
        // No re-sort: the default queue is inserted first at init, `add`
        // appends, and `remove` can never drop the default — so it stays
        // put without disturbing row order on every keystroke.
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(queues)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: the in-memory list stays authoritative.
        }
    }

    private static func load(from url: URL) -> [DownloadQueue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([DownloadQueue].self, from: data)
    }
}

// MARK: - Pure capacity planner

/// Decides which queued downloads may start under the per-queue and global
/// caps. Pure (no engine needed) so it's unit-testable; the engine applies
/// the result via `start(_:)`.
enum QueuePlanner {
    /// - Returns: queued items that may start now — per queue, highest
    ///   priority first, then list position (drag-reorder) — cycling
    ///   through queues in store order until the caps fill.
    static func startable(
        items: [DownloadItem],
        queues: [DownloadQueue],
        defaultQueue: DownloadQueue,
        globalMaxActive: Int
    ) -> [DownloadItem] {
        let globalMax = max(1, globalMaxActive)
        // The store guarantees a non-empty list; stay total anyway.
        let orderedQueues = queues.isEmpty ? [defaultQueue] : queues
        func effectiveID(_ item: DownloadItem) -> UUID {
            if let id = item.queueID, queues.contains(where: { $0.id == id }) {
                return id
            }
            return defaultQueue.id
        }
        func cap(for queueID: UUID) -> Int {
            let q = queues.first(where: { $0.id == queueID }) ?? defaultQueue
            return max(1, q.maxConcurrent)
        }

        var activeByQueue: [UUID: Int] = [:]
        var globalActive = 0
        for item in items where item.state == .downloading {
            let qid = effectiveID(item)
            activeByQueue[qid, default: 0] += 1
            globalActive += 1
        }

        var result: [DownloadItem] = []
        var startedIDs = Set<UUID>()
        var progressed = true
        // Backlog #7: queue start order — priority first (higher starts
        // sooner), then list position (drag-reorder defines it).
        let orderedItems = items.enumerated()
            .sorted {
                if $0.element.priority != $1.element.priority {
                    return $0.element.priority > $1.element.priority
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
        while progressed && globalActive < globalMax {
            progressed = false
            for queue in orderedQueues {
                guard globalActive < globalMax,
                      (activeByQueue[queue.id] ?? 0) < cap(for: queue.id)
                else { continue }
                if let next = orderedItems.first(where: {
                    $0.state == .queued
                        && !startedIDs.contains($0.id)
                        && effectiveID($0) == queue.id
                }) {
                    result.append(next)
                    startedIDs.insert(next.id)
                    activeByQueue[queue.id, default: 0] += 1
                    globalActive += 1
                    progressed = true
                }
            }
        }
        return result
    }
}
