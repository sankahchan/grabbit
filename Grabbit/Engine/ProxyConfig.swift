import Foundation
import CFNetwork

/// User-configured proxy for Grabbit's own engines.
///
/// Applies to the native direct-download transport (HTTP1Client tunnels
/// through the proxy) and to torrents (aria2 `--http-proxy/--https-proxy`
/// / `--all-proxy` options). `.none` means direct connection; the
/// URLSession-based size probe still honors the *system* proxy on its own.
public struct ProxyConfig: Equatable {
    public var mode: ProxyMode = .none
    public var host: String = ""
    public var port: Int = 8080
    public var username: String = ""
    public var password: String = ""

    public init(mode: ProxyMode = .none, host: String = "", port: Int = 8080,
         username: String = "", password: String = "")
    {
        self.mode = mode
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = min(max(port, 1), 65535)
        self.username = username
        self.password = password
    }

    public init(settings: AppSettings) {
        self.init(
            mode: settings.proxyMode, host: settings.proxyHost,
            port: settings.proxyPort, username: settings.proxyUsername,
            password: settings.proxyPassword)
    }

    /// A proxy is only used when a mode is selected AND a host is set.
    public var isEnabled: Bool { mode != .none && !host.isEmpty }

    public var hasCredentials: Bool { !username.isEmpty || !password.isEmpty }

    /// Value for the `Proxy-Authorization` header on an HTTP CONNECT.
    public func proxyAuthorizationValue() -> String? {
        guard hasCredentials else { return nil }
        let raw = "\(username):\(password)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    /// aria2 command-line proxy options for a fresh daemon spawn.
    /// Credentials are percent-encoded so `user:pass@` never breaks the URL.
    public func aria2Arguments() -> [String] {
        guard isEnabled else { return [] }
        switch mode {
        case .none:
            return []
        case .http:
            let url = "http://\(encodedCredentials())\(host):\(port)"
            return ["--http-proxy=\(url)", "--https-proxy=\(url)"]
        case .socks5:
            return ["--all-proxy=socks5://\(encodedCredentials())\(host):\(port)"]
        }
    }

    /// Global options for aria2 `changeGlobalOption` (covers reclaimed
    /// daemons that were spawned before the proxy existed). When the proxy
    /// is disabled, empty strings are pushed — aria2 treats "" as
    /// "override with no proxy", so a previously-set proxy is cleared.
    public func aria2GlobalOptions() -> [String: String] {
        switch mode {
        case .none:
            return ["http-proxy": "", "https-proxy": "", "all-proxy": ""]
        case .http:
            let url = "http://\(encodedCredentials())\(host):\(port)"
            return ["http-proxy": url, "https-proxy": url, "all-proxy": ""]
        case .socks5:
            return [
                "http-proxy": "",
                "https-proxy": "",
                "all-proxy": "socks5://\(encodedCredentials())\(host):\(port)",
            ]
        }
    }

    /// `user:pass@`, percent-encoded so reserved characters never break
    /// the proxy URL. Empty when no credentials are set.
    private func encodedCredentials() -> String {
        guard hasCredentials else { return "" }
        let allowed = CharacterSet.urlUserAllowed
            .union(.urlPasswordAllowed)
            .subtracting(CharacterSet(charactersIn: ":@"))
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        return "\(user):\(pass)@"
    }

    /// `connectionProxyDictionary` for the URLSession-based size probe.
    /// Authenticated proxies are not supported on the probe path (URLSession
    /// needs an auth challenge handler); the probe just degrades to
    /// unknown-size while the actual download still authenticates.
    public func urlSessionProxyDictionary() -> [AnyHashable: Any]? {
        guard isEnabled else { return nil }
        switch mode {
        case .none:
            return nil
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        }
    }
}

/// Pure HTTP CONNECT / SOCKS5 handshake message builders and parsers.
/// Kept free of I/O so the wire format is unit-testable byte-for-byte.
public enum ProxyHandshake {
    // MARK: - HTTP CONNECT

