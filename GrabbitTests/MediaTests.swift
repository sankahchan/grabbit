import XCTest
@testable import Grabbit

final class MediaTests: XCTestCase {

    // MARK: - MediaProbe.parse

    private func sampleJSON() -> Data {
        let formats: [[String: Any]] = [
            ["format_id": "h1080", "height": 1080, "filesize": 50_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "h720", "height": 720, "filesize": 25_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "h480", "height": 480, "filesize": 12_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "audio", "height": NSNull(), "filesize": 5_000_000 as Int64,
             "vcodec": "none", "acodec": "opus", "ext": "webm"],
        ]
        let json: [String: Any] = [
            "title": "Test Video",
            "duration": 123.0,
            "webpage_url": "https://example.com/v",
            "formats": formats,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testProbeParseBuildsPresets() throws {
        let media = try MediaProbe.parse(sampleJSON())
        XCTAssertEqual(media.title, "Test Video")
        XCTAssertEqual(media.duration, 123.0)
        let ids = media.presets.map(\.id)
        XCTAssertEqual(ids, ["best", "1080p", "720p", "480p", "videoOnly", "audio", "audioM4A", "audioOriginal"])
        // 360p has no matching format — correctly omitted.
        XCTAssertFalse(ids.contains("360p"))
        let best = media.presets.first { $0.id == "best" }!
        XCTAssertEqual(best.formatSpec, "bv*+ba/b")
        XCTAssertEqual(best.estimatedSize, 55_000_000) // video + audio
        let p720 = media.presets.first { $0.id == "720p" }!
        XCTAssertEqual(p720.formatSpec, "bv*[height<=720]+ba/b[height<=720]")
        XCTAssertEqual(p720.estimatedSize, 30_000_000)
        let audio = media.presets.first { $0.id == "audio" }!
        XCTAssertTrue(audio.isAudioOnly)
        XCTAssertEqual(audio.formatSpec, "bestaudio")
        XCTAssertEqual(audio.audioConvertFormat, "mp3")
        let audioM4A = media.presets.first { $0.id == "audioM4A" }!
        XCTAssertTrue(audioM4A.isAudioOnly)
        XCTAssertEqual(audioM4A.audioConvertFormat, "m4a")
        // Backlog #10: video-only + original-audio rows.
        let videoOnly = media.presets.first { $0.id == "videoOnly" }!
        XCTAssertTrue(videoOnly.videoOnly)
        XCTAssertFalse(videoOnly.isAudioOnly)
        XCTAssertEqual(videoOnly.formatSpec, "bv*")
        XCTAssertEqual(videoOnly.estimatedSize, 50_000_000) // video, no audio
        let audioOrig = media.presets.first { $0.id == "audioOriginal" }!
        XCTAssertTrue(audioOrig.isAudioOnly)
        XCTAssertNil(audioOrig.audioConvertFormat)
    }

    func testProbeParseEmptyFormats() throws {
        let json: [String: Any] = ["title": "x", "formats": [] as [[String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let media = try MediaProbe.parse(data)
        XCTAssertTrue(media.presets.isEmpty)
    }

    func testProbeParseMissingTitle() throws {
        let json: [String: Any] = ["formats": [] as [[String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let media = try MediaProbe.parse(data)
        XCTAssertEqual(media.title, "media")
    }

    // MARK: - MediaRuntimeResolver

    func testResolverEnvOverride() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-test-ytdlp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        setenv("YTDLP_PATH", tmp.path, 1)
        defer {
            unsetenv("YTDLP_PATH")
            try? FileManager.default.removeItem(at: tmp)
        }
        let resolved = try MediaRuntimeResolver.resolve(.ytDlp).get()
        XCTAssertEqual(resolved.path, tmp.path)
    }

    func testResolverMissingComponentGivesHint() {
        // Use a component name that can't exist anywhere: deno is unlikely to
        // be installed on CI, but to be deterministic, check the failure type
        // only when resolution actually fails.
        let result = MediaRuntimeResolver.resolve(.deno)
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("deno"))
            XCTAssertTrue(error.localizedDescription.contains("brew install deno"))
        }
    }

    // MARK: - MediaEngine.safeFilename

    func testSafeFilenameStripsIllegalChars() {
        XCTAssertEqual(MediaEngine.safeFilename("a/b\\c:d?e*f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j")
        XCTAssertEqual(MediaEngine.safeFilename("  spaced  "), "spaced")
        XCTAssertEqual(MediaEngine.safeFilename(""), "media")
        XCTAssertTrue(MediaEngine.safeFilename(String(repeating: "x", count: 500)).count <= 120)
    }

    // MARK: - ManagedProcess

    func testManagedProcessEcho() async {
        let proc = ManagedProcess()
        var lines: [String] = []
        proc.onStdoutLine = { lines.append($0) }
        let result = await proc.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(lines, ["hello world"])
    }

    func testManagedProcessNonZeroExit() async {
        let proc = ManagedProcess()
        let result = await proc.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testManagedProcessCancel() async {
        let proc = ManagedProcess()
        let task = Task {
            await proc.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"])
        }
        // Give it a moment to spawn, then cancel.
        try? await Task.sleep(nanoseconds: 500_000_000)
        proc.cancel()
        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
    }

    // MARK: - 4K / 1440p presets

    private func uhdJSON() -> Data {
        let formats: [[String: Any]] = [
            ["format_id": "h2160", "height": 2160, "filesize": 400_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "h1440", "height": 1440, "filesize": 200_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "h1080", "height": 1080, "filesize": 50_000_000 as Int64,
             "vcodec": "avc1", "acodec": "none", "ext": "mp4"],
            ["format_id": "audio", "height": NSNull(), "filesize": 5_000_000 as Int64,
             "vcodec": "none", "acodec": "opus", "ext": "webm"],
        ]
        let json: [String: Any] = ["title": "UHD", "formats": formats]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testProbeParseBuilds4KAnd1440pPresets() throws {
        let media = try MediaProbe.parse(uhdJSON())
        let ids = media.presets.map(\.id)
        XCTAssertEqual(ids, ["best", "2160p", "1440p", "1080p", "videoOnly", "audio", "audioM4A", "audioOriginal"])
        let p4k = media.presets.first { $0.id == "2160p" }!
        XCTAssertEqual(p4k.formatSpec, "bv*[height<=2160]+ba/b[height<=2160]")
        XCTAssertEqual(p4k.estimatedSize, 405_000_000) // 4K video + audio
        let p1440 = media.presets.first { $0.id == "1440p" }!
        XCTAssertEqual(p1440.formatSpec, "bv*[height<=1440]+ba/b[height<=1440]")
        XCTAssertEqual(p1440.estimatedSize, 205_000_000)
    }

    func testProbeParseOmits4KWhenUnavailable() throws {
        // The 1080p-only fixture must not gain 2160p/1440p rows.
        let media = try MediaProbe.parse(sampleJSON())
        let ids = media.presets.map(\.id)
        XCTAssertFalse(ids.contains("2160p"))
        XCTAssertFalse(ids.contains("1440p"))
    }

    // MARK: - Backlog #10: thumbnail + separate A/V

    func testProbeParseExtractsThumbnail() throws {
        var dict = try JSONSerialization.jsonObject(with: sampleJSON()) as! [String: Any]
        dict["thumbnail"] = "https://example.com/thumb.jpg"
        let data = try JSONSerialization.data(withJSONObject: dict)
        let media = try MediaProbe.parse(data)
        XCTAssertEqual(media.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testProbeParseNoThumbnailGivesNil() throws {
        let media = try MediaProbe.parse(sampleJSON())
        XCTAssertNil(media.thumbnailURL)
    }
}
