import Foundation

enum TransportError: Error, LocalizedError {
    case truncatedStream

    var errorDescription: String? {
        switch self {
        case .truncatedStream:
            "The connection closed before the segment finished. Resume to continue."
        }
    }
}

/// Owns one HTTP/1.1 connection per segment and streams response bytes
/// straight into the shared partial file.
///
/// Each segment gets a REAL TCP connection (via ``HTTP1Client``), which is
/// what makes multi-connection downloading fast on high-latency links:
/// URLSession would negotiate HTTP/2 and multiplex everything onto one
/// connection, capping total throughput at a single connection's share.
final class SegmentTransport {
    private struct Job {
        let segmentIndex: Int
        let startByte: Int64
        let endByte: Int64 // .max for the open-ended single-segment case
        let coversWholeFile: Bool
        let client: HTTP1Client
        let handle: FileHandle
        var received: Int64
        var lastReport: Date
    }

    /// (segmentIndex, httpStatus)
    var onHTTPError: ((Int, Int) -> Void)?
    /// Server answered 200 to a ranged request: collapse to one stream.
    var onRangeIgnored: (() -> Void)?
    /// (segmentIndex, absoluteBytesReceived)
    var onProgress: ((Int, Int64) -> Void)?
    /// (segmentIndex, absoluteBytesReceived)
    var onComplete: ((Int, Int64) -> Void)?
    /// (segmentIndex, error)
    var onError: ((Int, Error) -> Void)?
    /// Fired once per transport with the first segment's response headers
    /// (names already lowercased by HTTP1Client). The engine uses it to
    /// validate ETag/Last-Modified on resume.
    var onFirstResponseHeaders: (([String: String]) -> Void)?

    /// Progress callbacks are throttled to this interval per segment so the
    /// UI isn't re-rendered on every TCP packet.
    private static let progressInterval: TimeInterval = 0.25

    /// Phase 5 speed limiter: the shared global bucket (one per engine —
    /// this is what keeps the global cap exact across segments) and the
    /// per-download bucket. Either may pace; a rate of 0 is a no-op.
    var globalBucket: TokenBucket?
    var itemBucket: TokenBucket?

    private var jobs: [Int: Job] = [:]
    private let queue = DispatchQueue(label: "com.sankahchan.grabbit.transport")
    private var didReportFirstHeaders = false

    func startSegment(
        index: Int,
        url: URL,
        start: Int64,
        end: Int64,
        coversWholeFile: Bool,
        partialURL: URL,
        headers: [String: String] = [:]
    ) {
        queue.async { [weak self] in
            self?.startSegmentSync(
                index: index, url: url, start: start, end: end,
                coversWholeFile: coversWholeFile, partialURL: partialURL,
                headers: headers)
        }
    }

    private func startSegmentSync(
        index: Int,
        url: URL,
        start: Int64,
        end: Int64,
        coversWholeFile: Bool,
        partialURL: URL,
        headers: [String: String] = [:]
    ) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partialURL)
            try handle.seek(toOffset: UInt64(start))
        } catch {
            onError?(index, error)
            return
        }

        let client = HTTP1Client(url: url, start: start, end: end, queue: queue, extraHeaders: headers)
        jobs[index] = Job(
            segmentIndex: index, startByte: start, endByte: end,
            coversWholeFile: coversWholeFile, client: client,
            handle: handle, received: 0, lastReport: .distantPast)
        client.onEvent = { [weak self] event in
            self?.handleEvent(index: index, event: event)
        }
        client.start()
    }

    private func handleEvent(index: Int, event: HTTP1Client.Event) {
        switch event {
        case .response(let status, let headers):
            if !didReportFirstHeaders {
                didReportFirstHeaders = true
                onFirstResponseHeaders?(headers)
            }
            guard let job = jobs[index] else { return }
            if status == 200, !job.coversWholeFile {
                // Server ignored Range: discard any partial data (none was
                // written yet — the response event precedes body data) and let
                // the engine collapse to a single stream from byte zero.
                tearDown(index: index)
                onRangeIgnored?()
                return
            }
            guard (200...206).contains(status) else {
                tearDown(index: index)
                onHTTPError?(job.segmentIndex, status)
                return
            }
            // 206, or 200 covering the whole file: body follows.
        case .data(let data):
            guard var job = jobs[index] else { return }
            // Phase 5 speed limiter: pace this chunk through the per-download
            // bucket first, then the shared global bucket. Runs on this
            // transport's serial queue, so the block *is* the pacing — no
            // reordering, and all of this download's segments share it.
            itemBucket?.consume(data.count)
            globalBucket?.consume(data.count)
            do {
                try job.handle.write(contentsOf: data)
            } catch {
                tearDown(index: index)
                onError?(job.segmentIndex, error)
                return
            }
            job.received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(job.lastReport) >= Self.progressInterval {
                job.lastReport = now
                onProgress?(job.segmentIndex, job.startByte + job.received)
            }
            jobs[index] = job
        case .finished:
            guard let job = jobs.removeValue(forKey: index) else { return }
            try? job.handle.synchronize()
            try? job.handle.close()
            if job.endByte != Int64.max {
                let expected = job.endByte - job.startByte + 1
                if job.received < expected {
                    onError?(job.segmentIndex, TransportError.truncatedStream)
                    return
                }
            }
            onComplete?(job.segmentIndex, job.startByte + job.received)
        case .failed(let error):
            guard let job = jobs.removeValue(forKey: index) else { return }
            try? job.handle.close()
            onError?(job.segmentIndex, error)
        }
    }

    private func tearDown(index: Int) {
        if let job = jobs.removeValue(forKey: index) {
            job.client.cancel()
            try? job.handle.close()
        }
    }

    func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for index in Array(self.jobs.keys) {
                self.tearDown(index: index)
            }
        }
    }
}
