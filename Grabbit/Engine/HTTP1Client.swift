import Foundation
import Security

/// Minimal HTTP/1.1 client (GET only), one TCP connection per segment.
///
/// Why this exists: URLSession negotiates HTTP/2 via ALPN whenever the server
/// offers it, which multiplexes every segment task onto a SINGLE TCP
/// connection. On a high-latency link that one connection's flow-control
/// window caps aggregate throughput (~300 KB/s in practice) no matter how
/// many "connections" the app thinks it opened. aria2 — the engine behind
/// Motrix — is HTTP/1.1-only, so each of its segments rides a real TCP
/// connection. This client does the same: one TCP connection per segment,
/// TLS with ALPN pinned to "http/1.1" for https.
///
/// Scope: http/https GET with a Range header, redirect following (max 5),
/// Content-Length / chunked / close-delimited bodies. Proxy support lives
/// one layer down: `HTTP1Transport` (direct NWConnection, or a BSD socket
/// doing HTTP CONNECT / SOCKS5 when a proxy is configured).
final class HTTP1Client {
    enum Event {
        /// Status line + headers received; body follows via `.data`.
        case response(status: Int, headers: [String: String])
        case data(Data)
        case finished
        case failed(Error)
    }

    enum ClientError: Error, LocalizedError {
        case unsupportedScheme
        case badURL
        case tooManyRedirects
        case redirectWithoutLocation
        case connectTimeout
        case idleTimeout
        case connectionFailed(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme: "Only http/https URLs are supported."
            case .badURL: "The URL is invalid."
            case .tooManyRedirects: "Too many redirects."
            case .redirectWithoutLocation: "The server redirected without a Location header."
            case .connectTimeout: "Connection timed out."
            case .idleTimeout: "The connection stalled (no data for a while)."
            case .connectionFailed(let detail): detail.isEmpty ? "Connection failed." : detail
            case .malformedResponse: "The server sent a malformed response."
            }
        }

