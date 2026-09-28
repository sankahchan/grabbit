import XCTest
@testable import Grabbit

/// Phase 5 proxy: wire-format tests for the HTTP CONNECT / SOCKS5
/// handshakes plus ProxyConfig behavior. The socket/TLS machinery itself
/// is I/O and is verified at runtime, not here.
final class ProxyTests: XCTestCase {
    // MARK: - HTTP CONNECT

    func testConnectRequestNoAuth() {
        let proxy = ProxyConfig(mode: .http, host: "proxy.local", port: 8080)
        let data = ProxyHandshake.connectRequest(
            targetHost: "example.com", targetPort: 443, proxy: proxy)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
    }

    func testConnectRequestWithAuth() {
        let proxy = ProxyConfig(
            mode: .http, host: "proxy.local", port: 8080,
            username: "user", password: "pass")
        let text = String(
            data: ProxyHandshake.connectRequest(
                targetHost: "example.com", targetPort: 80, proxy: proxy),
            encoding: .utf8)
        // base64("user:pass") == "dXNlcjpwYXNz"
        XCTAssertTrue(text?.contains("Proxy-Authorization: Basic dXNlcjpwYXNz\r\n") == true)
        XCTAssertTrue(text?.hasPrefix("CONNECT example.com:80 HTTP/1.1\r\n") == true)
    }

