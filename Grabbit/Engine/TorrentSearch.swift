import Foundation
import Observation

/// A normalized torrent-search hit from a public index. `source` is what
/// gets handed to `TorrentEngine.add` — a magnet built from the info hash
/// (with public trackers appended) or the index's `.torrent` download URL.
public struct TorrentSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sizeBytes: Int64?
    public let seeders: Int?
    public let leechers: Int?
    public let provider: TorrentSearchProvider
    /// Badge label: the built-in provider's name, or the custom indexer's
    /// own name for Torznab hits.
    public let providerName: String
    public let source: String

    public init(
        id: String,
        name: String,
        sizeBytes: Int64?,
        seeders: Int?,
        leechers: Int?,
        provider: TorrentSearchProvider,
        providerName: String? = nil,
        source: String
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.seeders = seeders
        self.leechers = leechers
        self.provider = provider
        self.providerName = providerName ?? provider.displayName
        self.source = source
    }
}

/// Public indexes Grabbit can search. Kept small on purpose: JSON/RSS
/// endpoints only (no HTML scraping), so a provider breaks loudly and the
/// fix is a one-liner.
public enum TorrentSearchProvider: String, CaseIterable, Identifiable, Sendable {
    case apibay
    case nyaa
    /// Custom Torznab indexers wear this kind; the badge shows the
    /// indexer's own name (see `TorrentSearchResult.providerName`).
    case torznab

    public var id: String { rawValue }

    /// The user-selectable built-ins (Torznab comes from settings).
    public static let builtIns: [TorrentSearchProvider] = [.apibay, .nyaa]

    public var displayName: String {
        switch self {
        case .apibay:
            NSLocalizedString("torrents.search.provider.apibay", comment: "")
        case .nyaa:
            NSLocalizedString("torrents.search.provider.nyaa", comment: "")
        case .torznab:
            NSLocalizedString("torrents.search.provider.torznab", comment: "")
        }
    }
}

/// What the search sheet is querying: a built-in provider or one of the
/// user's Torznab indexers.
public enum TorrentSearchSource: Identifiable, Hashable, Sendable {
    case builtin(TorrentSearchProvider)
    case torznab(TorznabIndexer)

    public var id: String {
        switch self {
        case .builtin(let provider): "builtin.\(provider.rawValue)"
        case .torznab(let indexer): "torznab.\(indexer.id.uuidString)"
        }
    }

    public var name: String {
        switch self {
        case .builtin(let provider): provider.displayName
        case .torznab(let indexer): indexer.name
        }
    }
}

public enum TorrentSearchError: LocalizedError {
    case badURL
    case badResponse(Int)
    case emptyResponse
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .badURL:
            NSLocalizedString("torrents.search.error.url", comment: "")
        case .badResponse(let code):
            String(
                format: NSLocalizedString(
                    "torrents.search.error.response", comment: ""),
                code)
        case .emptyResponse:
            NSLocalizedString("torrents.search.error.empty", comment: "")
        case .missingAPIKey:
            NSLocalizedString("torrents.search.error.apiKey", comment: "")
        }
    }
}

/// Minimal HTML-entity decoder for index payloads (`&amp;`, `&#39;`,
/// `&#x1F600;`). Deliberately small — anything unknown passes through.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "middot": "\u{00B7}",
        "times": "\u{00D7}",
    ]

    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while let amp = input[index...].firstIndex(of: "&") {
            output += input[index..<amp]
            guard let semi = input[amp...].firstIndex(of: ";"),
                  input.distance(from: amp, to: semi) <= 10
            else {
                output.append("&")
                index = input.index(after: amp)
                continue
            }
            let entity = String(input[input.index(after: amp)..<semi])
            output += decodeEntity(entity) ?? "&\(entity);"
            index = input.index(after: semi)
        }
        output += input[index...]
        return output
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body)
            }
            guard let value, let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        return named[entity.lowercased()]
    }
}

