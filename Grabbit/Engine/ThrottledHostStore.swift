import Foundation

/// Hosts that throttle parallel connections.
///
/// Some file CDNs (send.now's `datatransfer.to`, …) answer `429`/`503` to a
/// multi-connection burst and then keep the token/IP blocked for minutes —
/// even single requests fail while the penalty is active. Downloads from a
/// throttling host must open a single stream.
///
/// The store is seeded with the hosts we know about, learns from live
/// `429`/`503` bursts, and persists to `throttledhosts.json` (a corrupt file
/// falls back to the seed). Matching is on the registrable-ish domain, so
/// every `dXXXX.datatransfer.to` token resolves to `datatransfer.to`.
public final class ThrottledHostStore {
    private var hosts: Set<String>
    private let fileURL: URL

    /// Hosts observed to ban multi-connection bursts. Keeping the seed means
    /// a fresh install never has to fail once before learning.
    public static let seed: Set<String> = ["clicknupload.net", "datatransfer.to"]

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("throttledhosts.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            self.hosts = Set(decoded).union(Self.seed)
        } else {
            self.hosts = Self.seed
        }
    }

    /// True when the host is known to throttle parallel connections.
    public func isThrottled(host: String?) -> Bool {
        guard let domain = Self.domain(host) else { return false }
        return hosts.contains(domain)
    }

    /// Records a throttling host so future downloads from it use one
    /// connection. Returns true when the host was newly learned.
    @discardableResult
    public func learn(host: String?) -> Bool {
        guard let domain = Self.domain(host), !hosts.contains(domain) else { return false }
        hosts.insert(domain)
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(hosts).sorted()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Registrable-ish domain: the last two labels
    /// (`d8177.datatransfer.to` → `datatransfer.to`). IP literals and
    /// single-label hosts are returned unchanged.
    static func domain(_ host: String?) -> String? {
        guard let host = host?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty
        else { return nil }
        if host.contains(":") { return host } // IPv6 literal
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            return host // IPv4 literal
        }
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }
}
