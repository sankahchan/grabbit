import Foundation

/// What a dropped link/file actually is — the notch/pill drop zone routes
/// each kind to the right engine.
public enum NotchLinkKind: Equatable, Sendable {
    case magnet(String)
    case torrentURL(URL)
    case torrentFile(URL)
    case mediaPage(URL, SourceSite)
    case direct(URL)
    case invalid
}

/// Pure classification for the notch/pill drop zone. Tested.
public enum NotchLinkClassifier {
    /// Hosts that should open the Media tab (yt-dlp) instead of a direct
    /// file download.
    private static let mediaHosts: [String: SourceSite] = [
        "youtube.com": .youtube,
        "youtu.be": .youtube,
        "x.com": .x,
        "twitter.com": .x,
        "t.co": .x,
        "tiktok.com": .tiktok,
        "instagram.com": .instagram,
        "t.me": .telegram,
        "telegram.org": .telegram,
    ]

    /// First URL found in arbitrary dropped text (clipboard-style payloads
    /// often carry surrounding words or multiple lines).
    public static func firstURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s"'<>]+"#
        guard let range = text.range(of: pattern, options: .regularExpression)
        else { return nil }
        return URL(string: String(text[range]))
    }

    public static func classify(droppedText: String) -> NotchLinkKind {
        let trimmed = droppedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        if MagnetParser.isMagnet(trimmed) {
            return .magnet(trimmed)
        }
        guard let url = firstURL(in: trimmed) else { return .invalid }
        return classify(url: url)
    }

    public static func classify(droppedFileURL: URL) -> NotchLinkKind {
        guard droppedFileURL.isFileURL else { return .invalid }
        if droppedFileURL.pathExtension.lowercased() == "torrent" {
            return .torrentFile(droppedFileURL)
        }
        return .invalid
    }

    public static func classify(url: URL) -> NotchLinkKind {
        let scheme = url.scheme?.lowercased()
        if scheme == "magnet" {
            return .magnet(url.absoluteString)
        }
        guard scheme == "http" || scheme == "https" else { return .invalid }
        if url.pathExtension.lowercased() == "torrent" {
            return .torrentURL(url)
        }
        if let host = url.host?.lowercased(),
           let site = site(for: host)
        {
            return .mediaPage(url, site)
        }
        return .direct(url)
    }

    /// Exact host match first, then subdomain suffixes ("www.youtube.com"
    /// → "youtube.com").
    static func site(for host: String) -> SourceSite? {
        if let exact = mediaHosts[host] { return exact }
        let parts = host.split(separator: ".")
        guard parts.count > 1 else { return nil }
        for index in 1...min(parts.count - 1, 2) {
            let candidate = parts.dropFirst(index).joined(separator: ".")
            if let match = mediaHosts[candidate] { return match }
        }
        return nil
    }
}
