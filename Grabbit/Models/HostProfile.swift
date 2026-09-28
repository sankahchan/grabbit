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
}
