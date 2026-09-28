import Foundation

extension URL {
    /// Canonical key for de-duplication. URLs that fetch the same resource
    /// but differ textually map to one key:
    /// - scheme and host are lowercased (`HTTPS://EXAMPLE.COM/x` ==
    ///   `https://example.com/x`; hosts are case-insensitive per RFC 4343)
    /// - default ports are dropped (`https://example.com:443/x` ==
    ///   `https://example.com/x`)
    /// - fragments never reach the server, so they're dropped
    /// - empty queries (`?` with nothing after it) are dropped
    ///
    /// Path case is preserved — paths can be case-sensitive — and
    /// non-empty queries are kept verbatim.
    public var dedupKey: String {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased()
        else { return absoluteString }
        c.scheme = scheme
        c.host = host
        if (scheme == "https" && c.port == 443)
            || (scheme == "http" && c.port == 80)
        {
            c.port = nil
        }
        c.fragment = nil
        if c.query?.isEmpty == true { c.query = nil }
        return c.url?.absoluteString ?? absoluteString
    }
}
