import Foundation
import Observation

/// Segmented, resumable HTTP download engine.
///
/// Each download is split into byte-range segments (`DownloadItem.makeSegments`);
/// every incomplete segment gets its own `URLSessionDataTask` inside a
/// `SegmentTransport`, which streams `Data` chunks straight to the
/// `.grabbit-part` file at absolute offsets. (The delegate API is used instead
/// of `URLSession.bytes(for:)` because the latter yields individual UInt8 —
/// millions of async suspensions per second — which capped throughput at
/// ~100 KB/s.)
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
    private var transports: [UUID: SegmentTransport] = [:]
    private var pendingSegments: [UUID: Int] = [:]
    private var launchGeneration: [UUID: Int] = [:]
    private var speedSamples: [UUID: [(date: Date, bytes: Int64)]] = [:]

    public init(resumeStore: ResumeStore = ResumeStore()) {
        self.resumeStore = resumeStore
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

    // MARK: - Public control

    /// Adds a download: HEAD-probes the server for size + range support, builds
    /// segments, creates the `.grabbit-part` file, persists state, and auto-starts.
    @MainActor
    public func add(
        url: URL,
        filename: String? = nil,
        category: DownloadCategory = .other,
        sourceSite: SourceSite = .direct,
        connections: Int? = nil,
        destination: URL? = nil
    ) async {
        let candidate = filename ?? url.lastPathComponent
        let decoded = candidate.removingPercentEncoding ?? candidate
        let name = decoded.isEmpty ? "download" : decoded

        // Probe the server: total size and Accept-Ranges support.
        var totalBytes: Int64?
        var supportsRanges = false
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse {
            if let length = http.value(forHTTPHeaderField: "Content-Length"),
               let parsed = Int64(length) {
                totalBytes = parsed
            }
            supportsRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?
                .lowercased().contains("bytes") ?? false
        }

        // No range support (or unknown size) -> single connection.
        let connectionCount = supportsRanges ? max(1, connections ?? maxConnections) : 1

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
            destinationURL: destinationURL
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
        // If the partial file vanished (e.g. user deleted it), restart cleanly.
        let partialURL = resumeStore.partialFileURL(for: items[itemIndex])
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            for i in items[itemIndex].segments.indices {
                items[itemIndex].segments[i].receivedBytes = 0
            }
            items[itemIndex].downloadedBytes = 0
        }
        items[itemIndex].state = .downloading
        items[itemIndex].errorMessage = nil
        speedSamples[id] = []
        launchSegmentTasks(for: id)
        persistItem(id: id)
    }

    @MainActor
    public func resume(_ id: UUID) {
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
        persistItem(id: id)
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
        transports[id] = transport
        pendingSegments[id] = pending.count

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
            Task { await self?.handleSegmentError(id: id, error: error, generation: generation) }
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
                partialURL: partialURL
            )
        }
    }

    @MainActor
    private func cancelSegmentTasks(for id: UUID) {
        launchGeneration[id] = (launchGeneration[id] ?? 0) + 1
        transports[id]?.cancelAll()
        transports[id] = nil
        pendingSegments[id] = nil
    }

    @MainActor
    private func isCurrentGeneration(id: UUID, generation: Int) -> Bool {
        launchGeneration[id] == generation
    }

    /// A segment got a non-2xx status. The transport already cancelled it;
    /// fail the whole download (the other segments are torn down by fail()).
    @MainActor
    private func handleHTTPError(id: UUID, status: Int, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        fail(id: id, message: "HTTP \(status)")
    }

    /// Server answered 200 to a ranged request: collapse to a single stream.
    @MainActor
    private func handleRangeIgnored(id: UUID, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        fallbackToSingleStream(id: id)
    }

    @MainActor
    private func handleSegmentComplete(id: UUID, segmentIndex: Int, absoluteReceived: Int64, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        finishSegment(id: id, segmentIndex: segmentIndex, absoluteReceived: absoluteReceived)
        let remaining = (pendingSegments[id] ?? 1) - 1
        pendingSegments[id] = remaining
        if remaining <= 0 {
            segmentsDidFinish(id: id, generation: generation)
        }
    }

    @MainActor
    private func handleSegmentError(id: UUID, error: Error, generation: Int) {
        guard isCurrentGeneration(id: id, generation: generation) else { return }
        if error is TransportError {
            fail(id: id, message: "Download ended before all segments completed.")
        } else {
            fail(id: id, message: error.localizedDescription)
        }
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

    /// Server ignored Range (HTTP 200): discard any mis-offset bytes, collapse
    /// to one stream from byte 0, and relaunch.
    @MainActor
    private func fallbackToSingleStream(id: UUID) {
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
        speedSamples[item.id] = nil
        persistItem(id: item.id)
        // No resume state needed for a finished download.
        try? resumeStore.delete(item.id)
    }

    @MainActor
    private func fail(id: UUID, message: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return }
        cancelSegmentTasks(for: id)
        items[itemIndex].state = .failed
        items[itemIndex].errorMessage = message
        items[itemIndex].speedBytesPerSec = 0
        speedSamples[id] = nil
        persistItem(id: id)
    }

    @MainActor
    private func persistItem(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? resumeStore.save(item)
    }
}
