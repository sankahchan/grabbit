import Foundation
import Observation

/// A watched folder: dropping a `.txt` file (one link per line) into it
/// adds every new link as a download. Duplicates (already listed or in
/// History) are skipped, and processed files are moved to the Trash.
public struct WatchFolder: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var path: String
    public var isEnabled: Bool = true

    public init(id: UUID = UUID(), path: String, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
    }
}

/// Phase 5 watch folders: persisted folder list (`watchfolders.json`,
/// atomic writes, corrupt-file fallback).
@Observable
public final class WatchFolderStore {
    public private(set) var folders: [WatchFolder] = []

    private let fileURL: URL

    /// `directory` is a test hook; production uses the app-support dir.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("watchfolders.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.folders = Self.load(from: fileURL) ?? []
    }

    public func add(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir),
              isDir.boolValue
        else { return }
        guard !folders.contains(where: { $0.path == trimmed }) else { return }
        folders.append(WatchFolder(path: trimmed))
        save()
    }

    public func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(id: UUID, enabled: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isEnabled = enabled
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: the in-memory list stays authoritative.
        }
    }

    private static func load(from url: URL) -> [WatchFolder]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WatchFolder].self, from: data)
    }
}

// MARK: - Scan helper (pure, testable)

/// Selects the `.txt` files ready for processing.
enum WatchFolderScan {
    /// - Parameters:
    ///   - processed: file paths already handled this launch.
    ///   - settleSeconds: only files untouched for this long qualify —
    ///     avoids reading a file that's still being copied in.
    static func pendingFiles(
        in directory: URL,
        processed: Set<String>,
        settleSeconds: TimeInterval = 3,
        now: Date = Date()
    ) -> [URL] {
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var out: [URL] = []
        for url in candidates {
            guard !processed.contains(url.path),
                  url.pathExtension.lowercased() == "txt"
            else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(mtime) >= settleSeconds else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }
}

// MARK: - Monitor

/// Polls the watched folders and feeds new links into the download engine.
public final class WatchFolderMonitor {
    private var timer: Timer?
    private var processedPaths: Set<String> = []
    private var isScanning = false

    public init() {}

    /// Starts the 5-second poll plus one immediate scan.
    public func start(
        store: WatchFolderStore,
        engine: DownloadEngine,
        history: HistoryStore
    ) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scan(store: store, engine: engine, history: history)
            }
        }
        Task { @MainActor in
            await self.scan(store: store, engine: engine, history: history)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func scan(
        store: WatchFolderStore,
        engine: DownloadEngine,
        history: HistoryStore
    ) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        // Dedup: anything already in the list or in History is skipped.
        var known = Set(engine.items.map { $0.url.absoluteString })
            .union(history.entries.map(\.sourceURL))
        for folder in store.folders where folder.isEnabled {
            let dir = URL(fileURLWithPath: folder.path, isDirectory: true)
            for file in WatchFolderScan.pendingFiles(in: dir, processed: processedPaths) {
                processedPaths.insert(file.path)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for url in BatchLinkParser.parse(text) where !known.contains(url.absoluteString) {
                    known.insert(url.absoluteString)
                    await engine.add(url: url)
                }
                // Move aside so a relaunch never reprocesses it.
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }
}
