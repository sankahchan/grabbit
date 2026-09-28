import XCTest
@testable import Grabbit

/// Proxy secrets live in the Keychain, never in persisted JSON.
/// Uses an isolated Keychain account per test class run; UserDefaults is
/// saved/restored around each test so the real settings are untouched.
final class ProxyKeychainTests: XCTestCase {
    private var account: String!
    private var savedDefaults: Data?

    override func setUp() {
        super.setUp()
        account = "grabbit-test-\(UUID().uuidString)"
        savedDefaults = UserDefaults.standard.data(
            forKey: SettingsStore.userDefaultsKey)
        UserDefaults.standard.removeObject(
            forKey: SettingsStore.userDefaultsKey)
    }

    override func tearDown() {
        KeychainStore.delete(account: account)
        if let savedDefaults {
            UserDefaults.standard.set(
                savedDefaults, forKey: SettingsStore.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: SettingsStore.userDefaultsKey)
        }
        super.tearDown()
    }

    private func persistedSettings() throws -> AppSettings {
        let data = try XCTUnwrap(UserDefaults.standard.data(
            forKey: SettingsStore.userDefaultsKey))
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    // MARK: - Global proxy password

    func testLegacyGlobalPasswordMigratesToKeychain() throws {
        // Plant a pre-Keychain settings blob with a plaintext password.
        var legacy = AppSettings.default
        legacy.proxyPassword = "s3cret"
        UserDefaults.standard.set(
            try JSONEncoder().encode(legacy),
            forKey: SettingsStore.userDefaultsKey)

        let store = SettingsStore(keychainAccount: account)

        // Working copy is populated (engines read this)…
        XCTAssertEqual(store.settings.proxyPassword, "s3cret")
        // …the Keychain holds it…
        XCTAssertEqual(
            try KeychainStore.load(account: account).get(), "s3cret")
        // …and the persisted copy is scrubbed.
        XCTAssertEqual(try persistedSettings().proxyPassword, "")
    }

    func testGlobalPasswordWriteThroughAndReload() throws {
        let store = SettingsStore(keychainAccount: account)
        store.settings.proxyPassword = "n3wpw"
        store.save()

        // A fresh launch repopulates the working copy from the Keychain,
        // not from UserDefaults.
        let reloaded = SettingsStore(keychainAccount: account)
        XCTAssertEqual(reloaded.settings.proxyPassword, "n3wpw")
        XCTAssertEqual(try persistedSettings().proxyPassword, "")
    }

    func testClearingGlobalPasswordDeletesKeychainItem() throws {
        let store = SettingsStore(keychainAccount: account)
        store.settings.proxyPassword = "todelete"
        store.save()
        store.settings.proxyPassword = ""
        store.save()

        let result = KeychainStore.load(account: account)
        guard case .failure(.notFound) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
    }

    // MARK: - Per-task proxy password

    func testTaskProxyPasswordNeverHitsJSON() throws {
        let proxy = TaskProxy(
            scope: .custom, mode: .http, host: "proxy.example",
            port: 8080, username: "u", password: "pw")
        let data = try JSONEncoder().encode(proxy)
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8))
        XCTAssertTrue(
            json.contains("\"password\":\"\""),
            "password leaked into task JSON: \(json)")
    }

    func testTaskProxyPasswordRoundTripsViaKeychain() throws {
        let taskID = UUID()
        var proxy: TaskProxy? = TaskProxy(
            scope: .custom, host: "proxy.example", password: "taskpw")
        TaskProxy.restorePassword(&proxy, for: taskID)
        // Still in memory for the engines…
        XCTAssertEqual(proxy?.password, "taskpw")
        // …in the Keychain…
        XCTAssertEqual(
            try KeychainStore.load(
                account: TaskProxy.keychainAccount(for: taskID)).get(),
            "taskpw")
        // …and never in the persisted JSON.
        let data = try JSONEncoder().encode(proxy)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            json.contains("\"password\":\"\""),
            "password leaked into task JSON: \(json)")

        // A fresh decode repopulates the working copy from the Keychain.
        var decoded = try JSONDecoder().decode(
            TaskProxy?.self, from: data)
        XCTAssertEqual(decoded?.password, "")
        TaskProxy.restorePassword(&decoded, for: taskID)
        XCTAssertEqual(decoded?.password, "taskpw")

        TaskProxy.deletePassword(for: taskID)
        let result = KeychainStore.load(
            account: TaskProxy.keychainAccount(for: taskID))
        guard case .failure(.notFound) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
    }

    func testLegacyTaskProxyPasswordMigrates() throws {
        // Old task JSON with a plaintext password (pre-Keychain builds).
        let legacyJSON = """
            {"scope":"custom","mode":"http","host":"h","port":8080,\
            "username":"u","password":"legacypw"}
            """.data(using: .utf8)!
        let taskID = UUID()
        var proxy = try JSONDecoder().decode(
            TaskProxy?.self, from: legacyJSON)
        XCTAssertEqual(proxy?.password, "legacypw")
        TaskProxy.restorePassword(&proxy, for: taskID)
        XCTAssertEqual(
            try KeychainStore.load(
                account: TaskProxy.keychainAccount(for: taskID)).get(),
            "legacypw")
    }
}