/// Parses the human sizes public indexes print ("1.2 GiB", "700 MiB").
enum HumanSize {
    static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scanner = Scanner(string: trimmed)
        guard let value = scanner.scanDouble() else { return nil }
        let unit = trimmed[scanner.currentIndex...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "kb": multiplier = 1_000
        case "kib": multiplier = 1_024
        case "mb": multiplier = 1_000_000
        case "mib": multiplier = 1_048_576
        case "gb": multiplier = 1_000_000_000
        case "gib": multiplier = 1_073_741_824
        case "tb": multiplier = 1_000_000_000_000
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }
}

/// Builds a magnet URI from an info hash plus the daemon's public tracker
/// list. A magnet with trackers resolves metadata far faster than one
/// relying on DHT alone.
enum MagnetLink {
    static func build(
        infoHash: String,
        name: String,
        trackers: [String] = Aria2Daemon.defaultTrackers
    ) -> String? {
        let hash = infoHash.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isInfoHash(hash) else { return nil }
        var components = URLComponents()
        components.scheme = "magnet"
        var items = [URLQueryItem(name: "xt", value: "urn:btih:\(hash)")]
        if !name.isEmpty {
            items.append(URLQueryItem(name: "dn", value: name))
        }
        for tracker in trackers.prefix(8) {
            items.append(URLQueryItem(name: "tr", value: tracker))
        }
        components.queryItems = items
        return components.string
    }

    /// A 40-char hex info hash that isn't the all-zero "no results" marker
    /// apibay returns for empty queries.
    static func isInfoHash(_ value: String) -> Bool {
        guard value.count == 40, value.allSatisfy(\.isHexDigit) else {
            return false
        }
        return value != String(repeating: "0", count: 40)
    }
}

