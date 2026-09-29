import Foundation

/// Parsed form of a `grabbit://download` URL.
///
/// The browser extension (and anything else — Shortcuts, terminal, other apps)
/// hands downloads to Grabbit through this scheme:
///
///     grabbit://download?payload=<path to Inbox JSON file>
///     grabbit://download?url=<percent-encoded>
///         [&filename=<name>]
///         [&cookie=<percent-encoded Cookie header>]
///         [&referer=<percent-encoded>]
///         [&userAgent=<percent-encoded>]
///         [&authorization=<percent-encoded>]
///         [&origin=<percent-encoded>]
///
/// The payload form is what the native helper uses: it writes URL, filename
/// and captured headers into the Grabbit Inbox and passes only the path, so
/// multi-KB cookie headers can never overflow an OS URL limit.
///
/// Only `http`/`https` target URLs are accepted; anything else returns nil.
struct GrabbitURLRequest {
    var url: URL
    var filename: String?
    /// Request headers the browser captured for this download (Cookie,
    /// Referer, …). Sent verbatim on every segment connection.
    var headers: [String: String]
}

/// Parsed form of a `grabbit://import` URL: a file that already exists on
/// disk (an in-page blob/MSE capture, or a finished browser download) that
/// should be registered in Grabbit as a completed task.
struct GrabbitImportRequest {
    var fileURL: URL
    /// Separate audio track captured alongside a video stream (MSE), muxed
    /// by the app before the file is filed away.
    var auxiliaryAudioURL: URL?
    var filename: String?
    var pageURL: URL?
    var source: String?
    var title: String?
    var mimeType: String?
}

enum GrabbitURLScheme {
    // MARK: - Inbox

    /// Where the native helper drops files before handing them to the app.
    static var inboxURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Grabbit/Inbox", isDirectory: true)
    }

    /// Import URLs only ever touch files inside the Grabbit Inbox — the
    /// native helper creates them there, so a hostile link can't make the
    /// app read or move an arbitrary path.
    static func isInInboxPath(_ path: String, inbox: URL? = nil) -> Bool {
        let base = (inbox ?? inboxURL).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    // MARK: - grabbit://download

    static func parse(_ url: URL, inbox: URL? = nil) -> GrabbitURLRequest? {
        guard url.scheme?.lowercased() == "grabbit",
              url.host?.lowercased() == "download",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        // Preferred transport: URL + headers live in an Inbox JSON payload.
        if let payloadPath = value("payload"), !payloadPath.isEmpty {
            guard isInInboxPath(payloadPath, inbox: inbox),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)),
                  let payload = try? JSONDecoder().decode(DownloadPayload.self, from: data),
                  let target = Self.httpURL(payload.url)
            else { return nil }
            return GrabbitURLRequest(
                url: target,
                filename: payload.filename.flatMap { $0.isEmpty ? nil : $0 },
                headers: payload.headers ?? [:])
        }

        guard let rawTarget = value("url"),
              let target = Self.httpURL(rawTarget)
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

    // MARK: - grabbit://import

    static func parseImport(_ url: URL, inbox: URL? = nil) -> GrabbitImportRequest? {
        guard url.scheme?.lowercased() == "grabbit",
              url.host?.lowercased() == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let payloadPath = value("payload"), !payloadPath.isEmpty,
              isInInboxPath(payloadPath, inbox: inbox),
              let data = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)),
              let payload = try? JSONDecoder().decode(ImportPayload.self, from: data),
              isInInboxPath(payload.path, inbox: inbox)
        else { return nil }

        var auxiliaryAudioURL: URL?
        if let aux = payload.auxPath, !aux.isEmpty, isInInboxPath(aux, inbox: inbox) {
            auxiliaryAudioURL = URL(fileURLWithPath: aux)
        }
        let pageURL = payload.pageUrl.flatMap { $0.isEmpty ? nil : Self.httpURL($0) }
        return GrabbitImportRequest(
            fileURL: URL(fileURLWithPath: payload.path),
            auxiliaryAudioURL: auxiliaryAudioURL,
            filename: payload.filename.flatMap { $0.isEmpty ? nil : $0 },
            pageURL: pageURL,
            source: payload.source,
            title: payload.title.flatMap { $0.isEmpty ? nil : $0 },
            mimeType: payload.mime.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Payload schema

    struct DownloadPayload: Decodable {
        var url: String
        var filename: String?
        var title: String?
        var pageUrl: String?
        var source: String?
        var headers: [String: String]?
    }

    struct ImportPayload: Decodable {
        var path: String
        var auxPath: String?
        var filename: String?
        var pageUrl: String?
        var source: String?
        var title: String?
        var mime: String?
    }

    // MARK: - Helpers

    private static func httpURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
