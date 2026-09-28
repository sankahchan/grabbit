import Foundation
import Observation

/// Segmented, resumable HTTP download engine.
///
/// Each download is split into byte-range segments (`DownloadItem.makeSegments`);
/// every incomplete segment gets its own HTTP/1.1 TCP connection inside a
/// `SegmentTransport` (via `HTTP1Client`), which streams `Data` chunks straight
/// to the `.grabbit-part` file at absolute offsets. Raw HTTP/1.1 is used
/// instead of URLSession because URLSession negotiates HTTP/2 via ALPN and
/// multiplexes every segment onto a single TCP connection, which caps total
/// throughput at one connection's share on high-latency links.
/// All model mutations happen on `@MainActor`; transport callbacks hop back
/// for state updates.
///
/// Resume model: segment offsets are persisted to `ResumeStore` (and autosaved
/// every 5s), so killing the app mid-download loses at most a few seconds of
/// bookkeeping. On the next launch, items found `.downloading` are flipped to
/// `.interrupted` and surfaced via `recoveredCount` for the UI's recovery banner.
@Observable
public final class DownloadEngine {
    public private(set) var items: [DownloadItem] = []
    public private(set) var recoveredCount = 0
    public var maxConnections = 16
    /// In-app completion/failure toast cards. Wired by GrabbitApp.
    public weak var toastCenter: ToastCenter?
    /// Backlog #3/#4: per-host profiles and packagizer rules, applied in
    /// add(). Wired by GrabbitApp; nil in unit tests.
    public weak var hostProfileStore: HostProfileStore?
    public weak var packagizerStore: PackagizerStore?
    /// After-downloads-finish actions (sleep/shutdown/…). Wired by GrabbitApp.
    public weak var completionCenter: CompletionActionCenter?

    private let resumeStore: ResumeStore
    private let history: HistoryStore
    private let settings: SettingsStore
    /// Phase 5 named queues: per-queue concurrency limits. The global
    /// `maxActiveTasks` stays the overall ceiling across all queues.
    public let queues: QueueStore
    private var transports: [UUID: SegmentTransport] = [:]
    private var pendingSegments: [UUID: Int] = [:]
    private var launchGeneration: [UUID: Int] = [:]
    private var speedSamples: [UUID: [(date: Date, bytes: Int64)]] = [:]
    /// Consecutive retry attempts per segment (reset on every launch).
    private var segmentRetries: [UUID: [Int: Int]] = [:]
    /// Retryable segment errors seen in the current generation. Many at once
    /// means the server is throttling our connection count.
    private var generationErrors: [UUID: Int] = [:]
    /// When the current generation launched (for slowness downshift timing).
    private var generationStartTime: [UUID: Date] = [:]
    private var slowStreaks: [UUID: Int] = [:]
    private var lastSlownessCheck: [UUID: Date] = [:]
    /// Below this sustained total speed with >1 connection, the server is
    /// likely throttling parallel connections: halve them (same machinery
    /// as the stall path). Checked every 15s after a 60s warmup.
    private static let slownessThreshold: Double = 32 * 1024
    private static let slownessCheckInterval: TimeInterval = 15
    private static let slownessWarmup: TimeInterval = 60
    private static let slownessStreakNeeded = 2
    /// How many times a single stalled/failed segment is retried (with
    /// backoff) before the whole download fails.
    private static let maxSegmentRetries = 5
    /// New downloads start here and grow toward `maxConnections` as segments
    /// complete (QDM-style dynamic growth). Starting moderate is safer against
    /// throttling servers than opening 16 connections up front.
    private static let initialConnections = 8
    /// A segment is only split for growth when it has at least this much
    /// untouched data left — spawning a TCP+TLS connection for less is
    /// pure overhead.
    private static let growthMinSplitBytes: Int64 = 8 * 1_048_576 // 8 MiB
    /// Process-wide sleep-prevention token while any download is active.
    private var sleepActivity: NSObjectProtocol?
    /// Phase 5 speed limiter: one bucket shared by every transport this
    /// engine creates. Shared (not per-segment) so the global cap holds
    /// exactly no matter how many connections are open.
    private let globalSpeedBucket = TokenBucket()

    public init(resumeStore: ResumeStore = ResumeStore(), history: HistoryStore = HistoryStore(), settings: SettingsStore = SettingsStore(), queues: QueueStore = QueueStore()) {
        self.resumeStore = resumeStore
        self.history = history
        self.settings = settings
        self.queues = queues
        let loaded = resumeStore.loadAll()
        var migrated: [DownloadItem] = []
        migrated.reserveCapacity(loaded.count)
        var recovered = 0
        for var item in loaded {
            if item.state == .downloading {
                // The app died mid-download. We deliberately do NOT auto-start
                // here — the UI shows a recovery banner ("N downloads were
                // interrupted — resume?"). The app layer may honor
                // SettingsStore.autoResumeOnLaunch by calling
                // resumeAllInterrupted() instead.
                item.state = .interrupted
                item.speedBytesPerSec = 0
                recovered += 1
            }
            migrated.append(item)
        }
        self.items = migrated
        self.recoveredCount = recovered
        resumeStore.startAutosave(every: 5) { [weak self] in self?.items ?? [] }
    }

    deinit {
        resumeStore.stopAutosave()
    }

    // MARK: - Server probe

    private struct ProbeResult {
        var totalBytes: Int64?
        var eTag: String?
        var lastModified: String?
        var filename: String?
        var contentType: String?
    }

    /// HEAD first; on failure (403/405/network) fall back to
    /// `GET Range: bytes=0-0` — a 206 confirms resumability and
    /// `Content-Range` carries the total (QDM probe strategy).
    /// Also captures ETag / Last-Modified validators and a
    /// Content-Disposition filename when the server provides them.
    private func probe(_ url: URL) async -> ProbeResult {
        var result = ProbeResult()
        if let (status, headers) = await fetchHeaders(url, method: "HEAD"),
           (200...299).contains(status)
        {
            Self.applyProbeHeaders(&result, headers: headers)
            if result.totalBytes != nil { return result }
        }
        if let (status, headers) = await fetchHeaders(
            url, method: "GET", range: "bytes=0-0"),
           status == 206
        {
            Self.applyProbeHeaders(&result, headers: headers)
            if result.totalBytes == nil,
               let range = headers["content-range"],
               let total = DownloadItem.totalFromContentRange(range)
            {
                result.totalBytes = total
            }
        }
        return result
    }

