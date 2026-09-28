import XCTest
@testable import Grabbit

final class CategoryTests: XCTestCase {

    // MARK: - DownloadCategory.infer

    func testInferVideoByExtension() {
        XCTAssertEqual(DownloadCategory.infer(filename: "movie.mp4"), .video)
        XCTAssertEqual(DownloadCategory.infer(filename: "clip.MKV"), .video)
        XCTAssertEqual(DownloadCategory.infer(filename: "show.webm"), .video)
    }

    func testInferAudioByExtension() {
        XCTAssertEqual(DownloadCategory.infer(filename: "song.mp3"), .audio)
        XCTAssertEqual(DownloadCategory.infer(filename: "track.FLAC"), .audio)
        XCTAssertEqual(DownloadCategory.infer(filename: "podcast.m4a"), .audio)
    }

    func testInferDocumentByExtension() {
        XCTAssertEqual(DownloadCategory.infer(filename: "report.pdf"), .document)
        XCTAssertEqual(DownloadCategory.infer(filename: "slides.pptx"), .document)
        XCTAssertEqual(DownloadCategory.infer(filename: "notes.txt"), .document)
    }

    func testInferOtherForUnknown() {
        XCTAssertEqual(DownloadCategory.infer(filename: "archive.zip"), .other)
        XCTAssertEqual(DownloadCategory.infer(filename: "setup.dmg"), .other)
        XCTAssertEqual(DownloadCategory.infer(filename: "noextension"), .other)
    }

    func testInferByContentType() {
        XCTAssertEqual(
            DownloadCategory.infer(filename: "file.bin", contentType: "video/mp4"), .video)
        XCTAssertEqual(
            DownloadCategory.infer(filename: "file.bin", contentType: "audio/mpeg"), .audio)
        XCTAssertEqual(
            DownloadCategory.infer(filename: "file.bin", contentType: "application/pdf"),
            .document)
        // Parameters are stripped by the probe, but infer tolerates them too.
        XCTAssertEqual(
            DownloadCategory.infer(filename: "file", contentType: "text/html; charset=utf-8"),
            .document)
    }

    func testInferExtensionWinsOverContentType() {
        XCTAssertEqual(
            DownloadCategory.infer(filename: "movie.mp4", contentType: "application/octet-stream"),
            .video)
    }

    // MARK: - sanitizeFilename

    func testSanitizeStripsSeparators() {
        XCTAssertEqual(DownloadEngine.sanitizeFilename("a/b\\c:d.mp4"), "a_b_c_d.mp4")
    }

    func testSanitizeStripsControlCharacters() {
        XCTAssertEqual(DownloadEngine.sanitizeFilename("a\u{0}b\u{7}c.txt"), "abc.txt")
    }

    func testSanitizeStripsLeadingDots() {
        XCTAssertEqual(DownloadEngine.sanitizeFilename("...secret.txt"), "secret.txt")
        XCTAssertEqual(DownloadEngine.sanitizeFilename(".."), "download")
    }

    func testSanitizeTrimsAndFallsBack() {
        XCTAssertEqual(DownloadEngine.sanitizeFilename("   "), "download")
        XCTAssertEqual(DownloadEngine.sanitizeFilename(""), "download")
        XCTAssertEqual(DownloadEngine.sanitizeFilename("  name.mp4  "), "name.mp4")
    }

    func testSanitizeCapsLengthPreservingExtension() {
        let long = String(repeating: "a", count: 300) + ".mp4"
        let out = DownloadEngine.sanitizeFilename(long)
        XCTAssertTrue(out.count <= 200)
        XCTAssertTrue(out.hasSuffix(".mp4"))
    }

    // MARK: - uniqueFilename

    func testUniqueFilenameNoCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(DownloadEngine.uniqueFilename("a.txt", in: dir), "a.txt")
    }

    func testUniqueFilenameCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "a (2).txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        XCTAssertEqual(DownloadEngine.uniqueFilename("a.txt", in: dir), "a (3).txt")
    }

    func testUniqueFilenameNoExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("README").path, contents: nil)
        XCTAssertEqual(DownloadEngine.uniqueFilename("README", in: dir), "README (2)")
    }
}
