import Foundation

/// Per-task proxy override (Motrix parity: per-task proxy in the add-task
/// dialog). `nil` on a task means "follow the global Settings proxy";
/// a non-nil value overrides it — including `.none`, which forces a direct
/// connection for that task even when a global proxy is configured.
///
/// Persisted on the task (Codable, `decodeIfPresent` → nil for old data).
public struct TaskProxy: Codable, Equatable, Sendable {
    /// Which proxy this task uses relative to the global setting.
    public enum Scope: String, Codable, CaseIterable, Sendable {
        /// Follow Settings > Proxy.
        case global
        /// Bypass any proxy for this task.
        case none
        /// Use the custom host/port below.
        case custom

        public var localizedName: String {
            NSLocalizedString("taskProxy.scope.\(rawValue)", comment: "")
        }
    }

    public var scope: Scope = .global
    public var mode: ProxyMode = .http
    public var host: String = ""
    public var port: Int = 8080
    public var username: String = ""
    public var password: String = ""
    /// Transient: true when the Keychain write failed and the plaintext
    /// password must stay in the task JSON as a fallback (never cleared
    /// merely because the Keychain errored). Not persisted, not compared.
    public var passwordKeychainFailed = false

    public init(
        scope: Scope = .global,
        mode: ProxyMode = .http,
        host: String = "",
        port: Int = 8080,
        username: String = "",
        password: String = ""
    ) {
        self.scope = scope
        self.mode = mode
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = min(max(port, 1), 65535)
        self.username = username
        self.password = password
    }

    /// The effective proxy for a task: the override wins when present,
    /// otherwise the global settings proxy.
    public static func resolve(
        override: TaskProxy?, settings: AppSettings
    ) -> ProxyConfig {
        guard let override else { return ProxyConfig(settings: settings) }
        switch override.scope {
        case .global:
            return ProxyConfig(settings: settings)
        case .none:
            return ProxyConfig() // direct
        case .custom:
            return ProxyConfig(
                mode: override.mode, host: override.host,
                port: override.port, username: override.username,
                password: override.password)
        }
    }

    // MARK: - Keychain-backed passwords

    /// Keychain account holding this task's proxy password.
    public static func keychainAccount(for taskID: UUID) -> String {
        "task-proxy-\(taskID.uuidString)"
    }

    /// Moves a legacy plaintext password (decoded from old task JSON, or
    /// set on a freshly-created task) into the Keychain, or repopulates
    /// the in-memory password from the Keychain. The password is never
    /// written to task JSON (see `encode(to:)`).
    ///
    /// If the Keychain write fails, `passwordKeychainFailed` is set so the
    /// plaintext stays in the task JSON as a fallback — a credential is
    /// never cleared merely because the Keychain errored.
    public static func restorePassword(
        _ proxy: inout TaskProxy?, for taskID: UUID
    ) {
        guard var p = proxy else { return }
        let account = keychainAccount(for: taskID)
        if !p.password.isEmpty {
            p.passwordKeychainFailed = !KeychainStore.save(p.password, account: account)
        } else if case .success(let saved) = KeychainStore.load(account: account) {
            p.password = saved
        }
        proxy = p
    }

    /// Deletes the task's Keychain password. Called when the task is removed.
    public static func deletePassword(for taskID: UUID) {
        KeychainStore.delete(account: keychainAccount(for: taskID))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case scope, mode, host, port, username, password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .global
        mode = try c.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .http
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        // Legacy plaintext copy (pre-Keychain builds) or "" — the
        // engines migrate it via restorePassword(_:for:) after decoding.
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(mode, forKey: .mode)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        // The secret never lives in task JSON — it lives in the Keychain —
        // unless the Keychain write failed (fallback keeps it working).
        try c.encode(passwordKeychainFailed ? password : "", forKey: .password)
    }

    public static func == (lhs: TaskProxy, rhs: TaskProxy) -> Bool {
        lhs.scope == rhs.scope && lhs.mode == rhs.mode &&
            lhs.host == rhs.host && lhs.port == rhs.port &&
            lhs.username == rhs.username && lhs.password == rhs.password
    }

    /// aria2 per-download options for this override, or nil when the task
    /// follows the daemon-wide (global) proxy. A `.none` scope pushes empty
    /// strings, which aria2 treats as "override with no proxy".
    public func aria2Options() -> [String: String]? {
        switch scope {
        case .global:
            return nil
        case .none:
            return ["http-proxy": "", "https-proxy": "", "all-proxy": ""]
        case .custom:
            return ProxyConfig(
                mode: mode, host: host, port: port,
                username: username, password: password).aria2GlobalOptions()
        }
    }
}
