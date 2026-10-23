import Foundation

/// A long-lived `grabbit-telegram-helper -serve` process.
///
/// The Telegram helper owns the MTProto session. Keeping one helper process
/// alive gives every download the already-open file-DC sub-connections, which
/// removes the multi-second `FILE_MIGRATE` handshake from the user's critical
/// path after the first warm-up. Commands are newline-delimited tabs; request
/// ids keep concurrent previews and downloads separate.
@MainActor
final class TelegramHelperSession {
    struct Reply {
        let ok: Bool
        let payload: String
    }

    private struct Pending {
        let continuation: CheckedContinuation<Reply, Never>
        let onProgress: ((Double) -> Void)?
    }

    private let process = ManagedProcess()
    private var runTask: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var readyWaiter: CheckedContinuation<Bool, Never>?
    private var started = false
    private var stopped = false
    private var ready = false
    private var nextRequestID = 0

    var isReady: Bool { ready }

    /// Starts the worker and waits for its authorization check to finish.
    /// A timeout prevents a wedged helper from leaving the workbench blank.
    func start(executable: URL) async -> Bool {
        guard !started else { return ready }
        started = true
        stopped = false

        process.onStdoutLine = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.handle(line)
            }
        }
        process.onStderrLine = { _ in }

        let process = self.process
        let didBecomeReady = await withCheckedContinuation { continuation in
            // Install the waiter before spawning: a very fast helper can
            // print READY before the continuation would otherwise be ready.
            readyWaiter = continuation
            runTask = Task { [weak self] in
                let result = await process.run(executable: executable, arguments: ["-serve"])
                await MainActor.run { [weak self] in
                    self?.handleExit(result)
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.timeoutStart()
            }
        }
        if !didBecomeReady {
            process.cancel()
            await runTask?.value
            runTask = nil
            started = false
        }
        return didBecomeReady
    }

    /// Stops the worker and waits for its stdin/process teardown. Call this
    /// before running a one-shot command (logout) against the same session.
    func stop() async {
        stopped = true
        process.cancel()
        await runTask?.value
        runTask = nil
        started = false
        ready = false
        finishStart(false)
        failPending("Telegram helper stopped.")
    }

    func request(
        _ command: String,
        arguments: [String] = [],
        onProgress: ((Double) -> Void)? = nil,
        register: ((String) -> Void)? = nil
    ) async -> Reply {
        guard ready else {
            return Reply(ok: false, payload: "Telegram helper is not ready.")
        }

        nextRequestID += 1
        let requestID = "r\(nextRequestID)"
        register?(requestID)
        let line = ([command, requestID] + arguments).joined(separator: "\t")

        return await withCheckedContinuation { continuation in
            pending[requestID] = Pending(
                continuation: continuation,
                onProgress: onProgress)
            if !process.sendLine(line) {
                if let failed = pending.removeValue(forKey: requestID) {
                    failed.continuation.resume(
                        returning: Reply(ok: false, payload: "Could not send a command to the Telegram helper."))
                }
            }
        }
    }

    func cancel(requestID: String) {
        guard ready else { return }
        _ = process.sendLine("CANCEL\t\(requestID)")
    }

    // MARK: - Transport

    private func handle(_ line: String) {
        if line == "READY" {
            ready = true
            finishStart(true)
            return
        }
        if line.hasPrefix("PROGRESS\t") {
            let progress = line.split(separator: "\t").map(String.init)
            guard progress.count >= 4,
                  let pending = pending[progress[1]],
                  let written = Double(progress[2]),
                  let total = Double(progress[3]), total > 0 else { return }
            pending.onProgress?(min(max(written / total, 0), 1))
            return
        }
        guard line.hasPrefix("RESULT\t") else { return }

        let parts = line.split(
            separator: "\t",
            maxSplits: 3,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count >= 3 else { return }

        let requestID = parts[1]
        let status = parts[2]
        let payload = parts.count > 3 ? parts[3] : ""
        guard let pending = pending.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(
            returning: Reply(ok: status == "OK", payload: payload))
    }

    private func handleExit(_ result: ManagedProcess.RunResult) {
        ready = false
        if !stopped {
            let detail = result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            failPending(detail.isEmpty ? "Telegram helper stopped." : detail)
        } else {
            failPending("Telegram helper stopped.")
        }
        finishStart(false)
    }

    private func timeoutStart() {
        guard !ready else { return }
        process.cancel()
        finishStart(false)
    }

    private func finishStart(_ value: Bool) {
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        waiter.resume(returning: value)
    }

    private func failPending(_ message: String) {
        let waiting = pending
        pending.removeAll()
        for (_, item) in waiting {
            item.continuation.resume(
                returning: Reply(ok: false, payload: message))
        }
    }
}
