import XCTest
import Foundation
@testable import Grabbit

/// Backlog #3 (per-host profiles) and #4 (packagizer rules): matching,
/// auth headers, template rendering, and store persistence.
final class ProfilesAndRulesTests: XCTestCase {
    // MARK: - HostProfile matching

    func testHostProfileMatches() {
        let profile = HostProfile(host: "example.com")
        XCTAssertTrue(profile.matches(host: "example.com"))
        XCTAssertTrue(profile.matches(host: "sub.example.com"))
        XCTAssertTrue(profile.matches(host: "a.b.example.com"))
        XCTAssertTrue(profile.matches(host: "EXAMPLE.COM"))
        XCTAssertFalse(profile.matches(host: "notexample.com"))
        XCTAssertFalse(profile.matches(host: "example.com.evil.com"))
        XCTAssertFalse(profile.matches(host: "other.org"))
        XCTAssertFalse(profile.matches(host: nil))
        XCTAssertFalse(profile.matches(host: ""))
    }

    func testHostProfileDisabledNeverMatches() {
        let profile = HostProfile(host: "example.com", isEnabled: false)
        XCTAssertFalse(profile.matches(host: "example.com"))
    }

    func testHostProfileEmptyHostNeverMatches() {
        let profile = HostProfile(host: "  ")
        XCTAssertFalse(profile.matches(host: "example.com"))
    }

    func testAuthorizationHeader() {
        XCTAssertNil(HostProfile(host: "h").authorizationHeader())
        // "user:pass" base64
        XCTAssertEqual(
            HostProfile(host: "h", username: "user", password: "pass").authorizationHeader(),
            "Basic dXNlcjpwYXNz")
    }

    // MARK: - PackagizerRule matching

    func testPackagizerMatches() {
        let rule = PackagizerRule(urlPattern: #"example\.com/.*\.zip"#)
        XCTAssertTrue(rule.matches(url: URL(string: "https://example.com/files/a.zip")!))
        XCTAssertFalse(rule.matches(url: URL(string: "https://example.com/files/a.rar")!))
        XCTAssertFalse(rule.matches(url: URL(string: "https://other.org/a.zip")!))
    }

    func testPackagizerInvalidRegexNeverMatches() {
        let rule = PackagizerRule(urlPattern: "([unclosed")
        XCTAssertFalse(rule.matches(url: URL(string: "https://example.com/a.zip")!))
    }

    func testPackagizerDisabledOrEmptyNeverMatches() {
        XCTAssertFalse(PackagizerRule(isEnabled: false, urlPattern: ".*")
            .matches(url: URL(string: "https://example.com/a.zip")!))
        XCTAssertFalse(PackagizerRule(urlPattern: "  ")
            .matches(url: URL(string: "https://example.com/a.zip")!))
    }

    // MARK: - Template rendering

    func testPackagizerRender() {
        let rule = PackagizerRule(filenameTemplate: "[{host}] {name}.{ext}")
        XCTAssertEqual(
            rule.render(filename: "movie.mp4", host: "example.com"),
            "[example.com] movie.mp4")
    }

    func testPackagizerRenderBlankTemplateKeepsName() {
        XCTAssertNil(PackagizerRule(filenameTemplate: "   ")
            .render(filename: "movie.mp4", host: "example.com"))
        XCTAssertNil(PackagizerRule(filenameTemplate: "")
            .render(filename: "movie.mp4", host: "example.com"))
    }

    func testPackagizerRenderBlankResultIsNil() {
        // Template of only placeholders that resolve empty.
        XCTAssertNil(PackagizerRule(filenameTemplate: "{host}")
            .render(filename: "movie.mp4", host: nil))
    }

    // MARK: - Stores

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testHostProfileStoreRoundTrip() {
        let dir = tempDir()
        let store = HostProfileStore(directory: dir)
        XCTAssertTrue(store.profiles.isEmpty)
        var profile = HostProfile(host: "example.com", username: "u", maxConnections: 4)
        store.add(profile)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profile(for: "sub.example.com")?.host, "example.com")
        XCTAssertNil(store.profile(for: "other.org"))

        profile.username = "u2"
        store.update(profile)
        XCTAssertEqual(store.profiles.first?.username, "u2")

        store.setEnabled(id: profile.id, enabled: false)
        XCTAssertNil(store.profile(for: "example.com"))

        // Persistence across instances.
        let reloaded = HostProfileStore(directory: dir)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.maxConnections, 4)

        store.remove(id: profile.id)
        XCTAssertTrue(store.profiles.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    func testPackagizerStoreRoundTrip() {
        let dir = tempDir()
        let store = PackagizerStore(directory: dir)
        let rule = PackagizerRule(
            name: "Zips", urlPattern: #"example\.com/.*\.zip"#,
            filenameTemplate: "[mf] {name}.{ext}", category: .document)
        store.add(rule)
        XCTAssertEqual(
            store.rule(for: URL(string: "https://example.com/a.zip")!)?.name, "Zips")
        XCTAssertNil(store.rule(for: URL(string: "https://example.com/a.rar")!))

        let reloaded = PackagizerStore(directory: dir)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertEqual(reloaded.rules.first?.category, .document)

        store.remove(id: rule.id)
        XCTAssertTrue(store.rules.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Host profile secrets (Keychain)

    /// CI runners (and locked-down environments) have no usable login
    /// keychain for an unsigned test bundle — probe once and skip the
    /// keychain-dependent tests instead.
    private func requireKeychain() throws {
        let probe = "grabbit-test-probe-\(UUID().uuidString)"
        let saved = KeychainStore.save("probe", account: probe)
        let loaded = try? KeychainStore.load(account: probe).get()
        KeychainStore.delete(account: probe)
        try XCTSkipUnless(
            saved && loaded == "probe",
            "Keychain unavailable in this environment")
    }

    func testHostProfilePasswordLivesInKeychainNotJSON() throws {
        try requireKeychain()
        let dir = tempDir()
        let profile = HostProfile(host: "example.com", username: "u", password: "s3cret")
        let account = HostProfile.keychainAccount(for: profile.id)
        defer {
            KeychainStore.delete(account: account)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = HostProfileStore(directory: dir)
        store.add(profile)
        let raw = try String(
            contentsOf: dir.appendingPathComponent("hostprofiles.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("s3cret"), "plaintext password must not be persisted")

        let reloaded = HostProfileStore(directory: dir)
        XCTAssertEqual(reloaded.profiles.first?.password, "s3cret")

        // Clearing the password deletes the Keychain item.
        var cleared = profile
        cleared.password = ""
        store.update(cleared)
        XCTAssertEqual(
            KeychainStore.load(account: account),
            .failure(KeychainStore.LoadError.notFound))
    }

    func testHostProfileLegacyPlaintextIsMigrated() throws {
        try requireKeychain()
        let dir = tempDir()
        let id = UUID()
        let account = HostProfile.keychainAccount(for: id)
        defer {
            KeychainStore.delete(account: account)
            try? FileManager.default.removeItem(at: dir)
        }

        let legacy = """
        [{"id":"\(id.uuidString)","host":"example.com","isEnabled":true,\
        "username":"u","password":"legacy-pass"}]
        """
        let file = dir.appendingPathComponent("hostprofiles.json")
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        let store = HostProfileStore(directory: dir)
        XCTAssertEqual(store.profiles.first?.password, "legacy-pass")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("legacy-pass"), "migration must scrub the file")
        XCTAssertEqual(try? KeychainStore.load(account: account).get(), "legacy-pass")
    }
}