    // MARK: - LinkGrabber probe (backlog #1)

    /// Public probe result for the LinkGrabber staging area: is the link
    /// alive, how big is it, and what does the server call it.
    public struct LinkProbe: Sendable {
        public var online: Bool
        public var totalBytes: Int64?
        public var filename: String?
        public init(online: Bool, totalBytes: Int64? = nil, filename: String? = nil) {
            self.online = online
            self.totalBytes = totalBytes
            self.filename = filename
        }
    }

    /// HEAD, then GET Range bytes=0-0 on failure — the same discovery the
    /// add path uses, exposed for staging so links can be checked before
    /// they are committed as downloads.
    public func probeLink(_ url: URL) async -> LinkProbe {
        // Resolve share links first (MediaFire pages need a page fetch to
        // find the real file) so staged links show the true size/name.
        let url = await MediaFireResolver.resolve(
            ShareURLRewriter.rewrite(url),
            proxyDictionary: proxyDictionary())
        if let (status, headers) = await fetchHeaders(url, method: "HEAD"),
           (200...299).contains(status)
        {
            var result = ProbeResult()
            Self.applyProbeHeaders(&result, headers: headers)
            return LinkProbe(online: true, totalBytes: result.totalBytes, filename: result.filename)
        }
        if let (status, headers) = await fetchHeaders(
            url, method: "GET", range: "bytes=0-0"),
           status == 206 || (200...299).contains(status)
        {
            var result = ProbeResult()
            Self.applyProbeHeaders(&result, headers: headers)
            if result.totalBytes == nil,
               let range = headers["content-range"],
               let total = DownloadItem.totalFromContentRange(range)
            {
                result.totalBytes = total
            }
            return LinkProbe(online: true, totalBytes: result.totalBytes, filename: result.filename)
        }
        return LinkProbe(online: false)
    }

    /// LinkGrabber dedup: is this URL already a download (or queued)?
    public func hasItem(with url: URL) -> Bool {
        let key = url.absoluteString
        return items.contains { $0.url.absoluteString == key }
    }

