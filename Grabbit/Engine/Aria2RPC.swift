import Foundation

/// JSON-RPC 2.0 client for the aria2 daemon, as a Swift actor so concurrent
/// poll / add / pause calls from the engine serialize safely.
///
/// Auth: aria2 expects `token:<secret>` as the first RPC param of every call.
/// Transport is plain HTTP POST to `http://127.0.0.1:<port>/jsonrpc` — the
/// daemon only ever listens on loopback (`--rpc-listen-all=false`).
public actor Aria2RPC {
    public enum RPCError: Error, LocalizedError, Equatable {
        case transport(String)
        case server(code: Int, message: String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .transport(let m): return m
            case .server(let code, let message): return "aria2 error \(code): \(message)"
            case .badResponse(let m): return "Bad RPC response: \(m)"
            }
        }
    }

    private let endpoint: URL
    private let secret: String
    private let session: URLSession

    public init(port: UInt16, secret: String, session: URLSession = .shared) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
        self.secret = secret
        self.session = session
    }

    // MARK: - Core call

    /// Encodes one JSON-RPC request. Pure — unit-tested.
    public static func encodeCall(
        id: String,
        method: String,
        secret: String,
        params: [JSONValue] = []
    ) throws -> Data {
        let request = RPCRequest(
            id: id,
            method: method,
            params: [.string("token:\(secret)")] + params)
        return try JSONEncoder().encode(request)
    }

    @discardableResult
    public func call(method: String, params: [JSONValue] = []) async throws -> JSONValue {
        let body = try Self.encodeCall(
            id: UUID().uuidString, method: method, secret: secret, params: params)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw RPCError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RPCError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded: RPCResponse
        do {
            decoded = try JSONDecoder().decode(RPCResponse.self, from: data)
        } catch {
            throw RPCError.badResponse(error.localizedDescription)
        }
        if let err = decoded.error {
            throw RPCError.server(code: err.code, message: err.message)
        }
        return decoded.result ?? .null
    }

    // MARK: - Typed wrappers

    private func gid(from result: JSONValue, what: String) throws -> String {
        guard let gid = result.stringValue else {
            throw RPCError.badResponse("expected GID string from \(what)")
        }
        return gid
    }

    private func optionsParam(_ options: [String: String]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: options.map { ($0.key, JSONValue.string($0.value)) }))
    }

    /// Adds magnet / http(s) / ftp URIs. Returns the new GID.
    public func addUri(_ uris: [String], options: [String: String] = [:]) async throws -> String {
        let result = try await call(
            method: "aria2.addUri",
            params: [.array(uris.map(JSONValue.string)), optionsParam(options)])
        return try gid(from: result, what: "aria2.addUri")
    }

    /// Adds a .torrent from its base64-encoded bytes. Returns the new GID.
    public func addTorrent(_ base64: String, options: [String: String] = [:]) async throws -> String {
        let result = try await call(
            method: "aria2.addTorrent",
            params: [.string(base64), .array([]), optionsParam(options)])
        return try gid(from: result, what: "aria2.addTorrent")
    }

    public func tellStatus(gid: String) async throws -> TorrentStatus {
        let result = try await call(method: "aria2.tellStatus", params: [.string(gid)])
        guard let status = TorrentStatus.parse(result) else {
            throw RPCError.badResponse("aria2.tellStatus")
        }
        return status
    }

    private func parseStatusList(_ result: JSONValue, what: String) throws -> [TorrentStatus] {
        guard let array = result.arrayValue else {
            throw RPCError.badResponse(what)
        }
        return array.compactMap(TorrentStatus.parse)
    }

    public func tellActive() async throws -> [TorrentStatus] {
        let result = try await call(method: "aria2.tellActive")
        return try parseStatusList(result, what: "aria2.tellActive")
    }

    public func tellWaiting(offset: Int = 0, num: Int = 100) async throws -> [TorrentStatus] {
        let result = try await call(
            method: "aria2.tellWaiting", params: [.int(Int64(offset)), .int(Int64(num))])
        return try parseStatusList(result, what: "aria2.tellWaiting")
    }

    public func tellStopped(offset: Int = 0, num: Int = 1000) async throws -> [TorrentStatus] {
        let result = try await call(
            method: "aria2.tellStopped", params: [.int(Int64(offset)), .int(Int64(num))])
        return try parseStatusList(result, what: "aria2.tellStopped")
    }

    public func pause(gid: String) async throws {
        try await call(method: "aria2.pause", params: [.string(gid)])
    }

    public func unpause(gid: String) async throws {
        try await call(method: "aria2.unpause", params: [.string(gid)])
    }

    public func remove(gid: String) async throws {
        try await call(method: "aria2.remove", params: [.string(gid)])
    }

    /// Purges a stopped (error/completed/removed) download from the daemon.
    /// `aria2.remove` only works on active/waiting/paused downloads, so a
    /// retry of a failed torrent needs this before re-adding.
    public func removeDownloadResult(gid: String) async throws {
        try await call(method: "aria2.removeDownloadResult", params: [.string(gid)])
    }

    public func getFiles(gid: String) async throws -> [Aria2File] {
        let result = try await call(method: "aria2.getFiles", params: [.string(gid)])
        guard let array = result.arrayValue else {
            throw RPCError.badResponse("aria2.getFiles")
        }
        return array.compactMap(Aria2File.parse)
    }

    public func changeOption(gid: String, options: [String: String]) async throws {
        try await call(
            method: "aria2.changeOption",
            params: [.string(gid), optionsParam(options)])
    }

    public func getOption(gid: String) async throws -> [String: String] {
        let result = try await call(method: "aria2.getOption", params: [.string(gid)])
        guard case .object(let obj) = result else {
            throw RPCError.badResponse("aria2.getOption")
        }
        return obj.compactMapValues { $0.stringValue }
    }

    public func changeGlobalOption(_ options: [String: String]) async throws {
        try await call(method: "aria2.changeGlobalOption", params: [optionsParam(options)])
    }

    public func getGlobalOption() async throws -> [String: String] {
        let result = try await call(method: "aria2.getGlobalOption")
        guard case .object(let obj) = result else {
            throw RPCError.badResponse("aria2.getGlobalOption")
        }
        return obj.compactMapValues { $0.stringValue }
    }

    public func getVersion() async throws -> String {
        let result = try await call(method: "aria2.getVersion")
        guard let version = result["version"]?.stringValue else {
            throw RPCError.badResponse("aria2.getVersion")
        }
        return version
    }

    /// Health check: proves the daemon is alive *and* the secret is accepted.
    public func listMethods() async throws -> [String] {
        let result = try await call(method: "system.listMethods")
        guard let array = result.arrayValue else {
            throw RPCError.badResponse("system.listMethods")
        }
        return array.compactMap { $0.stringValue }
    }

    /// Asks the daemon to save its session and exit. The daemon is dying, so
    /// transport errors here are expected — callers should ignore them.
    public func shutdown() async throws {
        try await call(method: "aria2.shutdown")
    }
}

