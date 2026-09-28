import Foundation

/// Resolves MediaFire share pages (`mediafire.com/file/<id>/<name>`) to
/// their direct `download*.mediafire.com` file URLs.
///
/// Without this the engine downloads the ~300KB HTML share page, names it
/// `*.zip`, and reports "complete" — a bogus file that then fails archive
/// extraction ("Couldn't read PKZip signature"). The share page embeds the
/// real file link, so one page fetch is enough to find it.
enum MediaFireResolver {
    /// Returns the direct file URL, or the input unchanged when it isn't
    /// a MediaFire share page or resolution fails (caller falls back to
    /// the HTML-content guard instead of downloading blindly).
    static func resolve(
        _ url: URL,
        proxyDictionary: [AnyHashable: Any]? = nil
    ) async -> URL {
        guard isSharePage(url) else { return url }
        guard let html = await fetchSharePage(url, proxyDictionary: proxyDictionary),
              let direct = extractDirectURL(from: html),
              let directURL = URL(string: direct)
        else { return url }
        return directURL
    }

    /// `https://www.mediafire.com/file/<id>/<name>` (any mediafire host).
    static func isSharePage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("mediafire.com")
        else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count >= 2 && parts[0] == "file"
    }

    /// The share page embeds the real file link; it always starts with
    /// `https://download<digits>.mediafire.com/`.
    static func extractDirectURL(from html: String) -> String? {
        let pattern = #"https://download\d*\.mediafire\.com/[^"'<>\s]+"#
        return html.range(of: pattern, options: .regularExpression)
            .map { String(html[$0]) }
    }

    private static func fetchSharePage(
        _ url: URL,
        proxyDictionary: [AnyHashable: Any]?
    ) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // MediaFire serves a bot wall to non-browser user agents.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let session: URLSession
        if let proxyDictionary {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDictionary
            session = URLSession(configuration: config)
        } else {
            session = .shared
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count < 5_000_000
        else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
