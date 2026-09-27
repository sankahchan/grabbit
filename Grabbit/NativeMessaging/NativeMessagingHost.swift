import Foundation

/// Chrome/Firefox native-messaging host endpoint.
///
/// The browser extension spawns Grabbit with the `--native-messaging` argument;
/// stdin/stdout then become the native-messaging channel instead of a normal
/// launch. The extension's manifest lives at:
///   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.sankahchan.grabbit.json
/// (and the equivalent Firefox location), with `"path"` pointing at the
/// Grabbit.app bundle executable and `"--native-messaging"` in `"args"`.
///
/// Wire protocol (Chrome native messaging): each message is a 4-byte
/// little-endian length prefix followed by that many bytes of UTF-8 JSON.
/// `onMessage` is invoked on the reader thread — hop to `@MainActor` in the app.
public final class NativeMessagingHost {
    public struct NativeMessage: Decodable {
        public var url: URL
        public var source: String?
        public var title: String?
        public var filename: String?
        /// Page the link came from — powers the expired-link "reopen source"
        /// flow. Never a secret.
        public var pageUrl: URL?
        /// Request headers captured by the extension (Cookie, Referer, …).
        public var headers: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case url, source, title, filename, pageUrl, headers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(URL.self, forKey: .url)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            filename = try container.decodeIfPresent(String.self, forKey: .filename)
            // Lenient: the extension may send "" when there is no page URL;
            // that must not fail the whole message.
            if let raw = try container.decodeIfPresent(String.self, forKey: .pageUrl),
               !raw.isEmpty
            {
                pageUrl = URL(string: raw)
            } else {
                pageUrl = nil
            }
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        }
    }

    private struct Ack: Encodable {
        var ok: Bool
        var url: URL
    }

    public var onMessage: ((NativeMessage) -> Void)?

    private let stateLock = NSLock()
    private var _running = false
    private var worker: Thread?

    private var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }

    public init() {}

    /// Spawns the background reader thread. Safe to call once; subsequent
    /// calls are no-ops.
    public func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "com.sankahchan.grabbit.native-messaging"
        thread.qualityOfService = .utility
        worker = thread
        thread.start()
    }

    /// Signals the reader thread to stop. The loop also exits on its own when
    /// stdin hits EOF (i.e. the browser disconnects) — at that point the app
    /// layer should terminate the process, since a native-messaging host has
    /// no reason to linger without its browser peer.
    public func stop() {
        running = false
        worker?.cancel()
        worker = nil
    }

    private func readLoop() {
        let stdin = FileHandle.standardInput
        while running {
            // 4-byte little-endian length prefix.
            let lengthData: Data
            do {
                guard let data = try stdin.read(upToCount: 4), data.count == 4 else { break }
                lengthData = data
            } catch {
                break
            }
            let length = lengthData.withUnsafeBytes { raw in
                raw.load(as: UInt32.self).littleEndian
            }
            // Sanity cap: a URL + metadata message is never anywhere near 100MB.
            guard length > 0, length < 100 * 1024 * 1024 else { break }

            let payload: Data
            do {
                guard let data = try stdin.read(upToCount: Int(length)),
                      data.count == Int(length) else { break }
                payload = data
            } catch {
                break
            }

            if let message = try? JSONDecoder().decode(NativeMessage.self, from: payload) {
                onMessage?(message)
                sendAck(for: message)
            }
            // Undecodable payloads are skipped (still acked implicitly by
            // continuing); the channel stays alive for the next message.
        }
        running = false
    }

    /// Writes a 4-byte LE length prefix + JSON ack to stdout.
    public func sendAck(for message: NativeMessage) {
        guard let body = try? JSONEncoder().encode(Ack(ok: true, url: message.url)) else { return }
        var leLength = UInt32(body.count).littleEndian
        var frame = Data(bytes: &leLength, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        try? FileHandle.standardOutput.write(contentsOf: frame)
    }
}
