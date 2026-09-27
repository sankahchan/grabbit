import Foundation

/// Keeps the aria2 tracker list fresh.
///
/// aria2 ships with no tracker list at all, so Grabbit announces a set of
/// public trackers (`--bt-tracker`) to every torrent. A compiled-in list rots:
/// trackers die, new ones appear. Like Motrix's daily auto-update, this
/// refreshes the list from ngosang/trackerslist `trackers_best` at most once
/// every 24 hours, caches it on disk, and pushes it into the running daemon
/// via RPC. The compiled-in `Aria2Daemon.defaultTrackers` stays as the
/// fallback — a failed refresh (offline, bad payload) never breaks
/// torrenting, it just keeps the old list.
enum TrackerUpdater {
    /// Raw `trackers_best.txt`: one announce URL per line.
    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt")!
    /// Minimum time between network refreshes.
    static let refreshInterval: TimeInterval = 24 * 3600

    // MARK: - Pure parsing

    /// Parses a `trackers_best.txt` payload into announce URLs.
    /// Pure — tested.
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Disk cache

    private static var supportDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Grabbit", isDirectory: true)
    }

    static var cacheFileURL: URL {
        supportDir.appendingPathComponent("trackers_best.txt")
    }

    static var cacheDateURL: URL {
        supportDir.appendingPathComponent("trackers_best.updated")
    }

    /// Cached list, or nil when nothing was ever cached (or it's unreadable).
    static func loadCache() -> [String]? {
        guard let text = try? String(contentsOf: cacheFileURL, encoding: .utf8) else {
            return nil
        }
        let trackers = parse(text)
        return trackers.isEmpty ? nil : trackers
    }

    static func saveCache(_ trackers: [String], at date: Date = Date()) {
        try? FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true)
        try? trackers.joined(separator: "\n").write(
            to: cacheFileURL, atomically: true, encoding: .utf8)
        try? String(date.timeIntervalSince1970).write(
            to: cacheDateURL, atomically: true, encoding: .utf8)
    }

    static func cacheUpdatedAt() -> Date? {
        guard let raw = try? String(contentsOf: cacheDateURL, encoding: .utf8),
              let interval = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// True when there is no cache yet, or the cache is older than
    /// `refreshInterval`. Pure given `now` — tested.
    static func needsRefresh(now: Date = Date()) -> Bool {
        guard let updated = cacheUpdatedAt() else { return true }
        return now.timeIntervalSince(updated) >= refreshInterval
    }

    // MARK: - Public API

    /// The tracker list to announce right now: the cached fresh list when
    /// one exists, otherwise the compiled-in defaults.
    static func currentTrackers() -> [String] {
        loadCache() ?? Aria2Daemon.defaultTrackers
    }

    static var currentTrackerList: String {
        currentTrackers().joined(separator: ",")
    }

    /// Fetches the latest list when due, caches it, and hands it to `apply`
    /// (the caller pushes it into the running daemon). Never throws: any
    /// failure silently keeps the previous list.
    static func refreshIfNeeded(
        autoUpdate: Bool,
        now: Date = Date(),
        apply: ([String]) async -> Void
    ) async {
        guard autoUpdate, needsRefresh(now: now) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let trackers = parse(text)
        guard !trackers.isEmpty else { return }
        saveCache(trackers, at: now)
        await apply(trackers)
    }
}
