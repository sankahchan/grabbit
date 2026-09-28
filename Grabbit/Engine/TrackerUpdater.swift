import Foundation

/// Keeps the aria2 tracker list fresh.
///
/// aria2 ships with no tracker list at all, so Grabbit announces a set of
/// public trackers (`--bt-tracker`) to every torrent. A compiled-in list rots:
/// trackers die, new ones appear. Like Motrix, this refreshes from multiple
/// sources (each with CDN fallbacks), UDP-probes the merged list to drop
/// dead trackers, caches the healthy list on disk, and pushes it into the
/// running daemon via RPC. The compiled-in `Aria2Daemon.defaultTrackers`
/// stays as the fallback — a failed refresh (offline, bad payload) never
/// breaks torrenting, it just keeps the old list.
enum TrackerUpdater {
    /// One tracker list with mirrors in preference order.
    struct TrackerSource: Sendable {
        let id: String
        let urls: [URL]
    }

    /// Motrix's source set: ngosang/trackerslist + DeSireFire/animeTrackerList,
    /// each reachable directly and via the jsDelivr CDN mirror.
    static let sources: [TrackerSource] = [
        TrackerSource(id: "ngosang", urls: [
            URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt")!,
            URL(string: "https://cdn.jsdelivr.net/gh/ngosang/trackerslist/trackers_best.txt")!,
        ]),
        TrackerSource(id: "animeTrackerList", urls: [
            URL(string: "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_best.txt")!,
            URL(string: "https://cdn.jsdelivr.net/gh/DeSireFire/animeTrackerList/AT_best.txt")!,
        ]),
    ]

    /// First source's primary URL (kept for the doc comment / tests).
    static let remoteURL = sources[0].urls[0]
    /// Default minimum time between network refreshes (hours).
    static let defaultSyncHours = 24.0
    /// Cap on the probed list handed to aria2.
    static let maxTrackers = 30

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
    /// `syncHours`. Pure given `now` — tested.
    static func needsRefresh(now: Date = Date(), syncHours: Double = defaultSyncHours) -> Bool {
        guard let updated = cacheUpdatedAt() else { return true }
        return now.timeIntervalSince(updated) >= syncHours * 3600
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

    // MARK: - Fetch + probe

    /// Fetches every source's mirrors in order and merges the parsed lists
    /// (deduped, order-preserving). Returns [] when all mirrors fail.
    /// `proxy` routes the HTTP fetch through the configured proxy (Phase 5);
    /// nil uses the shared session.
    static func fetchAll(proxy: ProxyConfig? = nil) async -> [String] {
        let session: URLSession
        if let proxyDict = proxy?.urlSessionProxyDictionary() {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDict
            session = URLSession(configuration: config)
        } else {
            session = URLSession.shared
        }
        var seen = Set<String>()
        var merged: [String] = []
        for source in sources {
            for url in source.urls {
                guard let (data, _) = try? await session.data(from: url),
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                let trackers = parse(text)
                guard !trackers.isEmpty else { continue }
                for t in trackers where seen.insert(t).inserted {
                    merged.append(t)
                }
                break // this source is satisfied; move to the next source
            }
        }
        return merged
    }

    /// Fetches the latest lists when due, UDP-probes them to drop dead
    /// trackers, caches the healthy list, and hands it to `apply` (the
    /// caller pushes it into the running daemon). Never throws: any failure
    /// silently keeps the previous list.
    static func refreshIfNeeded(
        autoUpdate: Bool,
        syncHours: Double = defaultSyncHours,
        probeDeadTrackers: Bool = true,
        proxy: ProxyConfig? = nil,
        now: Date = Date(),
        apply: ([String]) async -> Void
    ) async {
        guard autoUpdate, needsRefresh(now: now, syncHours: syncHours) else { return }
        let fetched = await fetchAll(proxy: proxy)
        guard !fetched.isEmpty else { return }
        let live = probeDeadTrackers
            ? await TrackerProber.probe(fetched)
            : fetched
        // If probing killed everything (e.g. UDP blocked on this network),
        // fall back to the unprobed list rather than announcing nothing.
        let trackers = Array((live.isEmpty ? fetched : live).prefix(maxTrackers))
        guard !trackers.isEmpty else { return }
        saveCache(trackers, at: now)
        await apply(trackers)
    }
}