    func testIsConnectSuccess() {
        XCTAssertTrue(ProxyHandshake.isConnectSuccess(
            Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)))
        XCTAssertTrue(ProxyHandshake.isConnectSuccess(
            Data("HTTP/1.0 200 OK\r\nProxy-Agent: x\r\n\r\n".utf8)))
        XCTAssertFalse(ProxyHandshake.isConnectSuccess(
            Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8)))
        XCTAssertFalse(ProxyHandshake.isConnectSuccess(
            Data("HTTP/1.1 500 Nope\r\n\r\n".utf8)))
        XCTAssertFalse(ProxyHandshake.isConnectSuccess(Data("garbage".utf8)))
        XCTAssertFalse(ProxyHandshake.isConnectSuccess(Data()))
    }

    // MARK: - SOCKS5

    func testSocks5Greeting() {
        XCTAssertEqual(
            Array(ProxyHandshake.socks5Greeting(hasCredentials: false)),
            [0x05, 0x01, 0x00])
        XCTAssertEqual(
            Array(ProxyHandshake.socks5Greeting(hasCredentials: true)),
            [0x05, 0x01, 0x02])
    }

    func testParseSocks5Method() {
        XCTAssertEqual(
            ProxyHandshake.parseSocks5Method(Data([0x05, 0x00])), .noAuth)
        XCTAssertEqual(
            ProxyHandshake.parseSocks5Method(Data([0x05, 0x02])), .userPass)
        XCTAssertNil(ProxyHandshake.parseSocks5Method(Data([0x05, 0xFF])))
        XCTAssertNil(ProxyHandshake.parseSocks5Method(Data([0x04, 0x00])))
        XCTAssertNil(ProxyHandshake.parseSocks5Method(Data([0x05])))
    }

    func testSocks5AuthRequest() {
        // "u" = 0x75, "pw" = 0x70 0x77
        XCTAssertEqual(
            Array(ProxyHandshake.socks5AuthRequest(username: "u", password: "pw")),
            [0x01, 0x01, 0x75, 0x02, 0x70, 0x77])
    }

    func testIsSocks5AuthSuccess() {
        XCTAssertTrue(ProxyHandshake.isSocks5AuthSuccess(Data([0x01, 0x00])))
        XCTAssertFalse(ProxyHandshake.isSocks5AuthSuccess(Data([0x01, 0x01])))
        XCTAssertFalse(ProxyHandshake.isSocks5AuthSuccess(Data([0x01])))
    }

    func testSocks5ConnectRequest() {
        let data = ProxyHandshake.socks5ConnectRequest(
            targetHost: "example.com", targetPort: 443)
        // VER CMD RSV ATYP LEN("example.com" == 11)
        XCTAssertEqual(Array(data.prefix(5)), [0x05, 0x01, 0x00, 0x03, 11])
        XCTAssertEqual(
            String(data: data.dropFirst(5).dropLast(2), encoding: .utf8),
            "example.com")
        // 443 == 0x01BB, network byte order
        XCTAssertEqual(Array(data.suffix(2)), [0x01, 0xBB])
        XCTAssertEqual(data.count, 5 + 11 + 2)
    }

    func testSocks5ReplyLength() {
        let v4 = ProxyHandshake.socks5ReplyLength(
            first4: Data([0x05, 0x00, 0x00, 0x01]), remainder: Data())
        XCTAssertEqual(v4, 4 + 4 + 2)
        let v6 = ProxyHandshake.socks5ReplyLength(
            first4: Data([0x05, 0x00, 0x00, 0x04]), remainder: Data())
        XCTAssertEqual(v6, 4 + 16 + 2)
        // Domain: length byte not yet read -> unknown; then known.
        let domain4 = Data([0x05, 0x00, 0x00, 0x03])
        XCTAssertNil(ProxyHandshake.socks5ReplyLength(first4: domain4, remainder: Data()))
        XCTAssertEqual(
            ProxyHandshake.socks5ReplyLength(first4: domain4, remainder: Data([3])),
            4 + 1 + 3 + 2)
        XCTAssertNil(ProxyHandshake.socks5ReplyLength(
            first4: Data([0x05, 0x00, 0x00, 0x09]), remainder: Data()))
    }

    func testIsSocks5ConnectSuccess() {
        XCTAssertTrue(ProxyHandshake.isSocks5ConnectSuccess(
            Data([0x05, 0x00, 0x00, 0x01, 1, 2, 3, 4, 0, 80])))
        XCTAssertFalse(ProxyHandshake.isSocks5ConnectSuccess(
            Data([0x05, 0x05, 0x00, 0x01, 1, 2, 3, 4, 0, 80])))
        XCTAssertFalse(ProxyHandshake.isSocks5ConnectSuccess(Data([0x05, 0x00])))
    }

    // MARK: - ProxyConfig

    func testIsEnabled() {
        XCTAssertFalse(ProxyConfig().isEnabled)
        XCTAssertFalse(ProxyConfig(mode: .http, host: "").isEnabled)
        XCTAssertFalse(ProxyConfig(mode: .http, host: "   ").isEnabled)
        XCTAssertTrue(ProxyConfig(mode: .http, host: "proxy.local").isEnabled)
        XCTAssertTrue(ProxyConfig(mode: .socks5, host: "proxy.local", port: 1080).isEnabled)
    }

    func testInitFromSettings() {
        var settings = AppSettings.default
        settings.proxyMode = .socks5
        settings.proxyHost = "proxy.local"
        settings.proxyPort = 1080
        settings.proxyUsername = "u"
        settings.proxyPassword = "p"
        let config = ProxyConfig(settings: settings)
        XCTAssertEqual(config.mode, .socks5)
        XCTAssertEqual(config.host, "proxy.local")
        XCTAssertEqual(config.port, 1080)
        XCTAssertEqual(config.username, "u")
        XCTAssertEqual(config.password, "p")
        XCTAssertTrue(config.isEnabled)
    }

    func testHostTrimmedAndPortClamped() {
        XCTAssertEqual(ProxyConfig(mode: .http, host: "  p  ").host, "p")
        XCTAssertEqual(ProxyConfig(mode: .http, host: "p", port: 99_999).port, 65535)
        XCTAssertEqual(ProxyConfig(mode: .http, host: "p", port: 0).port, 1)
        XCTAssertEqual(ProxyConfig(mode: .http, host: "p", port: -5).port, 1)
    }

    func testProxyAuthorizationValue() {
        XCTAssertNil(ProxyConfig(mode: .http, host: "p").proxyAuthorizationValue())
        XCTAssertEqual(
            ProxyConfig(mode: .http, host: "p", username: "user", password: "pass")
                .proxyAuthorizationValue(),
            "Basic dXNlcjpwYXNz")
    }

    func testAria2Arguments() {
        XCTAssertEqual(ProxyConfig().aria2Arguments(), [])
        XCTAssertEqual(
            ProxyConfig(mode: .http, host: "proxy.local", port: 8080).aria2Arguments(),
            ["--http-proxy=http://proxy.local:8080",
             "--https-proxy=http://proxy.local:8080"])
        XCTAssertEqual(
            ProxyConfig(mode: .socks5, host: "proxy.local", port: 1080).aria2Arguments(),
            ["--all-proxy=socks5://proxy.local:1080"])
    }

    func testAria2ArgumentsEncodeCredentials() {
        // "@" in the password must not break the proxy URL.
        XCTAssertEqual(
            ProxyConfig(
                mode: .socks5, host: "proxy.local", port: 1080,
                username: "u", password: "p@ss").aria2Arguments(),
            ["--all-proxy=socks5://u:p%40ss@proxy.local:1080"])
    }

    func testAria2GlobalOptions() {
        // Disabled: empty strings clear any previously-set proxy.
        XCTAssertEqual(
            ProxyConfig().aria2GlobalOptions(),
            ["http-proxy": "", "https-proxy": "", "all-proxy": ""])
        XCTAssertEqual(
            ProxyConfig(mode: .http, host: "proxy.local", port: 8080).aria2GlobalOptions(),
            ["http-proxy": "http://proxy.local:8080",
             "https-proxy": "http://proxy.local:8080",
             "all-proxy": ""])
        XCTAssertEqual(
            ProxyConfig(mode: .socks5, host: "proxy.local", port: 1080).aria2GlobalOptions(),
            ["http-proxy": "", "https-proxy": "",
             "all-proxy": "socks5://proxy.local:1080"])
    }

    func testUrlSessionProxyDictionary() {
        XCTAssertNil(ProxyConfig().urlSessionProxyDictionary())
        let http = ProxyConfig(mode: .http, host: "proxy.local", port: 8080)
            .urlSessionProxyDictionary()
        XCTAssertEqual(http?[kCFNetworkProxiesHTTPProxy as String] as? String, "proxy.local")
        XCTAssertEqual(http?[kCFNetworkProxiesHTTPPort as String] as? Int, 8080)
        XCTAssertEqual(http?[kCFNetworkProxiesHTTPSProxy as String] as? String, "proxy.local")
        let socks = ProxyConfig(mode: .socks5, host: "proxy.local", port: 1080)
            .urlSessionProxyDictionary()
        XCTAssertEqual(socks?[kCFNetworkProxiesSOCKSHost as String] as? String, "proxy.local")
        XCTAssertEqual(socks?[kCFNetworkProxiesSOCKSPort as String] as? Int, 1080)
    }
}
