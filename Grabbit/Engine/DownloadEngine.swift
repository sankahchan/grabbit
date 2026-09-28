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

    private let resumeStore: ResumeStore
    private let history: HistoryStore
    private let settings: SettingsStore
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

    public init(resumeStore: ResumeStore = ResumeStore(), history: HistoryStore = HistoryStore(), settings: SettingsStore = SettingsStore()) {
        self.resumeStore = resumeStore
        self.history = history
        self.settings = settings
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
    }

    /// HEAD first; on failure (403/405/network) fall back to
    /// `GET Range: bytes=0-0` — a 206 confirms resumability and
    /// `Content-Range` carries the total (QDM probe strategy).
    /// Also captures ETag / Last-Modified validators and a
    /// Content-Disposition filename when the server provides them.
    private static func probe(_ url: URL) async -> ProbeResult {
        var result = ProbeResult()
        if let (status, headers) = await fetchHeaders(url, method: "HEAD"),
           (200...299).contains(status)
        {
            applyProbeHeaders(&result, headers: headers)
            if result.totalBytes != nil { return result }
        }
        if let (status, headers) = await fetchHeaders(
            url, method: "GET", range: "bytes=0-0"),
           status == 206
        {
            applyProbeHeaders(&result, headers: headers)
            if result.totalBytes == nil,
               let range = headers["content-range"],
               let total = DownloadItem.totalFromContentRange(range)
            {
                result.totalBytes = total
            }
        }
        return result
    }

    private static func fetchHeaders(
        _ url: URL, method: String, range: String? = nil
    ) async -> (status: Int, headers: [String: String])? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
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
        if let disposition = headers["content-disposition"],
           let name = DownloadItem.filenameFromContentDisposition(disposition),
           !name.isEmpty
        {
            result.filename = name
        }
    }

    // MARK: - Public control

    /// Adds a download: rewrites share links, probes the server for total
    /// size, builds segments, creates the `.grabbit-part` file, persists
    /// state, and auto-starts.
    @MainActor
    public func add(
        url: URL,
        filename: String? = nil,
        category: DownloadCategory = .other,
        sourceSite: SourceSite = .direct,
        connections: Int? = nil,
        destination: URL? = nil,
        sourcePageURL: URL? = nil,
        headers: [String: String]? = nil,
        speedLimitBytesPerSec: Int64 = 0
    ) async {
        // Share links (Dropbox / Drive / OneDrive) become direct URLs first.
        let url = ShareURLRewriter.rewrite(url)

        // Probe the server for total size. We deliberately do NOT gate
        // multi-connection on the HEAD's Accept-Ranges header: many
        // servers/CDNs omit it on HEAD yet honor Range on GET. Like aria2
        // (Motrix's engine), we segment optimistically and collapse to a
        // single stream if a segment is answered with HTTP 200.
        let probe = await Self.probe(url)
        let totalBytes = probe.totalBytes

        let candidate = filename ?? probe.filename ?? url.lastPathComponent
        let decoded = candidate.removingPercentEncoding ?? candidate
        let name = decoded.isEmpty ? "download" : decoded

        // aria2-style: never split into pieces smaller than minSplitSize —
        // 16 TCP+TLS handshakes for 16 tiny segments would be pure overhead.
        let minSplitSize: Int64 = 1_048_576 // 1 MiB
        var connectionCount = max(1, connections ?? min(Self.initialConnections, maxConnections))
        connectionCount = min(connectionCount, maxConnections)
        if let totalBytes {
            connectionCount = min(connectionCount, max(1, Int(totalBytes / minSplitSize)))
        }

        let destinationURL: URL
        if let destination {
            destinationURL = destination
        } else {
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            destinationURL = folder.appendingPathComponent(name)
        }
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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
            url: url,
            filename: name,
            totalBytes: totalBytes,
            segments: segments,
            state: .queued,
            category: category,
            sourceSite: sourceSite,
            destinationURL: destinationURL,
            sourcePageURL: sourcePageURL,
            eTag: probe.eTag,
            lastModified: probe.lastModified,
            requestHeaders: headers,
            speedLimitBytesPerSec: speedLimitBytesPerSec
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
        let maxActive = max(1, settings.settings.maxActiveTasks)
        let activeCount = items.filter { $0.state == .downloading }.count
        if activeCount >= maxActive {
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

    /// Starts queued tasks while under the max-active-tasks cap. Called
    /// whenever a slot frees up (finish/fail/pause/remove) and when the cap
    /// itself is raised in Settings. Idempotent — `start()` re-checks the cap.
    @MainActor
    public func kickQueue(excluding: UUID? = nil) {
        let maxActive = max(1, settings.settings.maxActiveTasks)
        while items.filter({ $0.state == .downloading }).count < maxActive,
              let next = items.first(where: { $0.state == .queued && $0.id != excluding }) {
            start(next.id)
        }
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
        items[itemIndex].state = .completed
        items[itemIndex].speedBytesPerSec = 0
        items[itemIndex].errorMessage = nil
        if let total = items[itemIndex].totalBytes {
            items[itemIndex].downloadedBytes = total
        }
        history.record(.from(download: items[itemIndex], status: .completed))
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
        }
        speedSamples[id] = nil
        segmentRetries[id] = nil
        updateSleepPrevention()
        persistItem(id: id)
        kickQueue()
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