// MARK: - JSON value

/// Minimal heterogeneous JSON value for RPC params and results.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int64.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a JSON value"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let obj) = self { return obj[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// aria2 returns most numbers as strings ("12345") — accept all shapes.
    public var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return Bool(s)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - Request / response envelopes

public struct RPCRequest: Encodable {
    public var jsonrpc = "2.0"
    public var id: String
    public var method: String
    public var params: [JSONValue]
}

struct RPCResponse: Decodable {
    var result: JSONValue?
    var error: RPCErrorPayload?
}

struct RPCErrorPayload: Decodable {
    var code: Int
    var message: String
}

// MARK: - Torrent status

/// Parsed `aria2.tellStatus` result. aria2 encodes numbers as strings.
public struct TorrentStatus: Sendable, Equatable {
    public var gid: String
    /// "active" | "waiting" | "paused" | "error" | "complete" | "removed"
    public var status: String
    public var totalLength: Int64
    public var completedLength: Int64
    public var uploadLength: Int64
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var connections: Int
    public var numSeeders: Int
    public var dir: String
    public var name: String?
    public var infoHash: String?
    /// Magnet metadata continuation: when a magnet resolves, the daemon
    /// retires this GID and the real download continues under `followedBy`.
    public var followedBy: [String]
    public var following: String?
    public var errorCode: String?
    public var errorMessage: String?

    /// Human-readable failure line for the UI, including aria2's numeric
    /// errorCode (e.g. "Not a directory (code 1)") so failures are
    /// diagnosable without guessing. Only meaningful when status == "error".
    public var errorDisplay: String {
        let base = errorMessage ?? "Unknown error"
        if let code = errorCode, !code.isEmpty, code != "0" {
            return "\(base) (code \(code))"
        }
        return base
    }

