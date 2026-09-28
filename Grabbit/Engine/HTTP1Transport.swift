import Foundation
import Network
import Security
import Darwin

/// Byte-stream transport beneath HTTP1Client's HTTP/1.1 state machine.
///
/// NWConnection cannot be pointed at a proxy, so proxied downloads go
/// through `ProxyHTTP1Transport`: a BSD socket performs the HTTP CONNECT
/// or SOCKS5 handshake, then — for https targets — the socket is upgraded
/// to TLS via CFStream SSL settings (SNI + system trust validation, ALPN
/// pinned to http/1.1 by the server's choice of the offered protocols…
/// in practice the tunnel only ever carries our HTTP/1.1 bytes).
/// Unproxied downloads keep the existing NWConnection path.
///
/// The client sees the same connect/send/receive/cancel shape either way,
/// so its one-TCP-connection-per-segment behavior is unchanged.
protocol HTTP1Transport: AnyObject {
    /// Establishes the stream; exactly one of the callbacks fires.
    func connect(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void)
    /// Sends the whole payload, then calls completion (nil = sent).
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    /// Reads up to 64KB; (nil, true, nil) = clean EOF.
    func receive(completion: @escaping (Data?, Bool, Error?) -> Void)
    func cancel()
}

enum ProxyTransportError: Error, LocalizedError {
    case proxyDisabled
    case proxyUnreachable(String)
    case proxyHandshakeFailed(String)
    case proxyAuthFailed
    case tlsFailed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .proxyDisabled: "Proxy is not configured."
        case .proxyUnreachable(let d): "Proxy unreachable: \(d)"
        case .proxyHandshakeFailed(let d): "Proxy handshake failed: \(d)"
        case .proxyAuthFailed: "Proxy authentication failed."
        case .tlsFailed(let d): "TLS failed: \(d)"
        case .ioFailed(let d): "Connection failed: \(d)"
        }
    }
}

// MARK: - Direct (no proxy): the existing NWConnection path

/// Direct transport: the pre-proxy NWConnection behavior, unchanged.
final class NWHTTP1Transport: HTTP1Transport {
    private let url: URL
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var cancelled = false

    init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    func connect(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        guard !cancelled else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            onFailure(HTTP1Client.ClientError.unsupportedScheme)
            return
        }
        guard let host = url.host, !host.isEmpty else {
            onFailure(HTTP1Client.ClientError.badURL)
            return
        }
        let isTLS = scheme == "https"
        let port = url.port ?? (isTLS ? 443 : 80)
        guard port > 0, port <= 65535 else {
            onFailure(HTTP1Client.ClientError.badURL)
            return
        }

        let parameters: NWParameters
        if isTLS {
            let tlsOptions = NWProtocolTLS.Options()
            // Advertise ONLY http/1.1 via ALPN (ObjC shim; the
            // sec_protocol_options ALPN functions are not visible to Swift).
            GrabbitPinALPNToHTTP11(tlsOptions.securityProtocolOptions)
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = NWParameters.tcp
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection, !self.cancelled else { return }
            switch state {
            case .ready:
                onReady()
            case .failed(let error):
                onFailure(error)
            case .cancelled:
                break // our own cancel(); stays silent
            default:
                break // .setup / .preparing / .waiting — the client's idle timer guards stalls
            }
        }
        conn.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard let conn = connection, !cancelled else {
            completion(ProxyTransportError.ioFailed("cancelled"))
            return
        }
        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn, conn === self.connection, !self.cancelled else { return }
            completion(error)
        })
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        guard let conn = connection, !cancelled else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, !self.cancelled else { return }
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        cancelled = true
        connection?.cancel()
        connection = nil
    }
}

// MARK: - Proxied: BSD socket + CONNECT/SOCKS5 + CFStream TLS

