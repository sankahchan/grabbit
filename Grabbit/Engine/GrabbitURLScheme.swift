import Foundation

/// Parsed form of a `grabbit://download` URL.
///
/// The browser extension (and anything else — Shortcuts, terminal, other apps)
/// hands downloads to Grabbit through this scheme:
///
///     grabbit://download?url=<percent-encoded>
///         [&filename=<name>]
///         [&cookie=<percent-encoded Cookie header>]
///         [&referer=<percent-encoded>]
///         [&userAgent=<percent-encoded>]
///         [&authorization=<percent-encoded>]
///         [&origin=<percent-encoded>]
///
/// Only `http`/`https` target URLs are accepted; anything else returns nil.
struct GrabbitURLRequest {
    var url: URL
    var filename: String?
    /// Request headers the browser captured for this download (Cookie,
    /// Referer, …). Sent verbatim on every segment connection.
    var headers: [String: String]
}

enum GrabbitURLScheme {
    static func parse(_ url: URL) -> GrabbitURLRequest? {
        guard url.scheme?.lowercased() == "grabbit",
              url.host?.lowercased() == "download",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let rawTarget = value("url"),
              let target = URL(string: rawTarget),
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        var headers: [String: String] = [:]
        if let cookie = value("cookie"), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        if let referer = value("referer"), !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let userAgent = value("userAgent"), !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        if let authorization = value("authorization"), !authorization.isEmpty {
            headers["Authorization"] = authorization
        }
        if let origin = value("origin"), !origin.isEmpty {
            headers["Origin"] = origin
        }
        let filename = value("filename").flatMap { $0.isEmpty ? nil : $0 }
        return GrabbitURLRequest(url: target, filename: filename, headers: headers)
    }
}
