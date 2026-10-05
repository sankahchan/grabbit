import Foundation

/// Finds a locally running Jackett or Prowlarr and turns it into Torznab
/// indexer entries. Config files are read from their default macOS
/// locations (`~/.config/Jackett/ServerConfig.json`,
/// `~/.config/Prowlarr/config.xml`); a short HTTP probe confirms the
/// server is actually up before anything is added.
enum TorznabDiscovery {
    struct Found: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let urlString: String
        let apiKey: String
        /// "Jackett" or "Prowlarr" — for the result note only.
        let source: String
    }

    struct ProwlarrIndexer: Decodable, Sendable {
        let id: Int
        let name: String
        let enable: Bool?
        let `protocol`: String?
    }

    // MARK: - Config locations

    /// Modern Jackett (macOS .NET build) stores its config under
    /// Application Support; older builds used ~/.config. Both are checked
    /// in order.
    static var jackettConfigURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Application Support/Jackett/ServerConfig.json"),
            home.appendingPathComponent(
                ".config/Jackett/ServerConfig.json"),
        ]
    }

    /// First candidate that exists and parses.
    static func jackettConfig() -> JackettConfig? {
        for url in jackettConfigURLs {
            guard let data = try? Data(contentsOf: url),
                  let config = parseJackettConfig(data: data)
            else { continue }
            return config
        }
        return nil
    }

    static var prowlarrConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Prowlarr/config.xml")
    }

    // MARK: - Pure parsing (tested)

    struct JackettConfig: Equatable {
        let apiKey: String
        let port: Int
    }

    static func parseJackettConfig(data: Data) -> JackettConfig? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        let key = (object["APIKey"] as? String)
            ?? (object["apiKey"] as? String)
        let port = (object["Port"] as? Int)
            ?? (object["port"] as? Int)
            ?? 9117
        guard let key, !key.isEmpty else { return nil }
        return JackettConfig(apiKey: key, port: port)
    }

    struct ProwlarrConfig: Equatable {
        let apiKey: String
        let port: Int
    }

    static func parseProwlarrConfig(data: Data) -> ProwlarrConfig? {
        let delegate = ProwlarrConfigParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let key = delegate.apiKey, !key.isEmpty else { return nil }
        return ProwlarrConfig(apiKey: key, port: delegate.port ?? 9696)
    }

    static func parseProwlarrIndexers(data: Data) -> [ProwlarrIndexer] {
        (try? JSONDecoder().decode([ProwlarrIndexer].self, from: data)) ?? []
    }

    /// Enabled torrent indexers only — usenet stacks and disabled entries
    /// are useless to Grabbit's torrent engine. Missing fields count as
    /// enabled/torrent (older Prowlarr payloads).
    static func enabledTorrentIndexers(data: Data) -> [ProwlarrIndexer] {
        parseProwlarrIndexers(data: data).filter {
            $0.enable != false
                && ($0.`protocol` == nil || $0.`protocol` == "torrent")
        }
    }

    // MARK: - URL shapes

    static func jackettTorznabURL(port: Int) -> String {
        "http://localhost:\(port)/api/v2.0/indexers/all/results/torznab"
    }

    static func prowlarrTorznabURL(port: Int, indexerID: Int) -> String {
        "http://localhost:\(port)/\(indexerID)/api"
    }

    // MARK: - Discovery

    static func discover(session: URLSession = .shared) async -> [Found] {
        var found: [Found] = []

        if let config = jackettConfig(),
           await isReachable(port: config.port, session: session)
        {
            found.append(Found(
                id: "jackett",
                name: "Jackett",
                urlString: jackettTorznabURL(port: config.port),
                apiKey: config.apiKey,
                source: "Jackett"))
        }

        if let data = try? Data(contentsOf: prowlarrConfigURL),
           let config = parseProwlarrConfig(data: data),
           await isReachable(port: config.port, session: session),
           let list = try? await fetchProwlarrIndexers(
               port: config.port, apiKey: config.apiKey, session: session)
        {
            for indexer in enabledTorrentIndexers(data: list) {
                found.append(Found(
                    id: "prowlarr-\(indexer.id)",
                    name: indexer.name,
                    urlString: prowlarrTorznabURL(
                        port: config.port, indexerID: indexer.id),
                    apiKey: config.apiKey,
                    source: "Prowlarr"))
            }
        }

        return found
    }

    private static func isReachable(
        port: Int, session: URLSession
    ) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/")
        else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }

    private static func fetchProwlarrIndexers(
        port: Int, apiKey: String, session: URLSession
    ) async throws -> Data {
        guard var components = URLComponents(
            string: "http://localhost:\(port)/api/v1/indexer")
        else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Reads `<ApiKey>` and `<Port>` out of a *arr config.xml.
private final class ProwlarrConfigParser: NSObject, XMLParserDelegate {
    var apiKey: String?
    var port: Int?
    private var buffer = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "ApiKey":
            if apiKey == nil { apiKey = text }
        case "Port":
            if port == nil { port = Int(text) }
        default:
            break
        }
    }
}