/// Proxied transport. Handshake and I/O run blocking-style on a private
/// serial queue; completions hop back to the client's queue. `cancel()`
/// closes the socket/streams from any thread, which unblocks pending I/O.
final class ProxyHTTP1Transport: HTTP1Transport {
    private let targetHost: String
    private let targetPort: Int
    private let useTLS: Bool
    private let proxy: ProxyConfig
    private let clientQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "com.sankahchan.grabbit.proxy-io")
    private let lock = NSLock()

    /// Raw socket, owned until a TLS upgrade hands it to the CFStreams.
    private var fd: Int32 = -1
    private var readStream: CFReadStream?
    private var writeStream: CFWriteStream?
    private var cancelled = false

    private static let ioTimeout: TimeInterval = 30

    init(targetURL: URL, proxy: ProxyConfig, queue: DispatchQueue) {
        let isTLS = (targetURL.scheme ?? "").lowercased() == "https"
        self.targetHost = targetURL.host ?? ""
        self.targetPort = targetURL.port ?? (isTLS ? 443 : 80)
        self.useTLS = isTLS
        self.proxy = proxy
        self.clientQueue = queue
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    // MARK: HTTP1Transport

    func connect(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.establish()
                if self.isCancelled {
                    self.teardown()
                    return
                }
                self.clientQueue.async { onReady() }
            } catch {
                self.teardown()
                self.clientQueue.async { onFailure(error) }
            }
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let result: Error?
            do {
                try self.writeAll(data)
                result = nil
            } catch {
                result = error
            }
            self.clientQueue.async { completion(result) }
        }
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let (data, eof) = try self.readOnce(max: 65536)
                self.clientQueue.async { completion(data, eof, nil) }
            } catch {
                self.clientQueue.async { completion(nil, false, error) }
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        teardown() // unblocks any thread parked in recv/read
    }

    // MARK: - Establishment

    private func establish() throws {
        guard proxy.isEnabled else { throw ProxyTransportError.proxyDisabled }
        let socketFD = try Self.openSocket(host: proxy.host, port: proxy.port, timeout: Self.ioTimeout)
        lock.withLock { fd = socketFD }
        switch proxy.mode {
        case .http:
            try httpConnect()
        case .socks5:
            try socks5Handshake()
        case .none:
            throw ProxyTransportError.proxyDisabled
        }
        if useTLS {
            try upgradeToTLS()
        }
    }

    private func teardown() {
        let rs: CFReadStream?
        let ws: CFWriteStream?
        let socketFD: Int32
        lock.withLock {
            rs = readStream
            ws = writeStream
            socketFD = fd
            readStream = nil
            writeStream = nil
            fd = -1
        }
        if let rs { CFReadStreamClose(rs) }
        if let ws { CFWriteStreamClose(ws) }
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    // MARK: Handshakes

    private func httpConnect() throws {
        try writeAll(ProxyHandshake.connectRequest(
            targetHost: targetHost, targetPort: targetPort, proxy: proxy))
        let head = try readHead()
        guard ProxyHandshake.isConnectSuccess(head) else {
            if headStatusCode(head) == 407 { throw ProxyTransportError.proxyAuthFailed }
            throw ProxyTransportError.proxyHandshakeFailed("CONNECT rejected by proxy")
        }
    }

    private func socks5Handshake() throws {
        try writeAll(ProxyHandshake.socks5Greeting(hasCredentials: proxy.hasCredentials))
        let methodReply = try readExact(2)
        guard let method = ProxyHandshake.parseSocks5Method(methodReply) else {
            throw ProxyTransportError.proxyHandshakeFailed("SOCKS5 method negotiation failed")
        }
        if method == .userPass {
            guard proxy.hasCredentials else { throw ProxyTransportError.proxyAuthFailed }
            try writeAll(ProxyHandshake.socks5AuthRequest(
                username: proxy.username, password: proxy.password))
            guard ProxyHandshake.isSocks5AuthSuccess(try readExact(2)) else {
                throw ProxyTransportError.proxyAuthFailed
            }
        }
        try writeAll(ProxyHandshake.socks5ConnectRequest(
            targetHost: targetHost, targetPort: targetPort))
        // The reply length depends on the address type; for a domain name
        // the length byte arrives after the first 4 bytes.
        let first4 = try readExact(4)
        var remainder = Data()
        var total = ProxyHandshake.socks5ReplyLength(first4: first4, remainder: remainder)
        if total == nil {
            remainder = try readExact(1)
            total = ProxyHandshake.socks5ReplyLength(first4: first4, remainder: remainder)
        }
        guard let total else {
            throw ProxyTransportError.proxyHandshakeFailed("bad SOCKS5 address type")
        }
        let rest = try readExact(total - 4 - remainder.count)
        guard ProxyHandshake.isSocks5ConnectSuccess(first4 + remainder + rest) else {
            throw ProxyTransportError.proxyHandshakeFailed("SOCKS5 connect rejected")
        }
    }

    /// Wraps the (already handshaked) socket in TLS. The streams take
    /// ownership of the socket; `fd` is cleared so teardown won't
    /// double-close it.
    private func upgradeToTLS() throws {
        let socketFD = lock.withLock { () -> Int32 in
            let v = fd
            fd = -1
            return v
        }
        guard socketFD >= 0 else { throw ProxyTransportError.tlsFailed("no socket") }
        var rs: Unmanaged<CFReadStream>?
        var ws: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFD, &rs, &ws)
        guard let readStream = rs?.takeRetainedValue(),
              let writeStream = ws?.takeRetainedValue()
        else {
            Darwin.close(socketFD)
            throw ProxyTransportError.tlsFailed("stream creation failed")
        }
        // kCFStreamSSLPeerName drives both SNI and certificate-name
        // validation against the *target* host (not the proxy).
        let ssl: [CFString: Any] = [
            kCFStreamSSLLevel: kCFStreamSocketSecurityLevelNegotiatedSSL,
            kCFStreamSSLPeerName: targetHost as CFString,
        ]
        let key = CFStreamPropertyKey(kCFStreamPropertySSLSettings as String)
        CFReadStreamSetProperty(readStream, key, ssl as CFDictionary)
        CFWriteStreamSetProperty(writeStream, key, ssl as CFDictionary)
        guard CFReadStreamOpen(readStream), CFWriteStreamOpen(writeStream) else {
            CFReadStreamClose(readStream)
            CFWriteStreamClose(writeStream)
            throw ProxyTransportError.tlsFailed("open failed")
        }
        lock.withLock {
            self.readStream = readStream
            self.writeStream = writeStream
        }
    }

    // MARK: - Blocking I/O (always on ioQueue)

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                if isCancelled { throw ProxyTransportError.ioFailed("cancelled") }
                // Snapshot under the lock; the syscall itself runs unlocked
                // so cancel() (which takes the lock) never blocks on I/O.
                let (ws, socketFD): (CFWriteStream?, Int32) = lock.withLock { (writeStream, fd) }
                let n: Int
                if let ws {
                    n = CFWriteStreamWrite(ws, base.advanced(by: sent).assumingMemoryBound(to: UInt8.self), data.count - sent)
                } else if socketFD >= 0 {
                    n = Darwin.send(socketFD, base.advanced(by: sent), data.count - sent, 0)
                } else {
                    n = -1
                }
                if n <= 0 { throw ProxyTransportError.ioFailed("write failed") }
                sent += n
            }
        }
    }

    /// Reads up to `max` bytes; never over-reads.
    private func readOnce(max: Int) throws -> (Data?, Bool) {
        var buf = [UInt8](repeating: 0, count: max)
        let (rs, socketFD): (CFReadStream?, Int32) = lock.withLock { (readStream, fd) }
        let n: Int
        if let rs {
            n = CFReadStreamRead(rs, &buf, max)
        } else if socketFD >= 0 {
            n = Darwin.recv(socketFD, &buf, max, 0)
        } else {
            n = -1
        }
        if n > 0 { return (Data(buf.prefix(n)), false) }
        if n == 0 { return (nil, true) } // clean EOF
        throw ProxyTransportError.ioFailed(String(cString: strerror(errno)))
    }

    private func readExact(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            if isCancelled { throw ProxyTransportError.ioFailed("cancelled") }
            let (chunk, eof) = try readOnce(max: count - out.count)
            if let chunk, !chunk.isEmpty { out.append(chunk) }
            if eof { throw ProxyTransportError.ioFailed("unexpected EOF") }
        }
        return out
    }

    /// Reads a response head byte-by-byte up to the blank line so nothing
    /// past the head is ever consumed from the socket (bytes after the
    /// head belong to the TLS handshake or the response body).
    private func readHead() throws -> Data {
        var out = Data()
        let tail: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while out.count < 65536 {
            if out.count >= 4,
               Array(out.suffix(4)) == tail
            {
                return out
            }
            if isCancelled { throw ProxyTransportError.ioFailed("cancelled") }
            let (chunk, eof) = try readOnce(max: 1)
            if let chunk, !chunk.isEmpty { out.append(chunk) }
            if eof { break }
        }
        return out
    }

    private func headStatusCode(_ head: Data) -> Int? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    // MARK: - Socket connect with timeout

    /// Non-blocking connect + poll(), trying each resolved address.
    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let list = res else {
            throw ProxyTransportError.proxyUnreachable("DNS failed for \(host)")
        }
        defer { freeaddrinfo(list) }

        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            if connectWithTimeout(fd: fd, addr: ai.pointee.ai_addr, len: ai.pointee.ai_addrlen, timeout: timeout) {
                return fd
            }
            Darwin.close(fd)
        }
        throw ProxyTransportError.proxyUnreachable("could not reach \(host):\(port)")
    }

    private static func connectWithTimeout(fd: Int32, addr: UnsafeMutablePointer<sockaddr>?, len: socklen_t, timeout: TimeInterval) -> Bool {
        let savedFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, savedFlags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, savedFlags) }

        if Darwin.connect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waited = Darwin.poll(&pfd, 1, Int32(timeout * 1000))
        guard waited > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var soError: Int32 = 0
        var optLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &optLen)
        guard soError == 0 else { return false }

        // Back to blocking I/O, with send/recv timeouts as a backstop.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
        return true
    }
}
