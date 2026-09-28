import Foundation

/// Crash-safe persistence for in-progress downloads.
///
/// Each `DownloadItem` (including per-segment `receivedBytes` offsets) is
/// encoded to JSON in `~/Library/Application Support/Grabbit/States`.
///
/// Partial (incomplete) download *data* lives next to the final destination at
/// `<destination>.grabbit-part` until the download completes, then it is moved
/// into place. Keeping the partial file separate means an interrupted download
/// never leaves a corrupt-looking "complete" file at the destination, and the
/// recorded segment offsets stay valid across launches.
public final class ResumeStore {
    public let directory: URL
    private var autosaveTimer: DispatchSourceTimer?

    public convenience init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit/States", isDirectory: true)
        self.init(directory: base)
    }

    /// Test seam: point the store at a scratch directory.
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        stopAutosave()
    }

    // MARK: - State files

    private func stateURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Saves one item atomically: the JSON is first written to
    /// `<uuid>.json.tmp` on the *same volume*, then swapped over `<uuid>.json`
    /// with `replaceItemAt`. A crash mid-write can therefore only leave a stale
    /// or complete state file behind — never a torn one.
    public func save(_ item: DownloadItem) throws {
        let data = try JSONEncoder().encode(item)
        let destination = stateURL(for: item.id)
        let tmp = destination.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } catch {
            // First save for this item: there is no .json to replace yet, so
            // move the temp file into place (atomic on the same volume).
            // A failure here (e.g. permissions) still throws to the caller.
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    public func saveAll(_ items: [DownloadItem]) {
        for item in items {
            try? save(item)
        }
    }

    /// Loads every saved state file. Corrupt files are skipped (a single bad
    /// file must never prevent the rest from resuming); leftover `.tmp` files
    /// from a crashed save are ignored.
    public func loadAll() -> [DownloadItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let item = try? decoder.decode(DownloadItem.self, from: data)
                else { return nil }
                return item
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: stateURL(for: id))
    }

    // MARK: - Partial data files

    /// URL of the in-progress data file for an item: `<destination>.grabbit-part`.
    public func partialFileURL(for item: DownloadItem) -> URL {
        item.destinationURL.appendingPathExtension("grabbit-part")
    }

    // MARK: - Autosave

    /// Periodically persists whatever `provider()` returns. The provider is
    /// invoked on the main thread (where the engine performs its `@MainActor`
    /// mutations) and the actual writes happen on the timer's utility queue.
    public func startAutosave(every interval: TimeInterval, provider: @escaping () -> [DownloadItem]) {
        stopAutosave()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.sankahchan.grabbit.resume-autosave", qos: .utility)
        )
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let items: [DownloadItem]
            if Thread.isMainThread {
                items = provider()
            } else {
                items = DispatchQueue.main.sync(execute: provider)
            }
            self.saveAll(items)
        }
        timer.resume()
        autosaveTimer = timer
    }

    public func stopAutosave() {
        autosaveTimer?.cancel()
        autosaveTimer = nil
    }
}