    /// Sniffs the first bytes of a finished file for an HTML signature.
    /// Catches share pages that slipped past the probe-time guard (e.g.
    /// via replaceURL, which restarts without probing).
    static func fileLooksLikeHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !["html", "htm", "mhtml", "mht", "xhtml", "shtml"].contains(ext)
        else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), !data.isEmpty else { return false }
        var text = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text.hasPrefix("\u{feff}") { text = String(text.dropFirst()) }
        return ["<!doctype", "<html", "<head"].contains { text.hasPrefix($0) }
    }

    private func proxyDictionary() -> [AnyHashable: Any]? {
        ProxyConfig(settings: settings.settings).urlSessionProxyDictionary()
    }

    /// True when the probe says HTML but the filename isn't a web page —
    /// i.e. the link opened a share/info page instead of the file.
    static func isHTMLPage(contentType: String?, filename: String) -> Bool {
        guard let contentType = contentType?.lowercased(),
              contentType.contains("text/html")
                || contentType.contains("application/xhtml")
        else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        return !["html", "htm", "mhtml", "mht", "xhtml", "shtml"]
            .contains(ext)
    }

    private func fetchHeaders(
        _ url: URL, method: String, range: String? = nil
    ) async -> (status: Int, headers: [String: String])? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Probe timeout: a server that won't answer headers in 15s is
        // effectively dead for discovery — fail fast instead of hanging
        // the add sheet on the 60s default (x2 sequential probes). The
        // real download has its own timeouts and surfaces a proper error.
        request.timeoutInterval = 15
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        // Phase 5 proxy: run the probe through the user's proxy (if any)
        // so size discovery works behind it. This session has no proxy-auth
        // challenge handler, so an authenticated proxy just degrades to
        // unknown-size here — the real download still authenticates via
        // HTTP1Transport.
        let session: URLSession
        if let proxyDict = proxyDictionary() {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDict
            session = URLSession(configuration: config)
        } else {
            session = .shared
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = (key as? String)?.lowercased(),
                  let val = value as? String
            else { continue }
            headers[name] = val
        }
        return (http.statusCode, headers)
    }

    private static func applyProbeHeaders(
        _ result: inout ProbeResult, headers: [String: String]
    ) {
        if let length = headers["content-length"], let parsed = Int64(length) {
            result.totalBytes = parsed
        }
        result.eTag = headers["etag"]
        result.lastModified = headers["last-modified"]
        // Strip "; charset=…" parameters — infer() only needs the MIME type.
        result.contentType = headers["content-type"]?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : String($0) }
        if let disposition = headers["content-disposition"],
           let name = DownloadItem.filenameFromContentDisposition(disposition),
           !name.isEmpty
        {
            result.filename = name
        }
    }

    // MARK: - Filename hygiene

    /// `sanitize_filename` (Harbor/QDM): strip path separators, control
    /// characters and leading dots (hidden files / ".." traversal), trim,
    /// and cap length while preserving the extension.
    public static func sanitizeFilename(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        name = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "download" }
        // Cap at 200 characters — well under filesystems' 255-byte limit
        // even with multi-byte names — preserving the extension.
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            var base = (name as NSString).deletingPathExtension
            let keep = max(1, 200 - (ext.isEmpty ? 0 : ext.count + 1))
            base = String(base.prefix(keep)).trimmingCharacters(in: .whitespaces)
            name = ext.isEmpty ? base : "\(base).\(ext)"
            if name.isEmpty { return "download" }
        }
        return name
    }

    /// `unique_filename` (Harbor/QDM): if `<name>` already exists in
    /// `folder`, fall back to `<name> (2).ext`, `<name> (3).ext`, …
    /// Finished downloads never silently overwrite each other.
    public static func uniqueFilename(_ name: String, in folder: URL) -> String {
        let fm = FileManager.default
        var candidate = name
        var n = 1
        while fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            n += 1
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if n > 9999 { break } // pathological; give up uniquifying
        }
        return candidate
    }

    // MARK: - Public control

    /// Adds a download: rewrites share links, probes the server for total
    /// size, builds segments, creates the `.grabbit-part` file, persists
    /// state, and auto-starts.
    ///
    /// - Parameter category: fixed category, or `nil` to auto-detect from
    ///   the filename / Content-Type.
    /// - Parameter destination: the *folder* the finished file lands in —
    ///   an explicit per-task override of the category folder. The filename
    ///   is sanitized and uniquified inside it. Pass `nil` for the
    ///   category's folder from Settings.
    @MainActor
    public func add(
        url: URL,
        filename: String? = nil,
        category: DownloadCategory? = nil,
        sourceSite: SourceSite = .direct,
        connections: Int? = nil,
        destination: URL? = nil,
        sourcePageURL: URL? = nil,
        headers: [String: String]? = nil,
        speedLimitBytesPerSec: Int64 = 0,
        queueID: UUID? = nil
    ) async {
        // Share links (Dropbox / Drive / OneDrive) become direct URLs first.
        let url = ShareURLRewriter.rewrite(url)
        // MediaFire share pages serve HTML, not the file — resolve to the
        // direct download*.mediafire.com URL via the share page.
        let resolvedURL = await MediaFireResolver.resolve(
            url, proxyDictionary: proxyDictionary())

        // Backlog #4 (packagizer): the first enabled rule whose regex
        // matches the URL renames / re-routes the download.
        let rule = packagizerStore?.rule(for: resolvedURL)
        // Backlog #3 (host profiles): saved credentials, thread count,
        // and user-agent for this host.
        let hostProfile = hostProfileStore?.profile(for: resolvedURL.host)

        // Probe the server for total size. We deliberately do NOT gate
        // multi-connection on the HEAD's Accept-Ranges header: many
        // servers/CDNs omit it on HEAD yet honor Range on GET. Like aria2
        // (Motrix's engine), we segment optimistically and collapse to a
        // single stream if a segment is answered with HTTP 200.
        let probe = await probe(resolvedURL)
        let totalBytes = probe.totalBytes

        // Explicit filename wins; otherwise the packagizer template
        // renders against the server's natural name.
        let naturalName = probe.filename ?? resolvedURL.lastPathComponent
        let candidate: String
        if let filename {
            candidate = filename
        } else if let rule,
                  let rendered = rule.render(
                      filename: naturalName, host: resolvedURL.host)
        {
            candidate = rendered
        } else {
            candidate = naturalName
        }
        let decoded = candidate.removingPercentEncoding ?? candidate
        // sanitize_filename: never let a hostile name escape the folder.
        let name = Self.sanitizeFilename(decoded.isEmpty ? "download" : decoded)
        // Auto-detect the category when the caller didn't pin one — the
        // file then lands in the matching category subfolder. A
        // packagizer rule can pin the category instead.
        let resolvedCategory = category ?? rule?.category
            ?? DownloadCategory.infer(filename: name, contentType: probe.contentType)

        // Host profile credentials / user-agent merge into the per-task
        // headers (explicit per-task headers win).
        var effectiveHeaders = headers ?? [:]
        if let hostProfile {
            if !hostProfile.userAgent.isEmpty,
               effectiveHeaders["User-Agent"] == nil
            {
                effectiveHeaders["User-Agent"] = hostProfile.userAgent
            }
            if let auth = hostProfile.authorizationHeader(),
               effectiveHeaders["Authorization"] == nil
            {
                effectiveHeaders["Authorization"] = auth
            }
        }

        // aria2-style: never split into pieces smaller than minSplitSize —
        // 16 TCP+TLS handshakes for 16 tiny segments would be pure overhead.
        let minSplitSize: Int64 = 1_048_576 // 1 MiB
        // Host profile thread count sits between the explicit per-task
        // value and the global default.
        let profileConnections: Int? = hostProfile?.maxConnections ?? nil
        var connectionCount = max(1, connections ?? profileConnections ?? min(Self.initialConnections, maxConnections))
        connectionCount = min(connectionCount, maxConnections)
        if let totalBytes {
            connectionCount = min(connectionCount, max(1, Int(totalBytes / minSplitSize)))
        }

        // Destination contract: `destination` is the containing *folder*
        // (every caller passes a directory — a category folder or a
        // per-task override). With no override the file lands in the
        // resolved category's subfolder from Settings.
        let folder = destination ?? settings.folderURL(for: resolvedCategory)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        // unique_filename: never silently overwrite an existing file —
        // "report.pdf", "report (2).pdf", …
        let uniqueName = Self.uniqueFilename(name, in: folder)
        let destinationURL = folder.appendingPathComponent(uniqueName)

        let segments: [Segment]
        if let totalBytes {
            segments = DownloadItem.makeSegments(totalBytes: totalBytes, connections: connectionCount)
        } else {
            // Unknown size: a single open-ended segment. `endByte == .max` is the
            // sentinel — the worker issues an open "bytes=<start>-" range and
            // fixes endByte when the stream ends.
            segments = [Segment(index: 0, startByte: 0, endByte: Int64.max)]
        }

        var item = DownloadItem(
            url: resolvedURL,
            filename: uniqueName,
            totalBytes: totalBytes,
            segments: segments,
            state: .queued,
            category: resolvedCategory,
            sourceSite: sourceSite,
            destinationURL: destinationURL,
            sourcePageURL: sourcePageURL,
            eTag: probe.eTag,
            lastModified: probe.lastModified,
            requestHeaders: effectiveHeaders.isEmpty ? nil : effectiveHeaders,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            queueID: queueID,
            // Backlog #7: new tasks go last in the persisted list order.
            sortRank: (items.map(\.sortRank).max() ?? -1) + 1
        )

        let partialURL = resumeStore.partialFileURL(for: item)
        let created = FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        if created, let totalBytes {
            // Pre-size the sparse file so segment workers can seek/write anywhere.
            if let handle = try? FileHandle(forWritingTo: partialURL) {
                try? handle.truncate(atOffset: UInt64(totalBytes))
                try? handle.close()
            }
        }
        guard created else {
            item.state = .failed
            item.errorMessage = "Couldn't create partial download file."
            items.append(item)
            return
        }

        items.append(item)
        persistItem(id: item.id)
        // Share-page guard: the probe answered with a web page, not a file
        // (an unhandled share host). Downloading it would produce a bogus
        // "complete" file, so fail fast with a clear message instead.
        if Self.isHTMLPage(contentType: probe.contentType, filename: name) {
            fail(
                id: item.id,
                message: NSLocalizedString("download.error.htmlPage", comment: ""))
            return
        }
        start(item.id)
    }

    @MainActor
    public func start(_ id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[itemIndex].state {
        case .queued, .paused, .interrupted, .failed:
            break
        case .downloading, .completed:
            return
        }
        // Task Management: cap simultaneous downloads. Over-cap tasks wait
        // in .queued; kickQueue() starts the oldest when a slot frees up.
        // Phase 5 named queues: a task starts only when BOTH its queue has
        // a free slot and the global cap has room.
        let queue = queues.queue(for: items[itemIndex].queueID)
        let queueMax = max(1, queue.maxConcurrent)
        let activeInQueue = items.filter {
            $0.state == .downloading
                && queues.queue(for: $0.queueID).id == queue.id
        }.count
        let maxActive = max(1, settings.settings.maxActiveTasks)
        let activeCount = items.filter { $0.state == .downloading }.count
        if activeInQueue >= queueMax || activeCount >= maxActive {
            items[itemIndex].state = .queued
            items[itemIndex].errorMessage = nil
            persistItem(id: id)
            return
        }
        // If the partial file vanished (e.g. user deleted it), restart cleanly.
        let partialURL = resumeStore.partialFileURL(for: items[itemIndex])
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            for i in items[itemIndex].segments.indices {
                items[itemIndex].segments[i].receivedBytes = 0
            }
            items[itemIndex].downloadedBytes = 0
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
                  let fileSize = (attrs[.size] as? NSNumber)?.int64Value
        {
            // Resume honesty: never trust bookkeeping over the filesystem —
            // clamp received bytes to what is actually on disk. (If the stat
            // itself fails, leave bookkeeping untouched.)
            items[itemIndex].segments = DownloadItem.reconciledSegments(
                items[itemIndex].segments, fileSize: fileSize)
            items[itemIndex].downloadedBytes =
                items[itemIndex].segments.reduce(0) { $0 + $1.receivedBytes }
        }
        items[itemIndex].state = .downloading
        items[itemIndex].errorMessage = nil
        items[itemIndex].linkExpired = false // fresh attempt; re-set on 403/410 if still dead
        speedSamples[id] = []
        launchSegmentTasks(for: id)
        updateSleepPrevention()
        persistItem(id: id)
    }

    @MainActor
    public func resume(_ id: UUID) {
        start(id)
    }

    /// Starts queued tasks while under the caps. Called whenever a slot
    /// frees up (finish/fail/pause/remove) and when a cap itself is raised
    /// in Settings. Idempotent — `start()` re-checks the caps.
    /// Phase 5 named queues: drains each queue oldest-first, cycling through
    /// queues in store order so no queue starves another.
    @MainActor
    public func kickQueue(excluding: UUID? = nil) {
        let plan = QueuePlanner.startable(
            items: items,
            queues: queues.queues,
            defaultQueue: queues.defaultQueue,
            globalMaxActive: max(1, settings.settings.maxActiveTasks))
        for item in plan where item.id != excluding {
            start(item.id)
        }
    }

    /// Phase 5 named queues: after a queue is deleted, its tasks fall back
    /// to the default queue (nil queueID). Called by the queue UI.
    @MainActor
    public func reassignQueue(from deletedID: UUID) {
        for index in items.indices where items[index].queueID == deletedID {
            items[index].queueID = nil
            persistItem(id: items[index].id)
        }
        kickQueue()
    }

    /// Backlog #7: drag-reorder. Moves the dragged task to the target
    /// task's position, renumbers the persisted ranks, and re-kicks the
    /// queue (list order is the queue's start order for equal priority).
    @MainActor
    public func moveItem(draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let from = items.firstIndex(where: { $0.id == draggedID }),
              let to = items.firstIndex(where: { $0.id == targetID })
        else { return }
        let moving = items.remove(at: from)
        // Removing shifts the target left when it was after the source.
        let insertAt = from < to ? to - 1 : to
        items.insert(moving, at: insertAt)
        for (rank, index) in items.indices.enumerated() {
            items[index].sortRank = rank
            persistItem(id: items[index].id)
        }
        kickQueue()
    }

    /// Backlog #7: per-task priority (-5...5). Higher starts sooner when a
    /// queue slot frees up.
    @MainActor
    public func setPriority(id: UUID, priority: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].priority = max(-5, min(5, priority))
        persistItem(id: id)
        kickQueue()
    }

    /// Phase 5 scheduler: pushes the current global cap from Settings
    /// into the shared bucket. Called whenever a download launches and
    /// when the setting changes (0 = unlimited).
    @MainActor
    public func syncSpeedLimit() {
        globalSpeedBucket.rate = Double(max(0, settings.settings.speedLimitBytesPerSec))
    }

    /// Phase 5 scheduler "download" action: starts everything that's
    /// waiting — queued, paused, or interrupted by an app kill.
    @MainActor
    public func startAllEligible() {
        for item in items where item.state == .queued || item.state == .paused || item.state == .interrupted {
            start(item.id)
        }
    }

    /// Phase 5 scheduler "stop" action: pauses every active download.
    @MainActor
    public func pauseAll() {
        for item in items where item.state == .downloading {
            pause(item.id)
        }
    }

    /// Swaps the download URL in place (XDM `SetDownloadInfo` idea) — used
    /// when a signed link expires and the user pastes a fresh one. All
    /// downloaded segments are kept; validators are cleared because a fresh
    /// signed URL for the same file may report a different ETag.
    @MainActor
    public func replaceURL(_ id: UUID, with newURL: URL) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        cancelSegmentTasks(for: id)
        items[itemIndex].url = ShareURLRewriter.rewrite(newURL)
        items[itemIndex].linkExpired = false
        items[itemIndex].errorMessage = nil
        items[itemIndex].eTag = nil
        items[itemIndex].lastModified = nil
        items[itemIndex].state = .queued
        persistItem(id: id)
        start(id)
    }

    @MainActor
    public func pause(_ id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading else { return }
        cancelSegmentTasks(for: id)
        items[itemIndex].state = .paused
        items[itemIndex].speedBytesPerSec = 0
        speedSamples[id] = nil
        updateSleepPrevention()
        persistItem(id: id)
        kickQueue()
    }

    /// Stops the download, deletes the partial file and its resume state, and
    /// resets the record to `.queued` so it can be started fresh.
    @MainActor
    public func cancel(_ id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        cancelSegmentTasks(for: id)
        try? FileManager.default.removeItem(at: resumeStore.partialFileURL(for: items[itemIndex]))
        try? resumeStore.delete(items[itemIndex].id)
        for i in items[itemIndex].segments.indices {
            items[itemIndex].segments[i].receivedBytes = 0
        }
        items[itemIndex].downloadedBytes = 0
        items[itemIndex].speedBytesPerSec = 0
        items[itemIndex].state = .queued
        items[itemIndex].errorMessage = nil
        speedSamples[id] = nil
        updateSleepPrevention()
        // The just-cancelled item stays queued for a manual start — but a
        // freed slot should go to the next already-waiting task.
        kickQueue(excluding: items[itemIndex].id)
    }

    /// Drops the record entirely (stops workers, deletes partial file + state).
    @MainActor
    public func remove(_ id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        cancelSegmentTasks(for: id)
        let item = items.remove(at: itemIndex)
        try? FileManager.default.removeItem(at: resumeStore.partialFileURL(for: item))
        try? resumeStore.delete(item.id)
        speedSamples[id] = nil
        updateSleepPrevention()
        kickQueue()
    }

    @MainActor
    public func resumeAllInterrupted() {
        let ids = items.filter { $0.state == .interrupted }.map(\.id)
        for id in ids {
            start(id)
        }
    }

    /// Dismisses the recovery banner; interrupted items stay `.interrupted`
    /// until the user starts them individually.
    @MainActor
    public func dismissRecovery() {
        recoveredCount = 0
    }

    // MARK: - Segment orchestration (all @MainActor)

    @MainActor
    private func launchSegmentTasks(for id: UUID) {
        cancelSegmentTasks(for: id)
        let generation = (launchGeneration[id] ?? 0) + 1
        launchGeneration[id] = generation

        guard let item = items.first(where: { $0.id == id }) else { return }
        let pending = item.segments.filter { !$0.isComplete }
        guard !pending.isEmpty else {
            // Nothing to fetch (e.g. zero-byte file) — finalize immediately.
            segmentsDidFinish(id: id, generation: generation)
            return
        }

        let transport = SegmentTransport()
        // Phase 5 speed limiter: refresh the global rate (the user may have
        // changed it mid-session) and hand the transport both buckets.
        syncSpeedLimit()
        transport.globalBucket = globalSpeedBucket
        transport.itemBucket = TokenBucket(rate: Double(item.speedLimitBytesPerSec))
        // Phase 5 proxy: read live so a settings change applies to newly
        // launched segments without an app restart.
        transport.proxyConfig = ProxyConfig(settings: settings.settings)
        transports[id] = transport
        pendingSegments[id] = pending.count
        segmentRetries[id] = [:]
        generationErrors[id] = 0
        generationStartTime[id] = Date()
        slowStreaks[id] = 0
        lastSlownessCheck[id] = nil

        // All transport callbacks hop to @MainActor before touching the model.
        transport.onHTTPError = { [weak self] segmentIndex, status in
            Task { await self?.handleHTTPError(id: id, status: status, generation: generation) }
        }
        transport.onRangeIgnored = { [weak self] in
            Task { await self?.handleRangeIgnored(id: id, generation: generation) }
        }
        transport.onProgress = { [weak self] segmentIndex, absoluteReceived in
            Task { await self?.reportProgress(id: id, segmentIndex: segmentIndex, absoluteReceived: absoluteReceived) }
        }
        transport.onComplete = { [weak self] segmentIndex, absoluteReceived in
            Task { await self?.handleSegmentComplete(id: id, segmentIndex: segmentIndex, absoluteReceived: absoluteReceived, generation: generation) }
        }
        transport.onError = { [weak self] segmentIndex, error in
            Task { await self?.handleSegmentError(id: id, segmentIndex: segmentIndex, error: error, generation: generation) }
        }
        transport.onFirstResponseHeaders = { [weak self] headers in
            Task { await self?.validateResumeHeaders(id: id, headers: headers, generation: generation) }
        }

        let partialURL = resumeStore.partialFileURL(for: item)
        let wholeFile = item.segments.count == 1
        for segment in pending {
            let start = segment.startByte + segment.receivedBytes
            let coversWhole = wholeFile
                && segment.startByte == 0
                && segment.receivedBytes == 0
                && (segment.endByte == Int64.max
                    || item.totalBytes.map { segment.endByte == $0 - 1 } ?? false)
            transport.startSegment(
                index: segment.index,
                url: item.url,
                start: start,
                end: segment.endByte,
                coversWholeFile: coversWhole,
                partialURL: partialURL,
                headers: item.requestHeaders ?? [:]
            )
        }
    }

    @MainActor
    private func cancelSegmentTasks(for id: UUID) {
        launchGeneration[id] = (launchGeneration[id] ?? 0) + 1
        transports[id]?.cancelAll()
        transports[id] = nil
        pendingSegments[id] = nil
        segmentRetries[id] = nil
        generationErrors[id] = nil
        generationStartTime[id] = nil
        slowStreaks[id] = nil
        lastSlownessCheck[id] = nil
    }

    @MainActor
    private func isCurrentGeneration(id: UUID, generation: Int) -> Bool {
        launchGeneration[id] == generation
    }

    /// A segment got a non-2xx status. 403/410 on a signed URL means the link
    /// expired (marked distinctly so the UI can offer replace-URL instead of a
    /// dead retry). 429/503 with several segments means the server is
    /// throttling connection count — collapse to a single stream and retry
    /// (at most once: after the collapse only one segment remains, so a
    /// repeat 429/503 fails cleanly). Anything else fails the download; the
    /// transport already cancelled the segment and fail() tears down the rest.
    @MainActor
    private func handleHTTPError(id: UUID, status: Int, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation),
              let itemIndex = items.firstIndex(where: { $0.id == id })
        else { return }
        if (status == 403 || status == 410),
           SignedURLDetector.isSigned(items[itemIndex].url)
        {
            items[itemIndex].linkExpired = true
            let hint: String
            if let page = items[itemIndex].sourcePageURL {
                hint = "This download link has expired. Open \(page.absoluteString) for a fresh link, then use Replace URL to resume without losing progress."
            } else {
                hint = "This download link has expired. Use Replace URL with a fresh link to resume without losing progress."
            }
            fail(id: id, message: hint)
            return
        }
        if (status == 429 || status == 503),
           items[itemIndex].segments.count > 1
        {
            collapseToSingleStream(id: id)
        } else {
            fail(id: id, message: "HTTP \(status)")
        }
    }

    /// Server answered 200 to a ranged request: collapse to a single stream.
    @MainActor
    private func handleRangeIgnored(id: UUID, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        collapseToSingleStream(id: id)
    }

    @MainActor
    private func handleSegmentComplete(id: UUID, segmentIndex: Int, absoluteReceived: Int64, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        finishSegment(id: id, segmentIndex: segmentIndex, absoluteReceived: absoluteReceived)
        let remaining = (pendingSegments[id] ?? 1) - 1
        pendingSegments[id] = remaining
        if remaining <= 0 {
            segmentsDidFinish(id: id, generation: generation)
        } else {
            // The server is keeping up: grow toward maxConnections by splitting
            // the largest untouched segment (QDM try_split_segment). Pairs with
            // shrink-on-throttle for fully adaptive parallelism.
            tryGrowConnections(id: id, generation: generation)
        }
    }

    @MainActor
    private func tryGrowConnections(id: UUID, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation),
              let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading,
              let transport = transports[id],
              let split = DownloadItem.growthSplitPoint(
                segments: items[itemIndex].segments,
                maxConnections: maxConnections,
                minSplitBytes: Self.growthMinSplitBytes),
              let segIndex = items[itemIndex].segments.firstIndex(where: { $0.index == split.index })
        else { return }
        let originalEnd = items[itemIndex].segments[segIndex].endByte
        items[itemIndex].segments[segIndex].endByte = split.mid - 1
        let newIndex = (items[itemIndex].segments.map(\.index).max() ?? -1) + 1
        items[itemIndex].segments.append(
            Segment(index: newIndex, startByte: split.mid, endByte: originalEnd))
        pendingSegments[id, default: 0] += 1
        let item = items[itemIndex]
        transport.startSegment(
            index: newIndex,
            url: item.url,
            start: split.mid,
            end: originalEnd,
            coversWholeFile: false,
            partialURL: resumeStore.partialFileURL(for: item),
            headers: item.requestHeaders ?? [:]
        )
        persistItem(id: id)
    }

    /// XDM resume discipline: on a resume (bytes already on disk), the server's
    /// validators must still match what we captured at probe time — otherwise
    /// the file changed and resuming would corrupt the download. Also catches
    /// a changed Content-Range total.
    @MainActor
    private func validateResumeHeaders(id: UUID, headers: [String: String], generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation),
              let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading,
              items[itemIndex].downloadedBytes > 0
        else { return }
        let item = items[itemIndex]
        let changed = DownloadItem.validatorsChanged(
            storedETag: item.eTag,
            storedLastModified: item.lastModified,
            headers: headers)
        let totalChanged: Bool = {
            guard let total = item.totalBytes,
                  let range = headers["content-range"],
                  let rangeTotal = DownloadItem.totalFromContentRange(range)
            else { return false }
            return rangeTotal != total
        }()
        if changed || totalChanged {
            fail(id: id, message: "The file changed on the server. Remove this download and add it again.")
        }
    }

    @MainActor
    private func handleSegmentError(id: UUID, segmentIndex: Int, error: Error, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        guard isRetryable(error) else {
            fail(id: id, message: error.localizedDescription)
            return
        }
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        // Many segments stalling at once means the server is throttling our
        // connection count: halve the connections and relaunch instead of
        // retrying every segment in isolation (which would throttle harder).
        let errors = (generationErrors[id] ?? 0) + 1
        generationErrors[id] = errors
        let incompleteCount = items[itemIndex].segments.filter { !$0.isComplete }.count
        if incompleteCount > 1 && errors >= max(2, incompleteCount / 2) {
            reduceConnections(id: id)
            return
        }
        let attempts = (segmentRetries[id]?[segmentIndex] ?? 0) + 1
        guard attempts <= Self.maxSegmentRetries else {
            fail(id: id, message: error.localizedDescription)
            return
        }
        segmentRetries[id, default: [:]][segmentIndex] = attempts
        // XDM retry asymmetry: a segment that never got a byte failed in the
        // connect phase — back off exponentially (2s, 4s, 8s, 16s, 30s) so a
        // flaky server gets time to recover. A segment that was actively
        // receiving data just got cut off mid-download — reconnect quickly.
        let received = items[itemIndex].segments.first(where: { $0.index == segmentIndex })?.receivedBytes ?? 0
        let delay: Double = received > 0 ? 1.0 : min(30.0, pow(2.0, Double(attempts)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.retrySegment(id: id, segmentIndex: segmentIndex, generation: generation)
        }
    }

    /// Transient segment failures are retried in place (aria2-style): the
    /// segment reconnects and resumes from its last received byte instead of
    /// failing the whole download.
    @MainActor
    private func retrySegment(id: UUID, segmentIndex: Int, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation),
              let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading,
              let seg = items[itemIndex].segments.first(where: { $0.index == segmentIndex }),
              !seg.isComplete,
              let transport = transports[id]
        else { return }
        let item = items[itemIndex]
        let wholeFile = item.segments.count == 1
        let coversWhole = wholeFile
            && seg.startByte == 0
            && seg.receivedBytes == 0
            && (seg.endByte == Int64.max
                || item.totalBytes.map { seg.endByte == $0 - 1 } ?? false)
        transport.startSegment(
            index: seg.index,
            url: item.url,
            start: seg.startByte + seg.receivedBytes,
            end: seg.endByte,
            coversWholeFile: coversWhole,
            partialURL: resumeStore.partialFileURL(for: item),
            headers: item.requestHeaders ?? [:]
        )
    }

    /// The server is throttling our connection count (many segments stalling
    /// at once): halve the connections, re-split the remaining bytes across
    /// fewer segments, and relaunch. Already-downloaded bytes are kept.
    @MainActor
    private func reduceConnections(id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading else { return }
        // Remaining byte ranges of incomplete segments (sorted, non-overlapping).
        var ranges: [(Int64, Int64)] = []
        for seg in items[itemIndex].segments where !seg.isComplete {
            guard seg.endByte != Int64.max else { return } // open-ended: can't re-split
            let s = seg.startByte + seg.receivedBytes
            if s <= seg.endByte { ranges.append((s, seg.endByte)) }
        }
        ranges.sort { $0.0 < $1.0 }
        let totalRemaining = ranges.reduce(0) { $0 + ($1.1 - $1.0 + 1) }
        guard totalRemaining > 0 else { return }
        var newCount = max(1, ranges.count / 2)
        newCount = min(newCount, Int(totalRemaining))
        guard newCount < ranges.count else { return } // nothing to gain

        cancelSegmentTasks(for: id)
        let completed = items[itemIndex].segments.filter { $0.isComplete }
        // Carve the remaining bytes into newCount roughly-equal contiguous
        // chunks by walking the remaining ranges.
        var carved: [Segment] = []
        carved.reserveCapacity(newCount)
        let base = totalRemaining / Int64(newCount)
        var extra = totalRemaining % Int64(newCount)
        var ri = 0
        var pos = ranges[0].0
        for _ in 0..<newCount {
            var want = base + (extra > 0 ? 1 : 0)
            if extra > 0 { extra -= 1 }
            let segStart = pos
            var segEnd = pos - 1
            while want > 0, ri < ranges.count {
                let take = min(want, ranges[ri].1 - pos + 1)
                segEnd = pos + take - 1
                pos += take
                want -= take
                if pos > ranges[ri].1 {
                    ri += 1
                    if ri < ranges.count { pos = ranges[ri].0 }
                }
            }
            carved.append(Segment(index: 0, startByte: segStart, endByte: segEnd))
        }
        // Merge: completed segments keep their bytes; carved get fresh indices.
        var merged = completed
        let offset = (completed.map(\.index).max() ?? -1) + 1
        for (j, seg) in carved.enumerated() {
            var s = seg
            s.index = offset + j
            merged.append(s)
        }
        items[itemIndex].segments = merged
        items[itemIndex].downloadedBytes = merged.reduce(0) { $0 + $1.receivedBytes }
        speedSamples[id] = nil
        persistItem(id: id)
        launchSegmentTasks(for: id)
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let clientError = error as? HTTP1Client.ClientError {
            return clientError.isRetryable
        }
        // Truncated stream: the server closed early; resuming continues it.
        if error is TransportError {
            return true
        }
        // Anything else (e.g. file write errors) fails fast.
        return false
    }

    @MainActor
    private func reportProgress(id: UUID, segmentIndex: Int, absoluteReceived: Int64) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              let segIndex = items[itemIndex].segments.firstIndex(where: { $0.index == segmentIndex })
        else { return }
        // Drop callbacks from a superseded transport (pause/cancel/fallback
        // landed while a data chunk was still in flight).
        guard items[itemIndex].state == .downloading else { return }
        items[itemIndex].segments[segIndex].receivedBytes =
            max(0, absoluteReceived - items[itemIndex].segments[segIndex].startByte)
        items[itemIndex].downloadedBytes = items[itemIndex].segments.reduce(0) { $0 + $1.receivedBytes }

        // Speed = bytes moved inside a rolling 5-second window.
        let now = Date()
        var samples = speedSamples[id, default: []]
        samples.append((now, items[itemIndex].downloadedBytes))
        samples.removeAll { now.timeIntervalSince($0.date) > 5 }
        speedSamples[id] = samples
        if let first = samples.first, let last = samples.last, last.date > first.date {
            let dt = last.date.timeIntervalSince(first.date)
            if dt > 0 {
                items[itemIndex].speedBytesPerSec = Double(last.bytes - first.bytes) / dt
            }
        }
        checkSlowness(id: id)
    }

    /// Some servers don't stall parallel connections outright — they trickle
    /// them (a tarpit). If sustained total speed is abysmal with >1 connection,
    /// halve the connections: fewer connections often get *more* total speed.
    @MainActor
    private func checkSlowness(id: UUID) {
        let now = Date()
        guard now.timeIntervalSince(lastSlownessCheck[id] ?? .distantPast) >= Self.slownessCheckInterval else { return }
        lastSlownessCheck[id] = now
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading,
              let genStart = generationStartTime[id],
              now.timeIntervalSince(genStart) >= Self.slownessWarmup,
              items[itemIndex].segments.filter({ !$0.isComplete }).count > 1
        else { return }
        if items[itemIndex].speedBytesPerSec < Self.slownessThreshold {
            let streak = (slowStreaks[id] ?? 0) + 1
            slowStreaks[id] = streak
            if streak >= Self.slownessStreakNeeded {
                slowStreaks[id] = 0
                reduceConnections(id: id)
            }
        } else {
            slowStreaks[id] = 0
        }
    }

    @MainActor
    private func finishSegment(id: UUID, segmentIndex: Int, absoluteReceived: Int64) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              let segIndex = items[itemIndex].segments.firstIndex(where: { $0.index == segmentIndex })
        else { return }
        if items[itemIndex].segments[segIndex].endByte == Int64.max {
            // Open-ended segment: the stream ending defines its true length.
            items[itemIndex].segments[segIndex].endByte =
                max(items[itemIndex].segments[segIndex].startByte, absoluteReceived - 1)
        }
        items[itemIndex].segments[segIndex].receivedBytes =
            max(0, absoluteReceived - items[itemIndex].segments[segIndex].startByte)
        items[itemIndex].downloadedBytes = items[itemIndex].segments.reduce(0) { $0 + $1.receivedBytes }
        persistItem(id: id)
    }

    /// Server ignored Range (HTTP 200) or throttled connections (429/503):
    /// discard any mis-offset bytes, collapse to one stream from byte 0, and
    /// relaunch.
    @MainActor
    private func collapseToSingleStream(id: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              items[itemIndex].state == .downloading,
              items[itemIndex].segments.count > 1 else { return }
        cancelSegmentTasks(for: id)
        let partialURL = resumeStore.partialFileURL(for: items[itemIndex])
        try? FileManager.default.removeItem(at: partialURL)
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        if let total = items[itemIndex].totalBytes {
            items[itemIndex].segments = DownloadItem.makeSegments(totalBytes: total, connections: 1)
        } else {
            items[itemIndex].segments = [Segment(index: 0, startByte: 0, endByte: Int64.max)]
        }
        items[itemIndex].downloadedBytes = 0
        speedSamples[id] = nil
        persistItem(id: id)
        launchSegmentTasks(for: id)
    }

    @MainActor
    private func segmentsDidFinish(id: UUID, generation: Int) {
        guard launchGeneration[id] == generation else { return } // superseded relaunch
        transports[id] = nil
        pendingSegments[id] = nil
        segmentRetries[id] = nil
        generationErrors[id] = nil
        generationStartTime[id] = nil
        slowStreaks[id] = nil
        lastSlownessCheck[id] = nil
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[itemIndex].state == .downloading else { return } // paused/cancelled/failed already
        if items[itemIndex].segments.allSatisfy(\.isComplete) {
            finalize(itemIndex: itemIndex)
        } else {
            // Workers ended without completing every segment (e.g. truncated
            // stream) and without recording an explicit error.
            fail(id: id, message: "Download ended before all segments completed.")
        }
    }

    @MainActor
    private func finalize(itemIndex: Int) {
        let item = items[itemIndex]
        let partialURL = resumeStore.partialFileURL(for: item)
        do {
            if FileManager.default.fileExists(atPath: item.destinationURL.path) {
                try FileManager.default.removeItem(at: item.destinationURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: item.destinationURL)
        } catch {
            fail(id: item.id, message: "Couldn't move finished file into place: \(error.localizedDescription)")
            return
        }
        // Content backstop: the finished bytes are a web page, not the
        // file (e.g. a share page that slipped past the probe guard via
        // replaceURL or resume). Remove the bogus file and fail instead
        // of reporting "complete".
        if Self.fileLooksLikeHTML(items[itemIndex].destinationURL) {
            try? FileManager.default.removeItem(
                at: items[itemIndex].destinationURL)
            fail(
                id: item.id,
                message: NSLocalizedString("download.error.htmlPage", comment: ""))
            return
        }
        items[itemIndex].state = .completed
        items[itemIndex].speedBytesPerSec = 0
        items[itemIndex].errorMessage = nil
        if let total = items[itemIndex].totalBytes {
            items[itemIndex].downloadedBytes = total
        }
        history.record(.from(download: items[itemIndex], status: .completed))
        if settings.settings.notificationsEnabled {
            Notifier.downloadComplete(
                filename: items[itemIndex].filename,
                folder: items[itemIndex].destinationURL.deletingLastPathComponent().lastPathComponent
            )
        }
        if settings.settings.showCompletionToast {
            toastCenter?.push(AppToast(
                kind: .completed,
                source: .download,
                title: NSLocalizedString("toast.completed.title", comment: ""),
                message: items[itemIndex].filename,
                fileURL: items[itemIndex].destinationURL
            ))
        }
        if settings.settings.completionSoundEnabled {
            ToastCenter.playSound(for: .completed)
        }
        // Backlog #2: auto-extract archives with system tools. Runs
        // off-main (Process.waitUntilExit blocks); a failure leaves the
        // archive in place and shows an informational toast.
        if settings.settings.autoExtractArchives,
           ArchiveExtractor.isExtractableArchive(filename: items[itemIndex].filename)
        {
            let archiveURL = items[itemIndex].destinationURL
            let deleteAfter = settings.settings.deleteArchiveAfterExtract
            let center = toastCenter
            Task.detached(priority: .utility) {
                do {
                    try ArchiveExtractor.extract(archiveURL: archiveURL)
                    if deleteAfter {
                        try? FileManager.default.trashItem(
                            at: archiveURL, resultingItemURL: nil)
                    }
                } catch {
                    center?.push(AppToast(
                        kind: .failed,
                        source: .download,
                        title: NSLocalizedString(
                            "toast.extractFailed.title", comment: ""),
                        message: archiveURL.lastPathComponent
                            + " — " + error.localizedDescription
                    ))
                }
            }
        }
        speedSamples[item.id] = nil
        updateSleepPrevention()
        // No resume state needed for a finished download.
        try? resumeStore.delete(item.id)
        if settings.settings.autoClearFinished {
            // The History tab keeps the permanent record — drop the row.
            remove(item.id)
        } else {
            persistItem(id: item.id)
        }
        kickQueue()
        // Backlog #9: may trigger the after-downloads-finish action.
        completionCenter?.taskDidSettle()
    }

    @MainActor
    private func fail(id: UUID, message: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        cancelSegmentTasks(for: id)
        // Record only on transition — fail() can fire repeatedly for the
        // same stalled item (per-segment retries), and each must not append
        // another history entry.
        let wasAlreadyFailed = items[itemIndex].state == .failed
        items[itemIndex].state = .failed
        items[itemIndex].errorMessage = message
        items[itemIndex].speedBytesPerSec = 0
        if !wasAlreadyFailed {
            history.record(.from(download: items[itemIndex], status: .failed))
            if settings.settings.notificationsEnabled {
                Notifier.downloadFailed(
                    filename: items[itemIndex].filename,
                    message: message
                )
            }
            if settings.settings.showFailureToast {
                toastCenter?.push(AppToast(
                    kind: .failed,
                    source: .download,
                    title: NSLocalizedString("toast.failed.title", comment: ""),
                    message: items[itemIndex].filename + " — " + message,
                    taskID: id
                ))
            }
            if settings.settings.completionSoundEnabled {
                ToastCenter.playSound(for: .failed)
            }
        }
        speedSamples[id] = nil
        segmentRetries[id] = nil
        updateSleepPrevention()
        persistItem(id: id)
        kickQueue()
        // Backlog #9: only on the terminal transition (fail can fire
        // repeatedly for the same stalled item).
        if !wasAlreadyFailed {
            completionCenter?.taskDidSettle()
        }
    }

    @MainActor
    private func persistItem(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? resumeStore.save(item)
    }

    /// Keeps the Mac awake while any download is active (Harbor
    /// `DownloadSleepPreventionService` idea). Balanced when the last
    /// download stops.
    @MainActor
    private func updateSleepPrevention() {
        let active = items.contains { $0.state == .downloading }
        if active, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Downloading files"
            )
        } else if !active, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