    /// `CONNECT target:port HTTP/1.1` request (+ optional auth).
    public static func connectRequest(targetHost: String, targetPort: Int,
                               proxy: ProxyConfig) -> Data
    {
        var lines = [
            "CONNECT \(targetHost):\(targetPort) HTTP/1.1",
            "Host: \(targetHost):\(targetPort)",
        ]
        if let auth = proxy.proxyAuthorizationValue() {
            lines.append("Proxy-Authorization: \(auth)")
        }
        lines.append("")
        lines.append("")
        return Data((lines.joined(separator: "\r\n")).utf8)
    }

    /// True when the proxy answered 2xx to the CONNECT.
    static func isConnectSuccess(_ responseHead: Data) -> Bool {
        guard let head = String(data: responseHead, encoding: .utf8) ?? String(
            data: responseHead, encoding: .isoLatin1)
        else { return false }
        let statusLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200...299).contains(code)
    }

    // MARK: - SOCKS5 (RFC 1928 / RFC 1929)

    public enum Socks5Method: UInt8 {
        case noAuth = 0x00
        case userPass = 0x02
    }

    /// Greeting: version, one method (no-auth or username/password).
    static func socks5Greeting(hasCredentials: Bool) -> Data {
        Data([0x05, 0x01, hasCredentials ? Socks5Method.userPass.rawValue : Socks5Method.noAuth.rawValue])
    }

    /// Parses the 2-byte method-selection reply. Returns nil when the
    /// server refuses (0xFF) or the reply is malformed.
    static func parseSocks5Method(_ reply: Data) -> Socks5Method? {
        guard reply.count >= 2, reply[reply.startIndex] == 0x05 else { return nil }
        return Socks5Method(rawValue: reply[reply.startIndex + 1])
    }

    /// RFC 1929 username/password sub-negotiation request.
    static func socks5AuthRequest(username: String, password: String) -> Data {
        let user = Array(username.utf8.prefix(255))
        let pass = Array(password.utf8.prefix(255))
        var out: [UInt8] = [0x01, UInt8(user.count)]
        out.append(contentsOf: user)
        out.append(UInt8(pass.count))
        out.append(contentsOf: pass)
        return Data(out)
    }

    /// True when the auth reply is `0x01 0x00` (success).
    static func isSocks5AuthSuccess(_ reply: Data) -> Bool {
        reply.count >= 2 && reply[reply.startIndex] == 0x01 && reply[reply.startIndex + 1] == 0x00
    }

    /// CONNECT request with a domain-name address (ATYP 0x03).
    static func socks5ConnectRequest(targetHost: String, targetPort: Int) -> Data {
        let host = Array(targetHost.utf8.prefix(255))
        var out: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)]
        out.append(contentsOf: host)
        out.append(UInt8((targetPort >> 8) & 0xFF))
        out.append(UInt8(targetPort & 0xFF))
        return Data(out)
    }

    /// Total reply length once the first 4 bytes (`VER REP RSV ATYP`) are
    /// known; nil for unknown address types.
    static func socks5ReplyLength(first4: Data, remainder: Data) -> Int? {
        guard first4.count >= 4 else { return nil }
        switch first4[first4.startIndex + 3] {
        case 0x01: return 4 + 4 + 2 // IPv4
        case 0x04: return 4 + 16 + 2 // IPv6
        case 0x03:
            guard let len = remainder.first else { return nil }
            return 4 + 1 + Int(len) + 2 // domain
        default: return nil
        }
    }

    /// True when the full reply is `VER=0x05, REP=0x00` (granted).
    static func isSocks5ConnectSuccess(_ reply: Data) -> Bool {
        reply.count >= 4 && reply[reply.startIndex] == 0x05 && reply[reply.startIndex + 1] == 0x00
    }
}
