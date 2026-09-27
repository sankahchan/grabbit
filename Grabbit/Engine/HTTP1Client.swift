import Foundation
import Network
import Security

/// Minimal HTTP/1.1 client built on NWConnection (GET only).
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
/// Content-Length / chunked / close-delimited bodies. No proxy support yet
/// (URLSession handled system proxies automatically; NWConnection does not).
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
    }

    var onEvent: ((Event) -> Void)?

    private static let maxRedirects = 5
    private static let connectTimeout: TimeInterval = 30
    private static let idleTimeout: TimeInterval = 60

    private let queue: DispatchQueue
    private let rangeValue: String
    private let basicAuth: String?

    private var url: URL
    private var connection: NWConnection?
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
    init(url: URL, start: Int64, end: Int64, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
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
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: - Connection

    private func connect() {
        guard !cancelled, !finished else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            finish(with: .failed(ClientError.unsupportedScheme))
            return
        }
        guard let host = url.host, !host.isEmpty else {
            finish(with: .failed(ClientError.badURL))
            return
        }
        let isTLS = scheme == "https"
        let port = url.port ?? (isTLS ? 443 : 80)
        guard port > 0, port <= 65535 else {
            finish(with: .failed(ClientError.badURL))
            return
        }

        let parameters: NWParameters
        if isTLS {
            let tlsOptions = NWProtocolTLS.Options()
            // Advertise ONLY http/1.1 via ALPN. Without this the server may
            // negotiate h2 and then our raw HTTP/1.1 bytes would be garbage
            // to it (this is also what defeats URLSession's h2 multiplexing).
            // Implemented in ALPNPin.m: the sec_protocol_options ALPN
            // functions are not visible to Swift, so a tiny ObjC shim does it.
            GrabbitPinALPNToHTTP11(tlsOptions.securityProtocolOptions)
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = NWParameters.tcp
        }

        resetReceiveState()
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        armIdleTimer(seconds: Self.connectTimeout, error: .connectTimeout)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            self.handleState(state)
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        guard !cancelled, !finished else { return }
        switch state {
        case .ready:
            sendRequest()
        case .failed(let error):
            finish(with: .failed(ClientError.connectionFailed(error.localizedDescription)))
        case .cancelled:
            break // our own cancel(); stays silent
        default:
            break // .setup / .preparing / .waiting — the idle timer guards stalls
        }
    }

    // MARK: - Request

    private func sendRequest() {
        guard let conn = connection, !cancelled, !finished else { return }
        let payload = buildRequest()
        conn.send(content: payload, completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn, conn === self.connection,
                  !self.cancelled, !self.finished else { return }
            if let error {
                self.finish(with: .failed(ClientError.connectionFailed(error.localizedDescription)))
            } else {
                self.receiveHeaders()
            }
        })
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
            "User-Agent: Grabbit/1.0",
            "Accept-Encoding: identity",
            "Connection: close",
        ]
        if let basicAuth {
            lines.append("Authorization: Basic \(basicAuth)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    // MARK: - Response headers

    private func receiveHeaders() {
        guard let conn = connection, !cancelled, !finished else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection,
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
        connection?.cancel()
        connection = nil
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
        guard let conn = connection, !cancelled, !finished else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection,
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
        connection?.cancel()
        connection = nil
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
                break
            }
            guard buffer.count >= afterLine + size + 2 else { break } // incomplete chunk
            out.append(buffer[afterLine ..< afterLine + size])
            buffer.removeSubrange(..<(afterLine + size + 2))
        }
        return out
    }
}
