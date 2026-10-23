import AppKit
import Foundation
import Observation

/// Drives the bundled `grabbit-telegram-helper` process.
///
/// The helper owns Telegram session storage and MTProto networking; Grabbit
/// only exchanges line-oriented commands/results with it. Keeping the
/// account session out of the app process means a crash in the browser cannot
/// corrupt the session, and the helper can be replaced independently.
@MainActor
@Observable
final class TelegramService {
    enum AuthState: Equatable {
        case unknown
        case loggedOut
        case loggingIn
        case needs2FA
        case ready
        case failed(String)
    }

    private(set) var authState: AuthState = .unknown
    private(set) var qrURL: String?
    private(set) var selfName: String?
    private(set) var chats: [TelegramChat] = []
    private(set) var messagesByChat: [Int64: [TelegramMessage]] = [:]
    private(set) var loadingChats = false
    private(set) var loadingMessages = false
    private(set) var errorMessage: String?
    /// Telegram message ids are unique per dialog, not globally, so every
    /// transfer and cached file is keyed by (chat, message).
    private struct MediaKey: Hashable, Sendable {
        let chatID: Int64
        let messageID: Int
    }

    private var downloadProgressByMedia: [MediaKey: Double] = [:]
    /// The on-disk copy of each completed download, so the UI can reveal it.
    private var downloadedFilesByMedia: [MediaKey: URL] = [:]
    /// Destinations claimed by in-flight downloads. Two different messages can
    /// have the same filename; without this, concurrent clicks could make the
    /// helper write both transfers into one file.
    private var reservedDestinations: Set<String> = []
    /// 0...1, while a preview is being fetched into the cache.
    private var previewProgressByMedia: [MediaKey: Double] = [:]

    var activeDownloadCount: Int { downloadProgressByMedia.count }

    func downloadProgress(for message: TelegramMessage, in chat: TelegramChat) -> Double? {
        downloadProgressByMedia[mediaKey(message, chat)]
    }

    func previewProgress(for message: TelegramMessage, in chat: TelegramChat) -> Double? {
        previewProgressByMedia[mediaKey(message, chat)]
    }