    public static func parse(_ json: JSONValue) -> TorrentStatus? {
        guard let gid = json["gid"]?.stringValue,
              let status = json["status"]?.stringValue
        else { return nil }
        let btInfo = json["bittorrent"]?["info"]
        return TorrentStatus(
            gid: gid,
            status: status,
            totalLength: json["totalLength"]?.int64Value ?? 0,
            completedLength: json["completedLength"]?.int64Value ?? 0,
            uploadLength: json["uploadLength"]?.int64Value ?? 0,
            downloadSpeed: json["downloadSpeed"]?.int64Value ?? 0,
            uploadSpeed: json["uploadSpeed"]?.int64Value ?? 0,
            connections: Int(json["connections"]?.int64Value ?? 0),
            numSeeders: Int(json["numSeeders"]?.int64Value ?? 0),
            dir: json["dir"]?.stringValue ?? "",
            name: btInfo?["name"]?.stringValue,
            infoHash: json["infoHash"]?.stringValue,
            followedBy: json["followedBy"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            following: json["following"]?.stringValue,
            errorCode: json["errorCode"]?.stringValue,
            errorMessage: json["errorMessage"]?.stringValue)
    }
}

/// Maps aria2 task states onto Grabbit's `TorrentState`. Pure — unit-tested.
public enum Aria2StatusMapper {
    public static func map(_ status: TorrentStatus) -> TorrentState {
        switch status.status {
        case "active":
            // A torrent that finished downloading but is still seeding stays
            // "active" — only report seeding once every byte is present.
            if status.totalLength > 0 && status.completedLength >= status.totalLength {
                return .seeding
            }
            return .downloading
        case "waiting":
            return .downloading
        case "paused":
            return .paused
        case "error", "removed":
            return .failed
        case "complete":
            return .completed
        default:
            return .paused
        }
    }
}

// MARK: - Torrent files

/// One entry of `aria2.getFiles`. `index` is 1-based, matching aria2's
/// `select-file` option.
public struct Aria2File: Sendable, Equatable, Identifiable {
    public var index: Int
    public var path: String
    public var length: Int64
    public var completedLength: Int64
    public var selected: Bool
    public var id: Int { index }

    public static func parse(_ json: JSONValue) -> Aria2File? {
        guard let indexString = json["index"]?.stringValue,
              let index = Int(indexString),
              let path = json["path"]?.stringValue
        else { return nil }
        return Aria2File(
            index: index,
            path: path,
            length: json["length"]?.int64Value ?? 0,
            completedLength: json["completedLength"]?.int64Value ?? 0,
            selected: json["selected"]?.boolValue ?? true)
    }
}

// MARK: - GID lineage

/// Tracks which daemon GID belongs to which torrent item, and migrates the
/// mapping when a magnet resolves: the daemon retires the magnet's GID and
/// continues the real download under a new GID (`followedBy`). Without this
/// the item would show "complete at 0%" — the classic magnet bug.
public struct GidLineage: Sendable {
    private var gidToItem: [String: UUID] = [:]

    public init() {}

    public mutating func register(gid: String, item id: UUID) {
        gidToItem[gid] = id
    }

    /// Moves the item from `oldGid` to `newGid`. Returns the moved item id,
    /// or nil if `oldGid` was unknown.
    @discardableResult
    public mutating func migrate(from oldGid: String, to newGid: String) -> UUID? {
        guard let id = gidToItem.removeValue(forKey: oldGid) else { return nil }
        gidToItem[newGid] = id
        return id
    }

    public func itemID(for gid: String) -> UUID? {
        gidToItem[gid]
    }

    public mutating func forget(gid: String) {
        gidToItem.removeValue(forKey: gid)
    }

    public mutating func forgetItem(_ id: UUID) {
        gidToItem = gidToItem.filter { $0.value != id }
    }
}

// MARK: - Magnet parsing

public enum MagnetParser {
    /// Lowercased 40-char hex info hash from a magnet URI's `xt=urn:btih:…`
    /// param. Base32 hashes are not normalized (the daemon reports hex).
    public static func infoHash(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              components.scheme?.lowercased() == "magnet"
        else { return nil }
        let prefix = "urn:btih:"
        for item in components.queryItems ?? [] where item.name == "xt" {
            guard let value = item.value, value.lowercased().hasPrefix(prefix) else { continue }
            let hash = String(value.dropFirst(prefix.count))
            if hash.count == 40, hash.allSatisfy(\.isHexDigit) {
                return hash.lowercased()
            }
            return nil
        }
        return nil
    }

    public static func isMagnet(_ string: String) -> Bool {
        string.lowercased().hasPrefix("magnet:?")
    }

    /// Display name: the magnet's `dn` param (HTML-entities decoded —
    /// sites often emit `&ndash;` etc. raw), else the info hash.
    public static func displayName(for magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI) else { return nil }
        if let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value,
           !dn.isEmpty
        {
            return dn.decodingHTMLEntities
        }
        return infoHash(from: magnetURI)
    }
}
