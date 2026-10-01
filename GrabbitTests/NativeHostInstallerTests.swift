import XCTest
import Foundation
@testable import Grabbit

/// NativeHostInstaller: the app ships the native helper and rewrites the
/// browser host manifests on launch, so app updates refresh the helper.
final class NativeHostInstallerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-nhi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testManifestShape() throws {
        let data = try XCTUnwrap(NativeHostInstaller.manifestData(
            extensionIDs: ["abc", "def"], helperPath: "/tmp/helper.py"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "com.sankahchan.grabbit")
        XCTAssertEqual(object["type"] as? String, "stdio")
        XCTAssertEqual(object["path"] as? String, "/tmp/helper.py")
        XCTAssertEqual(
            object["allowed_origins"] as? [String],
            ["chrome-extension://abc/", "chrome-extension://def/"])
    }

    func testInstallHelperCopiesAndIsIdempotent() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundled = tmp.appendingPathComponent("bundled/grabbit-native-helper.py")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "print('helper')\n".write(to: bundled, atomically: true, encoding: .utf8)
        let installed = tmp.appendingPathComponent("appsupport/grabbit-native-helper.py")

        XCTAssertTrue(NativeHostInstaller.installHelper(
            bundled: bundled, installed: installed))
        XCTAssertEqual(
            try String(contentsOf: installed, encoding: .utf8), "print('helper')\n")
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o755)

        // Same bytes: no rewrite.
        XCTAssertFalse(NativeHostInstaller.installHelper(
            bundled: bundled, installed: installed))

        // Changed bytes: rewrite.
        try "print('v2')\n".write(to: bundled, atomically: true, encoding: .utf8)
        XCTAssertTrue(NativeHostInstaller.installHelper(
            bundled: bundled, installed: installed))
        XCTAssertEqual(
            try String(contentsOf: installed, encoding: .utf8), "print('v2')\n")
    }

    func testInstallHelperMissingBundleIsNoOp() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let installed = tmp.appendingPathComponent("helper.py")
        XCTAssertFalse(NativeHostInstaller.installHelper(
            bundled: nil, installed: installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    func testInstallManifestsWritesOnlyWhenDifferent() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dirs = [
            tmp.appendingPathComponent("A"),
            tmp.appendingPathComponent("B"),
        ]
        let data = try XCTUnwrap(NativeHostInstaller.manifestData(
            extensionIDs: ["abc"], helperPath: "/tmp/helper.py"))

        XCTAssertEqual(NativeHostInstaller.installManifests(into: dirs, data: data), 2)
        for dir in dirs {
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                dir.appendingPathComponent("com.sankahchan.grabbit.json").path))
        }
        // Idempotent.
        XCTAssertEqual(NativeHostInstaller.installManifests(into: dirs, data: data), 0)

        // Changed content rewrites both.
        let updated = try XCTUnwrap(NativeHostInstaller.manifestData(
            extensionIDs: ["abc", "def"], helperPath: "/tmp/helper.py"))
        XCTAssertEqual(NativeHostInstaller.installManifests(into: dirs, data: updated), 2)
    }
}
