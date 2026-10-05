import Foundation

/// Supervised child process (Harbor `ManagedChildProcess` idea).
///
/// - One instance per media download; `cancel()` SIGTERMs the process, waits
///   2s, then SIGKILLs it *and any children still alive* (yt-dlp cleans up its
///   own ffmpeg children on SIGTERM; the SIGKILL sweep via `pgrep -P` catches
///   stragglers so pause/cancel/quit never orphans an ffmpeg).
/// - stderr is kept in a bounded 256 KB ring buffer for diagnostics; both
///   streams also offer line-based callbacks (used for yt-dlp progress).
/// - Not thread-safe beyond `cancel()`; drive it from one task.
// @unchecked Sendable: callbacks fire on the serial io queue / process
// threads, and model mutation goes through that serialization.
public final class ManagedProcess: @unchecked Sendable {
    public struct RunResult {
        public var exitCode: Int32
        /// Last up-to-256KB of stderr, decoded lossily.
        public var stderrTail: String
        public var wasCancelled: Bool
    }

    public enum LaunchError: Error, LocalizedError {
        case spawnFailed(String)
        public var errorDescription: String? {
            if case .spawnFailed(let m) = self { return m }
            return nil
        }
    }

    /// 256 KB bounded stderr ring buffer.
    private static let stderrCap = 256 * 1024
    private static let killGrace: TimeInterval = 2

    public var onStdoutLine: ((String) -> Void)?
    public var onStderrLine: ((String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var stderrBuffer = Data()

    public init() {}

    /// Runs the executable to completion. Throws on spawn failure; a
    /// non-zero exit is reported in `RunResult`, not thrown (callers decide —
    /// yt-dlp uses exit codes for "already downloaded" etc.).
    public func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = arguments
            if let environment { proc.environment = environment }
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            lock.withLock {
                self.process = proc
                self.cancelled = false
                self.stderrBuffer.removeAll(keepingCapacity: true)
            }

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            // Pipe events and the termination cleanup run on one serial queue:
            // a fast process (e.g. /bin/echo) can fire the termination handler
            // before an in-flight readability callback has emitted its lines,
            // which silently dropped output. Serializing both guarantees
            // emissions complete before the result continuation resumes.
            let ioQueue = DispatchQueue(label: "com.sankahchan.grabbit.ManagedProcess.io")
            outHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                ioQueue.async { self?.emitLines(data, isStderr: false) }
            }
            errHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                ioQueue.async {
                    self?.appendStderr(data)
                    self?.emitLines(data, isStderr: true)
                }
            }

            proc.terminationHandler = { [weak self] p in
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                // Drain anything left in the pipes, then emit + resume on the
                // same serial queue as the readability callbacks.
                let outRest = (try? outHandle.readToEnd()) ?? Data()
                let errRest = (try? errHandle.readToEnd()) ?? Data()
                ioQueue.async {
                    if !outRest.isEmpty { self?.emitLines(outRest, isStderr: false) }
                    if !errRest.isEmpty {
                        self?.appendStderr(errRest)
                        self?.emitLines(errRest, isStderr: true)
                    }
                    let wasCancelled = self?.lock.withLock { self?.cancelled ?? false } ?? false
                    let tail = self?.lock.withLock {
                        String(decoding: (self?.stderrBuffer ?? Data()), as: UTF8.self)
                    } ?? ""
                    self?.lock.withLock { self?.process = nil }
                    continuation.resume(returning: RunResult(
                        exitCode: p.terminationStatus,
                        stderrTail: tail,
                        wasCancelled: wasCancelled))
                }
            }

            do {
                try proc.run()
            } catch {
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                lock.withLock { self.process = nil }
                continuation.resume(returning: RunResult(
                    exitCode: -1,
                    stderrTail: "Couldn't launch \(executable.lastPathComponent): \(error.localizedDescription)",
                    wasCancelled: false))
            }
        }
    }

    /// SIGTERM now; SIGKILL to the process and its children after a grace
    /// period. Safe to call multiple times and before/after exit.
    public func cancel() {
        let proc: Process? = lock.withLock {
            cancelled = true
            return process
        }
        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            guard proc.isRunning else { return }
            // Stragglers first (ffmpeg children yt-dlp didn't reap)…
            for child in (self?.childPIDs(of: pid) ?? []) {
                kill(child, SIGKILL)
            }
            // …then the process itself.
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Private

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrBuffer.append(data)
            if stderrBuffer.count > Self.stderrCap {
                stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrCap)
            }
        }
    }

    private var stdoutRemainder = ""
    private var stderrRemainder = ""
    /// Splits stream data into lines. Both pipe handlers may fire on
    /// different threads, so remainder bookkeeping is locked. Callbacks run
    /// under the lock — they must not call back into ManagedProcess.
    private func emitLines(_ data: Data, isStderr: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            var lines: [String]
            if isStderr {
                lines = (stderrRemainder + text).components(separatedBy: "\n")
                stderrRemainder = lines.removeLast()
            } else {
                lines = (stdoutRemainder + text).components(separatedBy: "\n")
                stdoutRemainder = lines.removeLast()
            }
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if isStderr { onStderrLine?(trimmed) } else { onStdoutLine?(trimmed) }
            }
        }
    }

    /// Direct children of pid via pgrep (macOS ships it).
    private func childPIDs(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(decoding: out, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
