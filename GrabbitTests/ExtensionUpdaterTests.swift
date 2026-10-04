import XCTest
import Foundation
@testable import Grabbit

/// ExtensionUpdater: browser-preferences parsing, directory mirroring and
/// ZIP installation (the download itself is not exercised offline).
final class ExtensionUpdaterTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-extupd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Preferences parsing

    func testUnpackedPathsOnlyForOurUnpackedIDs() {
        let preferences: [String: Any] = [
            "extensions": [
                "settings": [
                    "hdgandihmchcpeejohadokljdeicdhig": ["location": 4, "path": "/tmp/ext"],
                    "ccimhjbjoidahibcijllkgoljnonhg": ["location": 1, "path": "/store"],
                    "someone.else": ["location": 4, "path": "/tmp/other"],
                    "no.path": ["location": 4],
                ] as [String: Any],
            ],
        ]
        XCTAssertEqual(
            ExtensionUpdater.unpackedPaths(inPreferences: preferences), ["/tmp/ext"])
    }

    func testUnpackedPathsMissingStructureIsEmpty() {
        XCTAssertEqual(ExtensionUpdater.unpackedPaths(inPreferences: [:]), [])
        XCTAssertEqual(
            ExtensionUpdater.unpackedPaths(inPreferences: ["extensions": [:]]), [])
    }

    // MARK: - Mirror

    func testMirrorCopiesAndRemovesStaleFiles() throws {
        let source = try tempDir().appendingPathComponent("source")
        let destination = try tempDir().appendingPathComponent("destination")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(
            to: source.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try "icon".write(
            to: source.appendingPathComponent("icons/icon16.png"),
            atomically: true, encoding: .utf8)
        try "old".write(
            to: destination.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try "stale".write(
            to: destination.appendingPathComponent("removed.js"),
            atomically: true, encoding: .utf8)

        let copied = try ExtensionUpdater.mirror(from: source, to: destination)
        XCTAssertEqual(copied, 2)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("manifest.json"),
                encoding: .utf8),
            "new")
        XCTAssertTrue(fileManager.fileExists(
            atPath: destination.appendingPathComponent("icons/icon16.png").path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: destination.appendingPathComponent("removed.js").path))
    }

    // MARK: - Install from ZIP

    func testInstallFromZipMirrorsContents() throws {
        let root = try tempDir()
        let staging = root.appendingPathComponent("staging")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try "{}".write(
            to: staging.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try "code".write(
            to: staging.appendingPathComponent("background.js"),
            atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("ext.zip")
        try runDitto(["-c", "-k", "--sequesterRsrc", staging.path, zip.path])

        let folder = root.appendingPathComponent("loaded")
        let copied = try ExtensionUpdater.install(zip: zip, into: folder)
        XCTAssertEqual(copied, 2)
        XCTAssertTrue(fileManager.fileExists(
            atPath: folder.appendingPathComponent("background.js").path))
    }

    func testInstallRejectsPackageWithoutManifest() throws {
        let root = try tempDir()
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "not an extension".write(
            to: staging.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("bad.zip")
        try runDitto(["-c", "-k", "--sequesterRsrc", staging.path, zip.path])
        XCTAssertThrowsError(try ExtensionUpdater.install(
            zip: zip, into: root.appendingPathComponent("loaded")))
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
