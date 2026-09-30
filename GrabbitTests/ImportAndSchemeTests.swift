import XCTest
@testable import Grabbit

final class ImportAndSchemeTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    private func writePayload(_ json: [String: Any], named name: String = "payload.json") throws -> String {
        let url = inbox.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url.path
    }

    private func schemeURL(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "grabbit"
        components.host = host
        components.queryItems = [URLQueryItem(name: "payload", value: path)]
        return components.url!
    }

    // MARK: - grabbit://download payload

    func testDownloadPayloadParsesURLFilenameAndHeaders() throws {
        let payloadPath = try writePayload([
            "url": "https://cdn.example.com/video.m3u8",
            "filename": "video.m3u8",
            "title": "Example",
            "pageUrl": "https://example.com/watch",
            "headers": [
                "Referer": "https://example.com/watch",
                "Cookie": "session=abc",
                "User-Agent": "TestAgent/1.0",
            ],
        ])
        let request = GrabbitURLScheme.parse(schemeURL(host: "download", path: payloadPath), inbox: inbox)
        XCTAssertEqual(request?.url.absoluteString, "https://cdn.example.com/video.m3u8")
        XCTAssertEqual(request?.filename, "video.m3u8")
        XCTAssertEqual(request?.title, "Example")
        XCTAssertEqual(request?.headers["Referer"], "https://example.com/watch")
        XCTAssertEqual(request?.headers["Cookie"], "session=abc")
        XCTAssertEqual(request?.headers["User-Agent"], "TestAgent/1.0")
    }

    func testDownloadPayloadOutsideInboxIsRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-outside-\(UUID().uuidString).json")
        try Data("{\"url\":\"https://example.com/a.mp4\"}".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(GrabbitURLScheme.parse(schemeURL(host: "download", path: outside.path), inbox: inbox))
    }

    func testDownloadPayloadRejectsNonHTTPTarget() throws {
        let payloadPath = try writePayload(["url": "file:///etc/passwd"])
        XCTAssertNil(GrabbitURLScheme.parse(schemeURL(host: "download", path: payloadPath), inbox: inbox))
    }

    func testLegacyQueryParamsStillParse() {
        var components = URLComponents()
        components.scheme = "grabbit"
        components.host = "download"
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://example.com/a.zip"),
            URLQueryItem(name: "filename", value: "a.zip"),
            URLQueryItem(name: "referer", value: "https://example.com/page"),
            URLQueryItem(name: "cookie", value: "a=b"),
        ]
        let request = GrabbitURLScheme.parse(components.url!, inbox: inbox)
        XCTAssertEqual(request?.url.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(request?.filename, "a.zip")
        XCTAssertEqual(request?.headers["Referer"], "https://example.com/page")
        XCTAssertEqual(request?.headers["Cookie"], "a=b")
    }

    // MARK: - grabbit://import payload

    func testImportPayloadParsesPrimaryAndAuxiliaryTracks() throws {
        let video = inbox.appendingPathComponent("capture.mp4")
        let audio = inbox.appendingPathComponent("capture.audio.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: video)
        try Data([0x03, 0x04]).write(to: audio)
        let payloadPath = try writePayload([
            "path": video.path,
            "auxPath": audio.path,
            "filename": "Lioness S03E08.mp4",
            "pageUrl": "https://web.telegram.org/k/",
            "source": "extension-stream",
            "mime": "video/mp4",
        ])
        let request = GrabbitURLScheme.parseImport(schemeURL(host: "import", path: payloadPath), inbox: inbox)
        XCTAssertEqual(request?.fileURL.path, video.path)
        XCTAssertEqual(request?.auxiliaryAudioURL?.path, audio.path)
        XCTAssertEqual(request?.filename, "Lioness S03E08.mp4")
        XCTAssertEqual(request?.pageURL?.host, "web.telegram.org")
        XCTAssertEqual(request?.mimeType, "video/mp4")
    }

    func testImportPayloadPathOutsideInboxIsRejected() throws {
        let payloadPath = try writePayload(["path": "/etc/hosts"])
        XCTAssertNil(GrabbitURLScheme.parseImport(schemeURL(host: "import", path: payloadPath), inbox: inbox))
    }

    func testImportPayloadIgnoresAuxOutsideInbox() throws {
        let video = inbox.appendingPathComponent("capture.mp4")
        try Data([0x00]).write(to: video)
        let payloadPath = try writePayload([
            "path": video.path,
            "auxPath": "/etc/hosts",
        ])
        let request = GrabbitURLScheme.parseImport(schemeURL(host: "import", path: payloadPath), inbox: inbox)
        XCTAssertEqual(request?.fileURL.path, video.path)
        XCTAssertNil(request?.auxiliaryAudioURL)
    }

    func testInboxPathValidationPrefixesAreNotBypassed() {
        let base = inbox.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sibling = inbox.appendingPathComponent("Inbox-evil/file.mp4")
        XCTAssertTrue(GrabbitURLScheme.isInInboxPath(base.appendingPathComponent("file.mp4").path, inbox: base))
        XCTAssertFalse(GrabbitURLScheme.isInInboxPath(sibling.path, inbox: base))
    }

    // MARK: - yt-dlp header args

    func testHeaderArgumentsMapsRefererAndAddsRemainingSortedly() {
        let args = MediaProbe.headerArguments([
            "User-Agent": "Agent/1.0",
            "Referer": "https://example.com/page",
            "Cookie": "a=b",
        ])
        XCTAssertEqual(args, [
            "--referer", "https://example.com/page",
            "--add-header", "Cookie: a=b",
            "--add-header", "User-Agent: Agent/1.0",
        ])
    }

    func testHeaderArgumentsEmptyWhenNoHeaders() {
        XCTAssertTrue(MediaProbe.headerArguments([:]).isEmpty)
    }

    // MARK: - ffmpeg mux args

    func testMuxerArgumentsStreamCopyWithFaststart() {
        let args = MediaMuxer.arguments(
            video: URL(fileURLWithPath: "/tmp/in/video.mp4"),
            audio: URL(fileURLWithPath: "/tmp/in/audio.m4a"),
            output: URL(fileURLWithPath: "/tmp/out/merged.mp4"))
        XCTAssertEqual(args, [
            "-y",
            "-i", "/tmp/in/video.mp4",
            "-i", "/tmp/in/audio.m4a",
            "-c", "copy",
            "-movflags", "+faststart",
            "/tmp/out/merged.mp4",
        ])
    }
}
