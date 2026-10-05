import Foundation

/// Turns an HTTP(S) torrent source into something the torrent engine can
/// digest. Jackett (and several trackers) 302 their download links to a
/// `magnet:` URI; aria2 rejects those with "redirect target URL could not
/// be parsed" (code 6) and URLSession's default delegate can't switch
/// schemes either. A redirect-capturing delegate grabs the magnet
/// Location; otherwise the served bytes are checked for a bencoded
/// torrent payload.
enum TorrentSourceResolver {
    enum Resolved {
        case magnet(String)
        case torrentFile(Data)
    }

    static func resolve(url: URL) async throws -> Resolved {
        let catcher = RedirectCatcher()
        let session = URLSession(
            configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Grabbit/1.6 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        if let magnet = catcher.capturedMagnet {
            return .magnet(magnet)
        }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            throw TorrentSourceError.badResponse(http.statusCode)
        }
        guard isTorrentBytes(data) else {
            throw TorrentSourceError.notTorrent
        }
        return .torrentFile(data)
    }

    /// Cheap bencode sniff: torrent files are dictionaries whose first
    /// keys are `announce`/`info` (some tools reorder, so also accept a
    /// plain dictionary opener with an announce key in the head). HTML
    /// login/error pages are rejected here.
    static func isTorrentBytes(_ data: Data) -> Bool {
        guard data.count > 20, data.first == UInt8(ascii: "d") else {
            return false
        }
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        return head.contains("announce") || head.contains("info")
    }
}

enum TorrentSourceError: LocalizedError {
    case badResponse(Int)
    case notTorrent

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            String(
                format: NSLocalizedString(
                    "torrents.search.error.response", comment: ""),
                code)
        case .notTorrent:
            NSLocalizedString("torrents.source.notTorrent", comment: "")
        }
    }
}

/// Captures a `magnet:` redirect target and stops the chain; every other
/// redirect follows normally. The lock guards cross-queue access: delegate
/// callbacks run on URLSession's serial queue, the caller reads after the
/// task completes.
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var magnet: String?

    var capturedMagnet: String? {
        lock.lock()
        defer { lock.unlock() }
        return magnet
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let target = request.url,
           target.scheme?.lowercased() == "magnet"
        {
            lock.lock()
            magnet = target.absoluteString
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