/// Pure search pipeline: URL builders, payload parsers and the one network
/// call. Network-free parser entry points are tested directly.
enum TorrentSearch {
    static func apibayURL(query: String) -> URL? {
        var components = URLComponents(string: "https://apibay.org/q.php")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    static func nyaaURL(query: String) -> URL? {
        var components = URLComponents(string: "https://nyaa.si/")
        components?.queryItems = [
            URLQueryItem(name: "page", value: "rss"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "c", value: "0_0"),
            URLQueryItem(name: "f", value: "0"),
        ]
        return components?.url
    }

    static func search(
        provider: TorrentSearchProvider,
        query: String,
        session: URLSession = .shared
    ) async throws -> [TorrentSearchResult] {
        let url: URL
        switch provider {
        case .apibay:
            guard let built = apibayURL(query: query) else {
                throw TorrentSearchError.badURL
            }
            url = built
        case .nyaa:
            guard let built = nyaaURL(query: query) else {
                throw TorrentSearchError.badURL
            }
            url = built
        case .torznab:
            // Custom indexers go through searchTorznab with their own
            // URL/key; reaching here means a routing bug, not user input.
            throw TorrentSearchError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Grabbit/1.6 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            throw TorrentSearchError.badResponse(http.statusCode)
        }
        guard !data.isEmpty else { throw TorrentSearchError.emptyResponse }
        switch provider {
        case .apibay: return parseApibay(data: data)
        case .nyaa: return parseNyaa(data: data)
        case .torznab: return []
        }
    }

    // MARK: - Torznab

    /// The indexer URL is used as pasted (Jackett/Prowlarr torznab
    /// endpoints), with `t=search`, `q` and `apikey` appended. An apikey
    /// already embedded in the pasted URL wins.
    static func torznabURL(
        indexer: TorznabIndexer, apiKey: String, query: String
    ) -> URL? {
        guard var components = URLComponents(
            string: indexer.urlString
                .trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        var items = components.queryItems ?? []
        let hasKey = items.contains {
            $0.name.lowercased() == "apikey" && !($0.value ?? "").isEmpty
        }
        if !hasKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        items.append(URLQueryItem(name: "t", value: "search"))
        items.append(URLQueryItem(name: "q", value: query))
        components.queryItems = items
        return components.url
    }

    static func searchTorznab(
        indexer: TorznabIndexer,
        apiKey: String,
        query: String,
        session: URLSession = .shared
    ) async throws -> [TorrentSearchResult] {
        guard !apiKey.isEmpty
            || indexer.urlString.lowercased().contains("apikey")
        else { throw TorrentSearchError.missingAPIKey }
        guard let url = torznabURL(
            indexer: indexer, apiKey: apiKey, query: query)
        else { throw TorrentSearchError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Grabbit/1.6 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            throw TorrentSearchError.badResponse(http.statusCode)
        }
        guard !data.isEmpty else { throw TorrentSearchError.emptyResponse }
        return parseTorznab(data: data, indexerName: indexer.name)
    }

    static func parseTorznab(
        data: Data, indexerName: String
    ) -> [TorrentSearchResult] {
        let delegate = TorznabParser(indexerName: indexerName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    // MARK: - apibay (JSON)

    private struct ApibayEntry: Decodable {
        let id: String
        let name: String
        let infoHash: String
        let seeders: String
        let leechers: String
        let size: String
    }

    static func parseApibay(data: Data) -> [TorrentSearchResult] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let entries = try? decoder.decode(
            [ApibayEntry].self, from: data)
        else { return [] }
        return entries.compactMap { entry in
            let hash = entry.infoHash.lowercased()
            // The all-zero hash guards apibay's "no results" sentinel.
            guard MagnetLink.isInfoHash(hash) else { return nil }
            let name = HTMLEntities.decode(entry.name)
            guard let magnet = MagnetLink.build(infoHash: hash, name: name)
            else { return nil }
            return TorrentSearchResult(
                id: hash,
                name: name,
                sizeBytes: Int64(entry.size),
                seeders: Int(entry.seeders),
                leechers: Int(entry.leechers),
                provider: .apibay,
                source: magnet)
        }
    }

    // MARK: - Nyaa (RSS)

    static func parseNyaa(data: Data) -> [TorrentSearchResult] {
        let delegate = NyaaRSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }
}

/// Pulls title / link / nyaa:infoHash / seeders / leechers / size out of
/// Nyaa's RSS feed. Items without a usable hash or `.torrent` link are
/// dropped rather than shown un-addable.
private final class NyaaRSSParser: NSObject, XMLParserDelegate {
    private(set) var results: [TorrentSearchResult] = []
    private var inItem = false
    private var buffer = ""
    private var title = ""
    private var link = ""
    private var infoHash = ""
    private var seeders = ""
    private var leechers = ""
    private var size = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        if elementName == "item" {
            inItem = true
            title = ""
            link = ""
            infoHash = ""
            seeders = ""
            leechers = ""
            size = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard inItem else { return }
        let name = elementName.split(separator: ":").last.map(String.init)
            ?? elementName
        switch name {
        case "item":
            inItem = false
            appendResult()
        case "title":
            if title.isEmpty { title = text }
        case "link":
            if link.isEmpty { link = text }
        case "infoHash":
            if infoHash.isEmpty { infoHash = text }
        case "seeders":
            if seeders.isEmpty { seeders = text }
        case "leechers":
            if leechers.isEmpty { leechers = text }
        case "size":
            if size.isEmpty { size = text }
        default:
            break
        }
    }

    private func appendResult() {
        let name = HTMLEntities.decode(title)
        let hash = infoHash.lowercased()
        let source: String?
        if MagnetLink.isInfoHash(hash) {
            source = MagnetLink.build(infoHash: hash, name: name)
        } else if link.lowercased().hasSuffix(".torrent") {
            source = link
        } else {
            source = nil
        }
        guard let source, !name.isEmpty else { return }
        results.append(TorrentSearchResult(
            id: hash.isEmpty ? link : hash,
            name: name,
            sizeBytes: HumanSize.parse(size),
            seeders: Int(seeders),
            leechers: Int(leechers),
            provider: .nyaa,
            source: source))
    }
}

/// Torznab results are a Newznab-style RSS feed: `<item>` with title,
/// link/enclosure, size, and `<torznab:attr>` pairs carrying the info
/// hash, seeders and peers. Items without a hash or a fetchable .torrent
/// link are dropped.
private final class TorznabParser: NSObject, XMLParserDelegate {
    private let indexerName: String
    private(set) var results: [TorrentSearchResult] = []

    private var inItem = false
    private var buffer = ""
    private var title = ""
    private var link = ""
    private var enclosure = ""
    private var size = ""
    private var infoHash = ""
    private var seeders = ""
    private var peers = ""

    init(indexerName: String) {
        self.indexerName = indexerName
    }

    private func localName(_ element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        let name = localName(elementName)
        if name == "item" {
            inItem = true
            title = ""
            link = ""
            enclosure = ""
            size = ""
            infoHash = ""
            seeders = ""
            peers = ""
            return
        }
        guard inItem else { return }
        if name == "enclosure", let url = attributeDict["url"] {
            enclosure = url
            return
        }
        if name == "attr", let attr = attributeDict["name"]?.lowercased(),
           let value = attributeDict["value"]
        {
            switch attr {
            case "infohash":
                if infoHash.isEmpty { infoHash = value }
            case "seeders":
                if seeders.isEmpty { seeders = value }
            case "peers", "leechers":
                if peers.isEmpty { peers = value }
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard inItem else { return }
        switch localName(elementName) {
        case "item":
            inItem = false
            appendResult()
        case "title":
            if title.isEmpty { title = text }
        case "link":
            if link.isEmpty { link = text }
        case "size":
            if size.isEmpty { size = text }
        default:
            break
        }
    }

    private func appendResult() {
        let name = HTMLEntities.decode(title)
        let hash = infoHash.lowercased()
        let source: String?
        if MagnetLink.isInfoHash(hash) {
            source = MagnetLink.build(infoHash: hash, name: name)
        } else if !enclosure.isEmpty {
            source = enclosure
        } else if link.lowercased().hasPrefix("http") {
            source = link
        } else {
            source = nil
        }
        guard let source, !name.isEmpty else { return }
        results.append(TorrentSearchResult(
            id: hash.isEmpty ? source : hash,
            name: name,
            sizeBytes: Int64(size),
            seeders: Int(seeders),
            leechers: Int(peers),
            provider: .torznab,
            providerName: indexerName,
            source: source))
    }
}

/// Drives the search sheet: source, query, results, one in-flight search.
/// Owned by the sheet (`@State`) — nothing else in the app needs it.
@Observable
@MainActor
public final class TorrentSearchService {
    public private(set) var results: [TorrentSearchResult] = []
    public private(set) var isSearching = false
    public private(set) var hasSearched = false
    public private(set) var errorMessage: String?
    public var source: TorrentSearchSource = .builtin(.apibay)

    private var searchTask: Task<Void, Never>?

    public init() {}

    public func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        errorMessage = nil
        let source = source
        searchTask = Task { [weak self] in
            do {
                let found: [TorrentSearchResult]
                switch source {
                case .builtin(let provider):
                    found = try await TorrentSearch.search(
                        provider: provider, query: trimmed)
                case .torznab(let indexer):
                    let key = TorznabVault.loadKey(for: indexer.id) ?? ""
                    found = try await TorrentSearch.searchTorznab(
                        indexer: indexer, apiKey: key, query: trimmed)
                }
                guard !Task.isCancelled else { return }
                self?.results = found
                self?.isSearching = false
            } catch is CancellationError {
                // Superseded by a newer search; the new task owns state.
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.errorMessage = error.localizedDescription
                self?.isSearching = false
            }
        }
    }
}
