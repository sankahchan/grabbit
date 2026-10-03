import Foundation
import Observation

/// Polls RSS subscriptions and hands new items to the download engines:
/// media enclosures go to the direct engine (podcasts), page links go to
/// yt-dlp via the media engine (video channels).
///
/// The first check after a feed is added only marks the current items as
/// seen — no back-catalogue flood. Items stay remembered (capped) so a
/// keyword or toggle change cannot re-download old episodes.
@Observable
@MainActor
public final class RSSMonitor {
    /// How often enabled feeds are polled.
    public static let checkInterval: TimeInterval = 30 * 60

    private weak var store: RSSStore?
    private weak var settings: SettingsStore?
    private weak var downloadEngine: DownloadEngine?
    private weak var mediaEngine: MediaEngine?

    private var timer: Timer?
    private var isChecking = false

    /// yt-dlp is serial (one process at a time) — page-link downloads are
    /// queued here so several feeds can't fight over the engine.
    private var mediaQueue: [(url: URL, title: String)] = []
    private var drainingMedia = false

    public init() {}

    public func start(
        store: RSSStore,
        settings: SettingsStore,
        downloadEngine: DownloadEngine,
        mediaEngine: MediaEngine
    ) {
        self.store = store
        self.settings = settings
        self.downloadEngine = downloadEngine
        self.mediaEngine = mediaEngine

        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkAll() }
        }
        // First pass shortly after launch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            await self?.checkAll()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Checks every enabled feed.
    public func checkAll() async {
        guard !isChecking, let store else { return }
        isChecking = true
        defer { isChecking = false }
        for feed in store.feeds where feed.isEnabled {
            await check(feedID: feed.id)
        }
    }

    /// Checks one feed and enqueues its new matching items.
    public func check(feedID: UUID) async {
        guard let store,
              var feed = store.feeds.first(where: { $0.id == feedID })
        else { return }
        do {
            let data = try await Self.fetch(feed.url)
            let parsed = RSSFeedParser.parse(data: data)
            let isFirstCheck = feed.lastCheckedAt == nil
            if feed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !parsed.title.isEmpty
            {
                feed.title = parsed.title
            }
            let fresh = RSSFeed.newItems(
                from: parsed.items, feed: feed, isFirstCheck: isFirstCheck)
            feed.seenItemIDs = RSSFeed.mergedSeenIDs(
                existing: feed.seenItemIDs, checked: parsed.items)
            feed.lastCheckedAt = Date()
            feed.lastError = nil
            store.update(feed)

            guard feed.autoDownload else { return }
            for item in fresh {
                enqueue(item)
            }
        } catch {
            feed.lastCheckedAt = Date()
            feed.lastError = error.localizedDescription
            store.update(feed)
        }
    }

    // MARK: - Enqueueing

    private func enqueue(_ item: RSSItem) {
        guard let settings, let downloadEngine else { return }
        if let enclosure = item.enclosureURL, let url = URL(string: enclosure) {
            let category = Self.category(for: item.enclosureType, url: url)
            let directory = settings.folderURL(for: category)
            let name = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                await downloadEngine.add(
                    url: url,
                    filename: name.isEmpty ? nil : name,
                    destination: directory,
                    sourcePageURL: URL(string: item.link))
            }
            return
        }
        guard let link = URL(string: item.link) else { return }
        enqueueMedia(url: link, title: item.title)
    }

    private func enqueueMedia(url: URL, title: String) {
        mediaQueue.append((url, title))
        drainMediaQueue()
    }

    private func drainMediaQueue() {
        guard !drainingMedia else { return }
        drainingMedia = true
        Task { @MainActor [weak self] in
            while let self, !self.mediaQueue.isEmpty {
                let next = self.mediaQueue.removeFirst()
                guard let settings = self.settings,
                      let mediaEngine = self.mediaEngine
                else { break }
                let directory = settings.folderURL(for: .video)
                mediaEngine.speedLimitBytesPerSec =
                    settings.settings.speedLimitBytesPerSec
                await mediaEngine.downloadStream(
                    url: next.url,
                    to: directory,
                    headers: [:],
                    preferredName: next.title)
            }
            self?.drainingMedia = false
        }
    }

    // MARK: - Helpers

    private static func category(
        for mimeType: String?, url: URL
    ) -> DownloadCategory {
        if let mimeType = mimeType?.lowercased() {
            if mimeType.hasPrefix("audio") { return .audio }
            if mimeType.hasPrefix("video") { return .video }
        }
        return DownloadCategory.infer(filename: url.lastPathComponent)
    }

    private static func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Grabbit RSS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }
        return data
    }
}
