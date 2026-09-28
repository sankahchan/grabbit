import XCTest
@testable import Grabbit

/// Per-task proxy override (Motrix parity): resolution against the global
/// setting, aria2 option mapping, and Codable round-trips on both task
/// models, including backward-compatible decode of old resume JSON.
final class TaskProxyTests: XCTestCase {

    private func settingsWithProxy() -> AppSettings {
        var s = AppSettings()
        s.proxyMode = .http
        s.proxyHost = "global.example"
        s.proxyPort = 3128
        return s
    }

    func testResolveNilFollowsGlobal() {
        let resolved = TaskProxy.resolve(
            override: nil, settings: settingsWithProxy())
        XCTAssertEqual(resolved.mode, .http)
        XCTAssertEqual(resolved.host, "global.example")
        XCTAssertEqual(resolved.port, 3128)
    }

    func testResolveGlobalScopeFollowsGlobal() {
        let resolved = TaskProxy.resolve(
            override: TaskProxy(scope: .global), settings: settingsWithProxy())
        XCTAssertEqual(resolved.mode, .http)
        XCTAssertEqual(resolved.host, "global.example")
    }

    func testResolveNoneForcesDirect() {
        let resolved = TaskProxy.resolve(
            override: TaskProxy(scope: .none), settings: settingsWithProxy())
        XCTAssertEqual(resolved.mode, .none)
    }

    func testResolveCustomWinsOverGlobal() {
        let custom = TaskProxy(
            scope: .custom, mode: .socks5, host: "task.example", port: 1080,
            username: "u", password: "p")
        let resolved = TaskProxy.resolve(
            override: custom, settings: settingsWithProxy())
        XCTAssertEqual(resolved.mode, .socks5)
        XCTAssertEqual(resolved.host, "task.example")
        XCTAssertEqual(resolved.port, 1080)
        XCTAssertEqual(resolved.username, "u")
    }

    func testAria2OptionsGlobalIsNil() {
        XCTAssertNil(TaskProxy(scope: .global).aria2Options())
    }

    func testAria2OptionsNoneClearsProxy() {
        let opts = TaskProxy(scope: .none).aria2Options()
        XCTAssertEqual(opts?["http-proxy"], "")
        XCTAssertEqual(opts?["https-proxy"], "")
        XCTAssertEqual(opts?["all-proxy"], "")
    }

    func testAria2OptionsCustomMirrorsConfig() {
        let custom = TaskProxy(
            scope: .custom, mode: .http, host: "task.example", port: 8080)
        let opts = custom.aria2Options()
        let expected = ProxyConfig(
            mode: .http, host: "task.example", port: 8080).aria2GlobalOptions()
        XCTAssertEqual(opts, expected)
    }

    func testPortClamped() {
        XCTAssertEqual(TaskProxy(scope: .custom, port: 0).port, 1)
        XCTAssertEqual(TaskProxy(scope: .custom, port: 99999).port, 65535)
    }

    func testDownloadItemProxyRoundTrip() throws {
        let proxy = TaskProxy(
            scope: .custom, mode: .socks5, host: "task.example", port: 1080)
        let item = DownloadItem(
            url: URL(string: "https://example.com/f.zip")!,
            filename: "f.zip",
            destinationURL: URL(fileURLWithPath: "/tmp"),
            proxy: proxy)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)
        XCTAssertEqual(decoded.proxy, proxy)
    }

    func testDownloadItemDecodesWithoutProxy() throws {
        // Old resume-store JSON has no "proxy" key — must decode to nil,
        // not fail the whole file.
        let item = DownloadItem(
            url: URL(string: "https://example.com/f.zip")!,
            filename: "f.zip",
            destinationURL: URL(fileURLWithPath: "/tmp"))
        let data = try JSONEncoder().encode(item)
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        raw.removeValue(forKey: "proxy")
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: legacy)
        XCTAssertNil(decoded.proxy)
    }

    func testTorrentItemProxyRoundTrip() throws {
        let proxy = TaskProxy(scope: .none)
        let item = TorrentItem(
            name: "t",
            magnetURI: "magnet:?xt=urn:btih:abc",
            savePath: URL(fileURLWithPath: "/tmp"),
            proxy: proxy)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TorrentItem.self, from: data)
        XCTAssertEqual(decoded.proxy, proxy)
    }

    func testTorrentItemDecodesWithoutProxy() throws {
        let item = TorrentItem(
            name: "t",
            magnetURI: "magnet:?xt=urn:btih:abc",
            savePath: URL(fileURLWithPath: "/tmp"))
        let data = try JSONEncoder().encode(item)
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        raw.removeValue(forKey: "proxy")
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(TorrentItem.self, from: legacy)
        XCTAssertNil(decoded.proxy)
    }
}