    func downloadedURL(for message: TelegramMessage, in chat: TelegramChat) -> URL? {
        guard let url = downloadedFilesByMedia[mediaKey(message, chat)],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }
        return url
    }

    private func mediaKey(_ message: TelegramMessage, _ chat: TelegramChat) -> MediaKey {
        MediaKey(chatID: chat.id, messageID: message.id)
    }

    var historyStore: HistoryStore?
    var toastCenter: ToastCenter?

    private var loginProcess: ManagedProcess?
    private var loginTask: Task<Void, Never>?
    /// Invalidates late stdout/completion events from a cancelled login so
    /// they cannot clobber a newer QR attempt.
    private var loginGeneration = 0
    private var loginNeedsPassword = false
    private var bootstrapped = false
    private var helperSession: TelegramHelperSession?
    private var helperStartTask: Task<Bool, Never>?
    private var previewRequestID: String?
    private var previewToken = UUID()

    // MARK: - Paths

    private var helperURL: URL? {
        if let bundled = Bundle.main.url(
            forResource: "grabbit-telegram-helper",
            withExtension: nil,
            subdirectory: "bin"
        ) {
            return bundled
        }
        #if DEBUG
        // Explicit development override; never used in release builds.
        if let path = ProcessInfo.processInfo.environment["GRABBIT_TELEGRAM_HELPER"] {
            let dev = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: dev.path) {
                return dev
            }
        }
        #endif
        return nil
    }

    private var downloadsRoot: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Grabbit/Telegram", isDirectory: true)
    }

    /// Previews live in the caches directory, not Downloads: watching a clip
    /// should never leave a surprise file in the user's download folder.
    private var previewsRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches")
        return caches
            .appendingPathComponent("Grabbit/TelegramPreviews", isDirectory: true)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        cleanStalePreviewStagingFiles()
        guard let helperURL else {
            authState = .failed("Telegram helper is missing from the app bundle.")
            return
        }

        let result = await runHelper(helperURL, arguments: ["-status"])
        guard result.exitCode == 0 else {
            authState = .failed(result.stderrTail.isEmpty
                ? "Telegram helper could not start."
                : result.stderrTail)
            return
        }
        if Self.isAuthorizedStatus(result.stdout) {
            authState = .ready
            guard await startHelperIfNeeded() else { return }
            await loadChats()
        } else {
            authState = .loggedOut
        }
    }

    func login(password: String = "") {
        guard let helperURL else {
            authState = .failed("Telegram helper is missing from the app bundle.")
            return
        }

        // The helper is still running after printing NEED_2FA and is waiting
        // on its stdin. Sending the password to that same process preserves
        // the QR-approved auth key; restarting the helper would show a fresh
        // QR code and lose the user's scan.
        if authState == .needs2FA, let process = loginProcess {
            guard !password.isEmpty else { return }
            authState = .loggingIn
            qrURL = nil
            errorMessage = nil
            loginNeedsPassword = true
            if !process.sendLine(password) {
                authState = .needs2FA
                errorMessage = "Could not send the two-step password to the Telegram helper."
            }
            return
        }

        guard loginTask == nil else { return }

        authState = .loggingIn
        qrURL = nil
        errorMessage = nil
        loginNeedsPassword = false
        let arguments = ["-login"]
        loginGeneration += 1
        let generation = loginGeneration

        let process = ManagedProcess()
        loginProcess = process
        process.onStdoutLine = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.handleLoginLine(line, generation: generation)
            }
        }
        process.onStderrLine = { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { @MainActor [weak self] in
                // NEED_2FA is a normal login step, not an error. Its stderr
                // is an implementation detail that should not replace the
                // password prompt with an error card.
                guard let self,
                      self.loginGeneration == generation,
                      self.authState != .needs2FA else { return }
                self.errorMessage = trimmed
            }
        }
        loginTask = Task { [weak self] in
            let result = await process.run(
                executable: helperURL,
                arguments: arguments)
            await MainActor.run { [weak self] in
                guard let self, self.loginGeneration == generation else { return }
                self.loginProcess = nil
                self.loginTask = nil
                if result.exitCode == 0 {
                    self.authState = .ready
                    self.qrURL = nil
                    self.loginNeedsPassword = false
                    Task {
                        guard await self.startHelperIfNeeded() else { return }
                        await self.loadChats()
                    }
                } else if self.authState == .needs2FA || self.loginNeedsPassword {
                    let wasPasswordAttempt = self.loginNeedsPassword
                    self.authState = .needs2FA
                    self.qrURL = nil
                    self.loginNeedsPassword = false
                    if wasPasswordAttempt {
                        self.errorMessage = "Two-step verification failed. Check the password and try again."
                    } else {
                        // First QR approval: the password field is the next
                        // step, not a failure. Suppress the helper's raw
                        // NEED_2FA stderr diagnostic.
                        self.errorMessage = nil
                    }
                } else if self.authState != .loggedOut {
                    self.authState = .loggedOut
                    if self.errorMessage == nil {
                        self.errorMessage = result.stderrTail.isEmpty
                            ? "Telegram login was cancelled or failed."
                            : result.stderrTail
                    }
                }
            }
        }
    }

    func cancelLogin() {
        loginGeneration += 1
        loginProcess?.cancel()
        loginProcess = nil
        loginTask?.cancel()
        loginTask = nil
        qrURL = nil
        loginNeedsPassword = false
        authState = .loggedOut
    }

    private func handleLoginLine(_ line: String, generation: Int) {
        guard generation == loginGeneration else { return }
        if line.hasPrefix("QR_URL=") {
            qrURL = String(line.dropFirst("QR_URL=".count))
            return
        }
        if line == "AUTH_OK" {
            authState = .ready
            return
        }
        if line.hasPrefix("SELF\t") {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            if parts.count >= 3 {
                selfName = parts[2]
            }
            return
        }
        if line == "NEED_2FA=1" {
            let wasPasswordAttempt = loginNeedsPassword
            authState = .needs2FA
            qrURL = nil
            loginNeedsPassword = false
            errorMessage = wasPasswordAttempt
                ? "Two-step verification failed. Check the password and try again."
                : nil
        }
    }

    // MARK: - Helper worker

    private func startHelperIfNeeded() async -> Bool {
        if let session = helperSession {
            if session.isReady { return true }
            await session.stop()
            helperSession = nil
        }
        if let task = helperStartTask {
            return await task.value
        }
        guard let executable = helperURL else {
            authState = .failed("Telegram helper is missing from the app bundle.")
            return false
        }

        let task = Task { [weak self] in
            guard let self else { return false }
            let session = TelegramHelperSession()
            let ok = await session.start(executable: executable)
            guard ok, !Task.isCancelled else {
                await session.stop()
                self.helperSession = nil
                if !Task.isCancelled {
                    self.authState = .failed("Could not start the Telegram helper.")
                }
                return false
            }
            self.helperSession = session
            return true
        }
        helperStartTask = task
        let result = await task.value
        helperStartTask = nil
        return result
    }

    /// Warm the file-DC sub-connections in the background after a chat loads.
    /// A warm-up is a 4 KiB read per DC; it never writes a preview or download.
    private func warmMedia(for chat: TelegramChat) async {
        guard let helperSession, helperSession.isReady else { return }
        _ = await helperSession.request("WARM_PEER", arguments: [chat.peerArgument, "100"])
    }

    // MARK: - Browser data

    func loadChats() async {
        guard authState == .ready, !loadingChats else { return }
        loadingChats = true
        defer { loadingChats = false }

        guard await startHelperIfNeeded(), let helperSession else { return }
        let reply = await helperSession.request("CHATS")
        guard reply.ok else {
            errorMessage = reply.payload.isEmpty ? "Could not load Telegram chats." : reply.payload
            return
        }
        do {
            let decoded = try JSONDecoder.telegram.decode([TelegramChat].self, from: Data(reply.payload.utf8))
            chats = [.savedMessages] + decoded
            errorMessage = nil
        } catch {
            errorMessage = "Could not parse the Telegram chat list: \(error.localizedDescription)"
        }
    }

    func loadMessages(for chat: TelegramChat) async {
        guard authState == .ready, !loadingMessages else { return }
        loadingMessages = true
        defer { loadingMessages = false }

        guard await startHelperIfNeeded(), let helperSession else { return }
        let reply = await helperSession.request(
            "MESSAGES",
            arguments: [chat.peerArgument, "100"])
        guard reply.ok else {
            errorMessage = reply.payload.isEmpty
                ? "Could not load messages for \(chat.title)."
                : reply.payload
            return
        }
        do {
            let decoded = try JSONDecoder.telegram.decode([TelegramMessage].self, from: Data(reply.payload.utf8))
            messagesByChat[chat.id] = decoded
            errorMessage = nil
            if decoded.contains(where: { $0.canDownload }) {
                Task { [weak self] in
                    await self?.warmMedia(for: chat)
                }
            }
        } catch {
            errorMessage = "Could not parse messages for \(chat.title): \(error.localizedDescription)"
        }
    }

    func messages(for chat: TelegramChat) -> [TelegramMessage] {
        messagesByChat[chat.id] ?? []
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Downloads

    func download(_ message: TelegramMessage, from chat: TelegramChat) async {
        guard authState == .ready else { return }
        let key = mediaKey(message, chat)
        guard message.canDownload, downloadProgressByMedia[key] == nil else { return }
        guard downloadedURL(for: message, in: chat) == nil else { return }

        let folder = downloadsRoot.appendingPathComponent(Self.safeName(chat.title), isDirectory: true)
        let filename = Self.safeName(message.displayName)
        let destination = Self.uniqueDestination(
            in: folder,
            filename: filename,
            reserved: reservedDestinations)
        reservedDestinations.insert(destination.path)
        defer { reservedDestinations.remove(destination.path) }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create the Telegram download folder: \(error.localizedDescription)"
            return
        }

        errorMessage = nil
        downloadProgressByMedia[key] = 0

        // A preview has already fetched the full media file. Copying that
        // entry avoids a second MTProto transfer and the file-DC handshake,
        // which is where most of the pre-download delay comes from.
        if let cached = cachedPreviewURL(for: message, in: chat) {
            do {
                try FileManager.default.copyItem(at: cached, to: destination)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destination.path)
                downloadProgressByMedia[key] = nil
                if recordCompletedDownload(
                    at: destination,
                    filename: filename,
                    message: message,
                    chat: chat) {
                    return
                }
                try? FileManager.default.removeItem(at: destination)
            } catch {
                // The cache can disappear between the check and the copy.
                // Fall through to the normal network download.
                try? FileManager.default.removeItem(at: destination)
            }
        }

        guard await startHelperIfNeeded(), let helperSession else {
            downloadProgressByMedia[key] = nil
            errorMessage = "Could not start the Telegram helper."
            return
        }

        downloadProgressByMedia[key] = 0
        let reply = await helperSession.request(
            "DOWNLOAD",
            arguments: [
                chat.peerArgument,
                String(message.id),
                destination.path,
                "4",
            ],
            onProgress: { [weak self] (fraction: Double) in
                self?.downloadProgressByMedia[key] = fraction
            })

        downloadProgressByMedia[key] = nil
        if reply.ok {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        if reply.ok,
           recordCompletedDownload(
               at: destination,
               filename: filename,
               message: message,
               chat: chat) {
            return
        }

        try? FileManager.default.removeItem(at: destination)
        let reason: String
        if reply.ok {
            reason = "Telegram downloaded an empty file."
        } else {
            reason = reply.payload.isEmpty ? "Telegram download failed." : reply.payload
        }
        errorMessage = reason
        historyStore?.record(HistoryEntry(
            name: filename,
            kind: .download,
            status: .failed,
            totalBytes: message.sizeValue > 0 ? message.sizeValue : nil,
            sourceURL: sourceURL(for: message, in: chat),
            savePath: nil,
            errorMessage: reason))
        toastCenter?.push(AppToast(
            kind: .failed,
            source: .download,
            title: "Telegram download failed",
            message: filename))
    }

    @discardableResult
    private func recordCompletedDownload(
        at destination: URL,
        filename: String,
        message: TelegramMessage,
        chat: TelegramChat
    ) -> Bool {
        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 0 else { return false }
        downloadedFilesByMedia[mediaKey(message, chat)] = destination
        historyStore?.record(HistoryEntry(
            name: filename,
            kind: .download,
            status: .completed,
            totalBytes: Int64(fileSize),
            sourceURL: sourceURL(for: message, in: chat),
            savePath: destination.path))
        toastCenter?.push(AppToast(
            kind: .completed,
            source: .download,
            title: "Telegram download",
            message: filename,
            fileURL: destination))
        return true
    }

    private func sourceURL(for message: TelegramMessage, in chat: TelegramChat) -> String {
        chat.username.map { "https://t.me/\($0)/\(message.id)" }
            ?? "telegram://\(chat.id)/\(message.id)"
    }

    func downloadAll(_ messages: [TelegramMessage], from chat: TelegramChat) async {
        for message in messages where message.canDownload {
            await download(message, from: chat)
        }
    }

    // MARK: - Previews

    /// Returns the cached file for a message if it is already on disk.
    func cachedPreviewURL(for message: TelegramMessage, in chat: TelegramChat) -> URL? {
        let candidate = previewDestination(for: message, in: chat)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }
        return candidate
    }

    /// Fetches a media file into the preview cache and returns its local URL.
    /// Nothing lands in Downloads; the existing download flow stays separate.
    func preparePreview(_ message: TelegramMessage, from chat: TelegramChat) async -> URL? {
        guard authState == .ready else { return nil }
        guard message.canDownload, message.isPreviewable else { return nil }
        let key = mediaKey(message, chat)
        if let cached = cachedPreviewURL(for: message, in: chat) { return cached }

        let folder = previewsRoot
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            errorMessage = "Could not create the Telegram preview cache: \(error.localizedDescription)"
            return nil
        }

        let destination = previewDestination(for: message, in: chat)

        // One preview at a time — moving to the next file cancels the fetch
        // that is no longer visible instead of downloading both.
        if let previous = previewRequestID {
            helperSession?.cancel(requestID: previous)
        }
        previewRequestID = nil
        let token = UUID()
        previewToken = token
        // Download into a unique staging file, then atomically move it into
        // the cache. A cancelled or crashed fetch therefore never leaves a
        // partial file that could be mistaken for a valid cache entry.
        let staging = folder.appendingPathComponent(
            ".preview-\(chat.id)-\(message.id)-\(token.uuidString).partial")
        try? FileManager.default.removeItem(at: staging)
        previewProgressByMedia[key] = 0
        errorMessage = nil

        guard await startHelperIfNeeded(), let helperSession else {
            previewProgressByMedia[key] = nil
            try? FileManager.default.removeItem(at: staging)
            errorMessage = "Could not start the Telegram helper."
            return nil
        }

        let reply = await helperSession.request(
            "DOWNLOAD",
            arguments: [
                chat.peerArgument,
                String(message.id),
                staging.path,
                "4",
            ],
            onProgress: { [weak self] (fraction: Double) in
                guard let self, self.previewToken == token else { return }
                self.previewProgressByMedia[key] = fraction
            },
            register: { [weak self] (requestID: String) in
                guard let self else { return }
                if self.previewToken == token {
                    self.previewRequestID = requestID
                } else {
                    self.helperSession?.cancel(requestID: requestID)
                }
            })

        // A superseded fetch must not touch the newer preview's state, but it
        // still owns its unique staging file.
        guard previewToken == token else {
            try? FileManager.default.removeItem(at: staging)
            return nil
        }
        previewRequestID = nil
        previewProgressByMedia[key] = nil

        let size = (try? staging.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard reply.ok, size > 0 else {
            try? FileManager.default.removeItem(at: staging)
            let isCancellation = reply.payload == "cancelled"
                || reply.payload.localizedCaseInsensitiveContains("context canceled")
            if !reply.ok, !isCancellation {
                errorMessage = reply.payload.isEmpty
                    ? "Could not load the Telegram preview."
                    : reply.payload
            }
            return nil
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            errorMessage = "Could not finish the Telegram preview: \(error.localizedDescription)"
            return nil
        }
        return destination
    }

    /// Stops an in-flight preview fetch. Called when the viewer closes or
    /// switches files; a completed cache entry is kept.
    func cancelPreview() {
        previewToken = UUID()
        if let requestID = previewRequestID {
            helperSession?.cancel(requestID: requestID)
        }
        previewRequestID = nil
        previewProgressByMedia.removeAll()
    }

    private func previewDestination(for message: TelegramMessage, in chat: TelegramChat) -> URL {
        previewsRoot.appendingPathComponent(
            "\(chat.id)-\(message.id)-\(Self.safeName(message.displayName))")
    }

    /// A crashed fetch can leave its unique staging file behind. Bootstrap
    /// runs before any preview can start in this process, so every staging
    /// file found there is stale.
    private func cleanStalePreviewStagingFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: previewsRoot,
            includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func logout() async {
        guard authState == .ready, let helperURL else { return }
        cancelPreview()
        if let task = helperStartTask {
            task.cancel()
            _ = await task.value
            helperStartTask = nil
        }
        await helperSession?.stop()
        helperSession = nil
        let result = await runHelper(helperURL, arguments: ["-logout"])
        guard result.exitCode == 0 else {
            errorMessage = result.stderrTail.isEmpty ? "Could not sign out of Telegram." : result.stderrTail
            return
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit/Telegram", isDirectory: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("session.json"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("peers.json"))

        cancelPreview()
        try? FileManager.default.removeItem(at: previewsRoot)

        authState = .loggedOut
        qrURL = nil
        selfName = nil
        chats = []
        messagesByChat = [:]
        downloadProgressByMedia = [:]
        downloadedFilesByMedia = [:]
        reservedDestinations = []
        previewProgressByMedia = [:]
        errorMessage = nil
        bootstrapped = true
    }

    // MARK: - Helper transport

    /// Match a complete line: `UNAUTHORIZED` also contains the substring
    /// `AUTHORIZED`, which previously made a fresh session look connected.
    nonisolated static func isAuthorizedStatus(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("AUTHORIZED")
    }

    private struct HelperResult {
        var exitCode: Int32
        var stdout: String
        var stderrTail: String
    }

    private func runHelper(
        _ executable: URL,
        arguments: [String],
        onLine: ((String) -> Void)? = nil
    ) async -> HelperResult {
        let process = ManagedProcess()
        let collector = LineCollector()
        process.onStdoutLine = { line in
            collector.append(line)
            onLine?(line)
        }
        process.onStderrLine = { _ in }
        let result = await process.run(executable: executable, arguments: arguments)
        return HelperResult(
            exitCode: result.exitCode,
            stdout: collector.joined,
            stderrTail: result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Naming

    /// Sanitize a Telegram-provided name before it becomes a path component
    /// or an argument in the tab-delimited helper protocol. Control
    /// characters include tabs and newlines; leaving them intact would let a
    /// crafted filename inject another command into the worker's stdin.
    nonisolated static func safeName(_ raw: String) -> String {
        var illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        illegal.formUnion(.controlCharacters)
        illegal.formUnion(.newlines)
        var value = raw.components(separatedBy: illegal).joined(separator: "_")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." { value = "telegram-file" }
        // Keep the whole path component below the common 255-byte limit and
        // preserve the extension so AVFoundation can still choose a decoder.
        if value.utf8.count > 180 {
            let ext = (value as NSString).pathExtension
            let base = (value as NSString).deletingPathExtension
            // A pathological extension must not defeat the path-component
            // limit; real media extensions are far shorter than 32 bytes.
            let suffix = ext.isEmpty ? "" : ".\(String(ext.prefix(32)))"
            let limit = max(1, 180 - suffix.utf8.count)
            var clipped = ""
            for character in base {
                let candidate = clipped + String(character)
                if candidate.utf8.count > limit { break }
                clipped = candidate
            }
            value = clipped + suffix
        }
        return value
    }

    private static func uniqueDestination(
        in folder: URL,
        filename: String,
        reserved: Set<String> = []
    ) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || reserved.contains(candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}

private extension JSONDecoder {
    static var telegram: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
