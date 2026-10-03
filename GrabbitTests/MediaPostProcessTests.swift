import XCTest
import Foundation
@testable import Grabbit

/// The yt-dlp post-processing flags derived from Settings: embedded
/// metadata/thumbnail/chapters/subtitles and the optional cookies.txt.
final class MediaPostProcessTests: XCTestCase {
    func testDefaultsEmbedEverythingForVideo() {
        let args = MediaEngine.postProcessArguments(
            settings: AppSettings(), isAudioOnly: false)
        XCTAssertTrue(args.contains("--embed-metadata"))
        XCTAssertTrue(args.contains("--embed-thumbnail"))
        XCTAssertTrue(args.contains("--embed-chapters"))
        XCTAssertTrue(args.contains("--embed-subs"))
        let subLangsIndex = try? XCTUnwrap(args.firstIndex(of: "--sub-langs"))
        XCTAssertEqual(args[(subLangsIndex ?? 0) + 1], "en.*,my.*")
        XCTAssertFalse(args.contains("--cookies"))
    }

    func testAudioOnlySkipsChaptersAndSubtitles() {
        let args = MediaEngine.postProcessArguments(
            settings: AppSettings(), isAudioOnly: true)
        XCTAssertTrue(args.contains("--embed-metadata"))
        XCTAssertTrue(args.contains("--embed-thumbnail"))
        XCTAssertFalse(args.contains("--embed-chapters"))
        XCTAssertFalse(args.contains("--embed-subs"))
    }

    func testAllTogglesOffProduceNoFlags() {
        var settings = AppSettings()
        settings.mediaEmbedMetadata = false
        settings.mediaEmbedThumbnail = false
        settings.mediaEmbedChapters = false
        settings.mediaEmbedSubtitles = false
        settings.cookiesFilePath = ""
        XCTAssertEqual(
            MediaEngine.postProcessArguments(settings: settings, isAudioOnly: false),
            [])
    }

    func testEmptySubtitleLanguagesOmitSubLangs() {
        var settings = AppSettings()
        settings.mediaSubtitleLanguages = "   "
        let args = MediaEngine.postProcessArguments(
            settings: settings, isAudioOnly: false)
        XCTAssertTrue(args.contains("--embed-subs"))
        XCTAssertFalse(args.contains("--sub-langs"))
    }

    func testCookiesFlagOnlyWhenFileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-cookies-\(UUID().uuidString).txt")
        try "# Netscape HTTP Cookie File\n".write(
            to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var settings = AppSettings()
        settings.cookiesFilePath = tmp.path
        var args = MediaEngine.postProcessArguments(
            settings: settings, isAudioOnly: false)
        let cookiesIndex = try XCTUnwrap(args.firstIndex(of: "--cookies"))
        XCTAssertEqual(args[cookiesIndex + 1], tmp.path)

        // A path whose file has gone missing must not be passed through —
        // yt-dlp hard-fails on a missing cookies file.
        settings.cookiesFilePath = tmp.path + ".missing"
        args = MediaEngine.postProcessArguments(
            settings: settings, isAudioOnly: false)
        XCTAssertFalse(args.contains("--cookies"))
    }

    func testLegacySettingsDecodeWithMediaDefaults() throws {
        let json = #"{"language":"system","theme":"dark"}"#
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.theme, .dark)
        XCTAssertTrue(decoded.mediaEmbedMetadata)
        XCTAssertTrue(decoded.mediaEmbedThumbnail)
        XCTAssertTrue(decoded.mediaEmbedChapters)
        XCTAssertTrue(decoded.mediaEmbedSubtitles)
        XCTAssertEqual(decoded.mediaSubtitleLanguages, "en.*,my.*")
        XCTAssertEqual(decoded.cookiesFilePath, "")
    }
}