        /// Transient network failures are worth retrying; configuration
        /// errors (bad URL, redirect loops) will just fail again.
        var isRetryable: Bool {
            switch self {
            case .connectTimeout, .idleTimeout, .connectionFailed, .malformedResponse:
                true
            case .unsupportedScheme, .badURL, .tooManyRedirects, .redirectWithoutLocation:
                false
            }
        }
    }

    var onEvent: ((Event) -> Void)?

    private static let maxRedirects = 5
    private static let connectTimeout: TimeInterval = 30
    private static let idleTimeout: TimeInterval = 60

    private let queue: DispatchQueue
    private let rangeValue: String
    private let basicAuth: String?
    private let extraHeaders: [String: String]
    /// When set and enabled, segments tunnel through the proxy instead of
    /// connecting directly. Read at segment start, so a settings change
    /// applies to newly launched segments.
    var proxyConfig: ProxyConfig?

    private var url: URL
    private var transport: HTTP1Transport?
    private var redirectCount = 0
    private var cancelled = false
    private var finished = false

    // Receive state, reset on every (re)connect.
    private var headerBuffer = Data()
    private var contentLength: Int64?
    private var chunked = false
    private var chunkedDecoder = ChunkedDecoder()
    private var bodyReceived: Int64 = 0

    private var idleTimer: DispatchWorkItem?

    /// - Parameters:
    ///   - url: The resource URL.
    ///   - start: First byte offset (inclusive).
    ///   - end: Last byte offset (inclusive), or `.max` for open-ended.
    ///   - queue: Serial queue every event is delivered on.
    ///   - extraHeaders: Per-download headers captured by the browser
    ///     extension (Cookie, Referer, …). A provided `User-Agent` replaces
    ///     the default; protocol headers (Host, Range, Connection, …) are
    ///     never overridden.
    ///   - proxyConfig: Optional proxy; when enabled the transport tunnels
    ///     through it, otherwise it connects directly.
    init(url: URL, start: Int64, end: Int64, queue: DispatchQueue,
         extraHeaders: [String: String] = [:], proxyConfig: ProxyConfig? = nil)
    {
        self.url = url
        self.queue = queue
        self.extraHeaders = extraHeaders
        self.proxyConfig = proxyConfig
        rangeValue = end == .max ? "bytes=\(start)-" : "bytes=\(start)-\(end)"
        if let user = url.user, !user.isEmpty {
            let credentials = "\(user):\(url.password ?? "")"
            basicAuth = Data(credentials.utf8).base64EncodedString()
        } else {
            basicAuth = nil
        }
    }

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.idleTimer?.cancel()
            self.idleTimer = nil
            self.transport?.cancel()
            self.transport = nil
        }
    }

    // MARK: - Connection

    private func connect() {
        guard !cancelled, !finished else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            finish(with: .failed(ClientError.unsupportedScheme))
            return
        }
        guard url.host != nil else {
            finish(with: .failed(ClientError.badURL))
            return
        }

        let transport: HTTP1Transport
        if let proxy = proxyConfig, proxy.isEnabled {
            transport = ProxyHTTP1Transport(targetURL: url, proxy: proxy, queue: queue)
        } else {
            transport = NWHTTP1Transport(url: url, queue: queue)
        }
        self.transport = transport

        resetReceiveState()
        armIdleTimer(seconds: Self.connectTimeout, error: .connectTimeout)
        transport.connect(onReady: { [weak self, weak transport] in
            guard let self, let transport, transport === self.transport,
                  !self.cancelled, !self.finished else { return }
            // Connected: the idle timer now guards request/response stalls.
            self.armIdleTimer(seconds: Self.idleTimeout, error: .idleTimeout)
            self.sendRequest()
        }, onFailure: { [weak self, weak transport] error in
            guard let self, let transport, transport === self.transport,
                  !self.cancelled, !self.finished else { return }
            self.finish(with: .failed(ClientError.connectionFailed(error.localizedDescription)))
        })
    }

    // MARK: - Request

    private func sendRequest() {
        guard let transport, !cancelled, !finished else { return }
        let payload = buildRequest()
        transport.send(payload) { [weak self, weak transport] error in
            guard let self, let transport, transport === self.transport,
                  !self.cancelled, !self.finished else { return }
            if let error {
                self.finish(with: .failed(ClientError.connectionFailed(error.localizedDescription)))
            } else {
                self.receiveHeaders()
            }
        }
    }

    private func buildRequest() -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? ""
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?" + query
        }

        var hostHeader = url.host ?? ""
        if hostHeader.contains(":"), !hostHeader.hasPrefix("[") {
            hostHeader = "[\(hostHeader)]" // IPv6 literal
        }
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        if let explicit = url.port, explicit != defaultPort {
            hostHeader += ":\(explicit)"
        }

        var lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "Range: \(rangeValue)",
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Accept-Encoding: identity",
            "Connection: close",
        ]
        if let basicAuth {
            lines.append("Authorization: Basic \(basicAuth)")
        }
        // Browser-captured headers (Cookie, Referer, custom User-Agent, …).
        // Protocol-critical headers can never be overridden, and CR/LF are
        // stripped from names/values to block header injection.
        let protected: Set<String> = [
            "host", "range", "connection", "content-length",
            "transfer-encoding", "accept-encoding",
        ]
        for (rawName, rawValue) in extraHeaders {
            let name = rawName
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let value = rawValue
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            guard !name.isEmpty, !protected.contains(name.lowercased()) else { continue }
            if name.lowercased() == "user-agent" {
                // Replace the default rather than sending two User-Agent lines.
                lines.removeAll { $0.lowercased().hasPrefix("user-agent:") }
            }
            if name.lowercased() == "authorization", basicAuth != nil {
                lines.removeAll { $0.lowercased().hasPrefix("authorization:") }
            }
            lines.append("\(name): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    // MARK: - Response headers

    private func receiveHeaders() {
        guard let transport, !cancelled, !finished else { return }
        transport.receive { [weak self, weak transport] data, isComplete, error in
            guard let self, let transport, transport === self.transport,
                  !self.cancelled, !self.finished else { return }
            if let error {
                self.finish(with: .failed(ClientError.connectionFailed(error.localizedDescription)))
                return
            }
            if let data, !data.isEmpty { self.headerBuffer.append(data) }
            if let end = self.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let block = self.headerBuffer[..<end.lowerBound]
                let leftover = Data(self.headerBuffer[end.upperBound...])
                self.headerBuffer.removeAll(keepingCapacity: true)
                self.handleHeaderBlock(block, leftover: leftover)
            } else if isComplete {
                self.finish(with: .failed(ClientError.malformedResponse))
            } else {
                self.receiveHeaders()
            }
        }
    }

    private func handleHeaderBlock(_ block: Data, leftover: Data) {
        guard let text = String(data: block, encoding: .utf8)
            ?? String(data: block, encoding: .isoLatin1)
        else {
            finish(with: .failed(ClientError.malformedResponse))
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            finish(with: .failed(ClientError.malformedResponse))
            return
        }
        // e.g. "HTTP/1.1 206 Partial Content"
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            finish(with: .failed(ClientError.malformedResponse))
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, headers[name] == nil else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // URLSession followed redirects for us; do it manually now.
        if (300...308).contains(status), status != 304 {
            followRedirect(headers: headers)
            return
        }

        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.contains("chunked") {
            chunked = true
        } else if let lengthValue = headers["content-length"], let length = Int64(lengthValue) {
            contentLength = length
        }

        armIdleTimer(seconds: Self.idleTimeout, error: .idleTimeout)
        onEvent?(.response(status: status, headers: headers))
        guard !cancelled, !finished else { return }
        if !leftover.isEmpty { handleBodyData(leftover) }
        if isBodyComplete {
            finish(with: .finished)
        } else {
            receiveBody()
        }
    }

    private func followRedirect(headers: [String: String]) {
        guard redirectCount < Self.maxRedirects else {
            finish(with: .failed(ClientError.tooManyRedirects))
            return
        }
        guard let location = headers["location"], !location.isEmpty,
              let next = URL(string: location, relativeTo: url)?.absoluteURL else {
            finish(with: .failed(ClientError.redirectWithoutLocation))
            return
        }
        redirectCount += 1
        url = next
        transport?.cancel()
        transport = nil
        connect() // new host => new TCP connection; absolute Range offsets stay valid
    }

    // MARK: - Body

    private var isBodyComplete: Bool {
        if chunked { return chunkedDecoder.isFinished }
        if let length = contentLength { return bodyReceived >= length }
        return false // close-delimited: only EOF completes the body
    }

    private var isCloseDelimited: Bool {
        !chunked && contentLength == nil
    }

    private func receiveBody() {
        guard let transport, !cancelled, !finished else { return }
        transport.receive { [weak self, weak transport] data, isComplete, error in
            guard let self, let transport, transport === self.transport,
                  !self.cancelled, !self.finished else { return }
            if let error {
                // A RST arriving right after the final byte is harmless.
                self.finish(with: self.isBodyComplete
                    ? .finished
                    : .failed(ClientError.connectionFailed(error.localizedDescription)))
                return
            }
            if let data, !data.isEmpty {
                self.armIdleTimer(seconds: Self.idleTimeout, error: .idleTimeout)
                self.handleBodyData(data)
                if self.isBodyComplete {
                    self.finish(with: .finished)
                    return
                }
            }
            if isComplete {
                if self.isCloseDelimited {
                    // No Content-Length: EOF is the body terminator.
                    self.finish(with: .finished)
                } else {
                    self.finish(with: self.isBodyComplete
                        ? .finished
                        : .failed(ClientError.connectionFailed("The connection closed before the download finished.")))
                }
                return
            }
            self.receiveBody()
        }
    }

    private func handleBodyData(_ data: Data) {
        if chunked {
            for piece in chunkedDecoder.feed(data) {
                bodyReceived += Int64(piece.count)
                onEvent?(.data(piece))
            }
            return
        }
        if let length = contentLength {
            let remaining = length - bodyReceived
            guard remaining > 0 else { return }
            let take = data.prefix(Int(min(remaining, Int64(data.count))))
            bodyReceived += Int64(take.count)
            onEvent?(.data(Data(take)))
            return
        }
        bodyReceived += Int64(data.count)
        onEvent?(.data(data))
    }

    // MARK: - Timers & teardown

    private func resetReceiveState() {
        headerBuffer.removeAll(keepingCapacity: true)
        contentLength = nil
        chunked = false
        chunkedDecoder = ChunkedDecoder()
        bodyReceived = 0
    }

    private func armIdleTimer(seconds: TimeInterval, error: ClientError) {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finish(with: .failed(error))
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(with event: Event) {
        guard !finished else { return }
        finished = true
        idleTimer?.cancel()
        idleTimer = nil
        transport?.cancel()
        transport = nil
        if !cancelled { onEvent?(event) }
    }
}

/// Incremental HTTP/1.1 chunked transfer-encoding decoder.
struct ChunkedDecoder {
    private var buffer = Data()
    private var inTrailers = false
    private(set) var isFinished = false

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while !isFinished {
            if inTrailers {
                if buffer.prefix(2) == Data("\r\n".utf8) {
                    // Bare CRLF: empty trailer line ends the body.
                    buffer.removeSubrange(..<2)
                    isFinished = true
                } else if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    buffer.removeSubrange(..<end.upperBound)
                    isFinished = true
                }
                break
            }
            guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(data: buffer[..<lineEnd.lowerBound], encoding: .utf8)?
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16) else { break } // wait for more data
            let afterLine = lineEnd.upperBound
            if size == 0 {
                // Final chunk: either a bare CRLF (no trailers) or trailer lines.
                if buffer[afterLine...].prefix(2) == Data("\r\n".utf8) {
                    buffer.removeSubrange(..<(afterLine + 2))
                    isFinished = true
                } else {
                    buffer.removeSubrange(..<afterLine)
                    inTrailers = true
                }
                continue // process trailers immediately; don't wait for the next feed
            }
            guard buffer.count >= afterLine + size + 2 else { break } // incomplete chunk
            out.append(buffer[afterLine ..< afterLine + size])
            buffer.removeSubrange(..<(afterLine + size + 2))
        }
        return out
    }
}
