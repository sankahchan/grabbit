import Foundation

/// Per-host profile (backlog #3, AB Download Manager idea): saved
/// credentials, thread count, and user-agent for one host. When a download
/// URL's host matches, the profile's values apply automatically.
public struct HostProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// "example.com" — matches the host and all its subdomains.
    public var host: String
    public var isEnabled: Bool
    public var username: String
    public var password: String
    /// nil = use the global default connection count.
    public var maxConnections: Int?
    /// "" = use Grabbit's default user agent.
    public var userAgent: String
    /// Set when the Keychain write failed: the password then stays in the
    /// profile JSON as a fallback, exactly like `TaskProxy`. Credentials are
    /// never cleared merely because the Keychain errored.
    public var passwordKeychainFailed = false

    public init(
        id: UUID = UUID(),
        host: String = "",
        isEnabled: Bool = true,
        username: String = "",
        password: String = "",
        maxConnections: Int? = nil,
        userAgent: String = ""
    ) {
        self.id = id
        self.host = host
        self.isEnabled = isEnabled
        self.username = username
        self.password = password
        self.maxConnections = maxConnections
        self.userAgent = userAgent
    }

    /// Keychain account holding this profile's password.
    public static func keychainAccount(for id: UUID) -> String {
        "host-profile-\(id.uuidString)"
    }

    /// Suffix match on the normalized host: "example.com" matches
    /// "example.com" and "sub.example.com", but not "notexample.com".
    public func matches(host candidate: String?) -> Bool {
        guard isEnabled,
              let candidate = candidate?.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return false }
        let wanted = host.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return candidate == wanted || candidate.hasSuffix("." + wanted)
    }

    /// HTTP Basic credential, or nil when no username is saved.
    public func authorizationHeader() -> String? {
        guard !username.isEmpty else { return nil }
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Codable
    //
    // The secret never lives in hostprofiles.json — it lives in the Keychain
    // (see HostProfileStore) — unless the Keychain write failed.

    private enum CodingKeys: String, CodingKey {
        case id, host, isEnabled, username, password, maxConnections, userAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        // Legacy plaintext copy (pre-Keychain builds) or "" — the store
        // migrates it to the Keychain on load.
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(host, forKey: .host)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(username, forKey: .username)
        try c.encode(passwordKeychainFailed ? password : "", forKey: .password)
        try c.encodeIfPresent(maxConnections, forKey: .maxConnections)
        try c.encode(userAgent, forKey: .userAgent)
    }
}
