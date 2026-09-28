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
