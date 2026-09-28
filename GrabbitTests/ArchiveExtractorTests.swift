import Foundation
import XCTest
@testable import Grabbit

/// ArchiveExtractor: type detection, destination naming, and real
/// zip/tar.gz round-trips with the system tools CI provides.
final class ArchiveExtractorTests: XCTestCase {
    func testIsExtractableArchive() {
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "app.zip"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "APP.ZIP"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tar"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tar.gz"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tgz"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tar.bz2"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tbz2"))
        XCTAssertTrue(ArchiveExtractor.isExtractableArchive(filename: "src.tar.xz"))
        XCTAssertFalse(ArchiveExtractor.isExtractableArchive(filename: "app.rar"))
        XCTAssertFalse(ArchiveExtractor.isExtractableArchive(filename: "app.7z"))
        XCTAssertFalse(ArchiveExtractor.isExtractableArchive(filename: "movie.mp4"))
        XCTAssertFalse(ArchiveExtractor.isExtractableArchive(filename: "noextension"))
        XCTAssertFalse(ArchiveExtractor.isExtractableArchive(filename: "zip"))
    }

    func testExtractionDestination() {
        XCTAssertEqual(
            ArchiveExtractor.extractionDestination(
                for: URL(fileURLWithPath: "/dl/app.zip")).path,
            "/dl/app")
        XCTAssertEqual(
            ArchiveExtractor.extractionDestination(
                for: URL(fileURLWithPath: "/dl/src.tar.gz")).path,
            "/dl/src")
        XCTAssertEqual(
            ArchiveExtractor.extractionDestination(
                for: URL(fileURLWithPath: "/dl/src.tgz")).path,
            "/dl/src")
    }

    func testZipRoundTrip() throws {
        let tmp = try makeTempDir()
        let srcDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "hello".write(
            to: srcDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        let zipURL = tmp.appendingPathComponent("bundle.zip")
        try run("/usr/bin/ditto", [
            "-c", "-k", "--sequesterRsrc", srcDir.path, zipURL.path,
        ])

        let dest = try ArchiveExtractor.extract(archiveURL: zipURL)
        XCTAssertEqual(dest.path, tmp.appendingPathComponent("bundle").path)
        let content = try String(
            contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "hello")
    }

    func testTarGzRoundTrip() throws {
        let tmp = try makeTempDir()
        let srcFile = tmp.appendingPathComponent("a.txt")
        try "world".write(to: srcFile, atomically: true, encoding: .utf8)
        let tgzURL = tmp.appendingPathComponent("bundle.tar.gz")
        try run("/usr/bin/tar", ["-czf", tgzURL.path, "-C", tmp.path, "a.txt"])

        let dest = try ArchiveExtractor.extract(archiveURL: tgzURL)
        let content = try String(
            contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "world")
    }

    func testExtractMissingArchiveThrows() {
        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveURL: URL(
            fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.zip")))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, launchPath)
    }
}
