import Foundation

/// Errors raised by `SegmentTransport` itself (as opposed to network errors).
enum TransportError: Error {
    case cannotOpenFile
    case seekFailed
    /// A bounded segment's stream ended before its full byte range arrived.
    case truncatedStream
}

/// Delegate-driven HTTP transport for segmented downloads.
///
/// Why not `URLSession.bytes(for:)`? Its AsyncSequence yields individual
/// UInt8 — an async suspension per byte, millions per second — which capped
/// real-world throughput at ~100 KB/s. The delegate API hands us `Data`
/// chunks (tens of KB each) straight from the socket, which is how download
/// managers saturate the link.
///
/// All delegate callbacks run on a private serial queue, so no locks are
/// needed. The engine is notified through closures; every closure hops to
/// `@MainActor` before touching model state. Progress callbacks are
/// time-throttled per segment so the UI isn't re-rendered thousands of
/// times per second.
final class SegmentTransport: NSObject {

    /// One in-flight range request. Lives only on the serial queue.
    private struct Job {
        let segmentIndex: Int
        let startByte: Int64   // absolute file offset of the first byte
        let endByte: Int64     // inclusive; .max = open-ended
        let coversWholeFile: Bool
        let task: URLSessionDataTask
        let handle: FileHandle
        var received: Int64    // bytes written so far
        var lastReport: Date
    }

    /// Interesting response status (non-2xx). The task is already cancelled.
    var onHTTPError: ((Int, Int) -> Void)?          // (segmentIndex, statusCode)
    /// Server answered 200 to a Range request that didn't cover the whole
    /// file — the engine should collapse to a single stream. Task cancelled.
    var onRangeIgnored: (() -> Void)?
    /// Throttled progress. (segmentIndex, absoluteReceived)
    var onProgress: ((Int, Int64) -> Void)?
    /// Segment fully received. (segmentIndex, absoluteReceived)
    var onComplete: ((Int, Int64) -> Void)?
    /// Network/file failure. (segmentIndex, error). Cancellation is silent.
    var onError: ((Int, Error) -> Void)?

    /// Minimum interval between progress callbacks for one segment.
    private static let progressInterval: TimeInterval = 0.25

    private var session: URLSession!
    private var jobs: [Int: Job] = [:]   // taskIdentifier -> Job
    private let queue: OperationQueue

    override init() {
        queue = OperationQueue()
        queue.name = "com.sankahchan.grabbit.transport"
        queue.maxConcurrentOperationCount = 1
        super.init()
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Starts one segment download. Safe to call from any thread.
    func startSegment(
        index: Int,
        url: URL,
        start: Int64,
        end: Int64,
        coversWholeFile: Bool,
        partialURL: URL
    ) {
        queue.addOperation { [weak self] in
            self?.startSegmentSync(
                index: index, url: url, start: start, end: end,
                coversWholeFile: coversWholeFile, partialURL: partialURL
            )
        }
    }

    private func startSegmentSync(
        index: Int,
        url: URL,
        start: Int64,
        end: Int64,
        coversWholeFile: Bool,
        partialURL: URL
    ) {
        var request = URLRequest(url: url)
        if end == Int64.max {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partialURL)
            try handle.seek(toOffset: UInt64(start))
        } catch {
            onError?(index, error)
            return
        }
        let task = session.dataTask(with: request)
        jobs[task.taskIdentifier] = Job(
            segmentIndex: index,
            startByte: start,
            endByte: end,
            coversWholeFile: coversWholeFile,
            task: task,
            handle: handle,
            received: 0,
            lastReport: .distantPast
        )
        task.resume()
    }

    /// Cancels every in-flight segment, closes files, and invalidates the
    /// session (releasing this delegate). Safe to call from any thread.
    func cancelAll() {
        queue.addOperation { [weak self] in
            self?.cancelAllSync()
        }
    }

    private func cancelAllSync() {
        for (_, job) in jobs {
            job.task.cancel()
            try? job.handle.close()
        }
        jobs.removeAll()
        session.finishTasksAndInvalidate()
    }
}

// MARK: - URLSessionDataDelegate (all on the serial queue)

extension SegmentTransport: URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let job = jobs[dataTask.taskIdentifier], status == 200, !job.coversWholeFile {
            // Server ignored our Range header and is sending the whole file.
            jobs.removeValue(forKey: dataTask.taskIdentifier)
            try? job.handle.close()
            onRangeIgnored?()
            completionHandler(.cancel)
            return
        }
        guard (200...206).contains(status) else {
            if let job = jobs.removeValue(forKey: dataTask.taskIdentifier) {
                try? job.handle.close()
                onHTTPError?(job.segmentIndex, status)
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var job = jobs[dataTask.taskIdentifier] else { return }
        do {
            try job.handle.write(contentsOf: data)
        } catch {
            jobs.removeValue(forKey: dataTask.taskIdentifier)
            try? job.handle.close()
            dataTask.cancel()
            onError?(job.segmentIndex, error)
            return
        }
        job.received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(job.lastReport) >= Self.progressInterval {
            job.lastReport = now
            jobs[dataTask.taskIdentifier] = job
            onProgress?(job.segmentIndex, job.startByte + job.received)
        } else {
            jobs[dataTask.taskIdentifier] = job
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
        try? job.handle.synchronize()
        try? job.handle.close()
        if let error {
            // pause()/cancel()/fallback teardown — the engine already moved on.
            if (error as NSError).code == NSURLErrorCancelled { return }
            onError?(job.segmentIndex, error)
            return
        }
        if job.endByte != Int64.max {
            let expected = job.endByte - job.startByte + 1
            if job.received < expected {
                onError?(job.segmentIndex, TransportError.truncatedStream)
                return
            }
        }
        onComplete?(job.segmentIndex, job.startByte + job.received)
    }
}
