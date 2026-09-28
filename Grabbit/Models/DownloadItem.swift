import Foundation

public enum DownloadState: String, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case interrupted

    /// Static-key lookup. NOTE: `NSLocalizedString("state.\(rawValue)", comment: "")`
    /// does NOT work — interpolation builds the key "state.%@" which never
    /// matches the catalog, so the raw key leaks into the UI.
    public var localizedName: String {
        switch self {
        case .queued: NSLocalizedString("state.queued", comment: "")
        case .downloading: NSLocalizedString("state.downloading", comment: "")
        case .paused: NSLocalizedString("state.paused", comment: "")
        case .completed: NSLocalizedString("state.completed", comment: "")
        case .failed: NSLocalizedString("state.failed", comment: "")
        case .interrupted: NSLocalizedString("state.interrupted", comment: "")
        }
    }
}

public enum DownloadCategory: String, Codable, CaseIterable {
    case video
    case audio
    case document
    case other

    /// See DownloadState.localizedName — same interpolation pitfall.
    public var localizedName: String {
        switch self {
        case .video: NSLocalizedString("category.video", comment: "")
        case .audio: NSLocalizedString("category.audio", comment: "")
        case .document: NSLocalizedString("category.document", comment: "")
        case .other: NSLocalizedString("category.other", comment: "")
        }
    }

    /// "settings.folders.video" etc. for the Settings folder rows.
    public var settingsFolderName: String {
        switch self {
        case .video: NSLocalizedString("settings.folders.video", comment: "")
        case .audio: NSLocalizedString("settings.folders.audio", comment: "")
        case .document: NSLocalizedString("settings.folders.document", comment: "")
        case .other: NSLocalizedString("settings.folders.other", comment: "")
        }
    }

    // MARK: - Auto-detection

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv",
        "mpg", "mpeg", "ts", "m2ts", "3gp", "ogv",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "aiff", "mid",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "txt", "md", "markdown", "rtf", "csv", "epub", "odt", "ods", "odp",
    ]

    /// Best-effort category detection from a filename and/or MIME type.
    /// The extension wins over the Content-Type; anything unrecognized
    /// falls back to `.other`.
    public static func infer(filename: String, contentType: String? = nil) -> DownloadCategory {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            if videoExtensions.contains(ext) { return .video }
            if audioExtensions.contains(ext) { return .audio }
            if documentExtensions.contains(ext) { return .document }
        }
        if let ct = contentType?.lowercased() {
            if ct.hasPrefix("video/") { return .video }
            if ct.hasPrefix("audio/") { return .audio }
            if ct.hasPrefix("text/")
                || ct.contains("pdf")
                || ct.contains("msword")
                || ct.contains("officedocument")
                || ct.contains("rtf")
                || ct.contains("epub")
            { return .document }
        }
        return .other
    }
}

public enum SourceSite: String, Codable {
    case direct
    case youtube
    case x
    case tiktok
    case instagram
    case telegram
    case other
}

/// One byte-range slice of a segmented download. `receivedBytes` is the number
/// of bytes already written for this segment, measured from `startByte`.
public struct Segment: Codable, Identifiable {
    public var index: Int
    public var startByte: Int64
    public var endByte: Int64
    public var receivedBytes: Int64

    public var id: Int { index }

    public init(index: Int, startByte: Int64, endByte: Int64, receivedBytes: Int64 = 0) {
        self.index = index
        self.startByte = startByte
        self.endByte = endByte
        self.receivedBytes = receivedBytes
    }

    public var isComplete: Bool {
        receivedBytes >= byteCount
    }

    public var byteCount: Int64 {
        // Open-ended segment (unknown total size): endByte == .max is the
        // sentinel. Saturate instead of trapping on `.max - startByte + 1`
        // — Swift integer overflow is a hard runtime crash (hit via
        // DownloadItem.progress the moment an unknown-size task renders).
        if endByte == .max { return .max }
        return max(0, endByte - startByte + 1)
    }
}

public struct DownloadItem: Identifiable, Codable {
    public var id: UUID
    public var url: URL
    public var filename: String
    public var totalBytes: Int64?
    public var downloadedBytes: Int64
    public var segments: [Segment]
    public var state: DownloadState
    public var speedBytesPerSec: Double
    public var category: DownloadCategory
    public var sourceSite: SourceSite
    public var destinationURL: URL
    public var addedAt: Date
    public var errorMessage: String?
    /// Page the user copied this link from (used by the expired-link flow to
    /// point them back at the source). Never a secret.
    public var sourcePageURL: URL?
    /// Validators captured at probe time; a mismatch on resume means the file
    /// changed on the server (XDM resume discipline).
    public var eTag: String?
    public var lastModified: String?
    /// Set when a signed URL failed with 403/410: the link expired, the file
    /// didn't. Distinct from a generic failure so the UI can offer a
    /// "replace URL" flow instead of a dead retry button.
    public var linkExpired: Bool
    /// Request headers captured by the browser extension for this download
    /// (Cookie, Referer, User-Agent, …). Sent on every segment connection so
    /// authenticated/CDN-gated URLs work exactly like they did in the browser.
    ///
    /// Secrets hygiene (QDM `serde(skip)` pattern): cookies / Authorization
    /// are runtime-only and deliberately EXCLUDED from Codable — they are
    /// never written to the resume store on disk.
    public var requestHeaders: [String: String]?
    /// Phase 5 speed limiter: per-download cap in bytes/sec, 0 = unlimited
    /// (falls back to the global Settings limit). Persisted so a limit
    /// survives app restarts.
    public var speedLimitBytesPerSec: Int64 = 0
    /// Phase 5 named queues: the queue this task belongs to. nil = the
    /// default queue (also the legacy value for pre-queue resume files).
    public var queueID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, url, filename, totalBytes, downloadedBytes, segments, state,
             speedBytesPerSec, category, sourceSite, destinationURL, addedAt,
             errorMessage, sourcePageURL, eTag, lastModified, linkExpired,
             speedLimitBytesPerSec, queueID
        // requestHeaders intentionally absent: runtime-only secret.
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        totalBytes: Int64? = nil,
        downloadedBytes: Int64 = 0,
        segments: [Segment] = [],
        state: DownloadState = .queued,
        speedBytesPerSec: Double = 0,
        category: DownloadCategory = .other,
        sourceSite: SourceSite = .direct,
        destinationURL: URL,
        addedAt: Date = Date(),
        errorMessage: String? = nil,
        sourcePageURL: URL? = nil,
        eTag: String? = nil,
        lastModified: String? = nil,
        linkExpired: Bool = false,
        requestHeaders: [String: String]? = nil,
        speedLimitBytesPerSec: Int64 = 0,
        queueID: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.segments = segments
        self.state = state
        self.speedBytesPerSec = speedBytesPerSec
        self.category = category
        self.sourceSite = sourceSite
        self.destinationURL = destinationURL
        self.addedAt = addedAt
        self.errorMessage = errorMessage
        self.sourcePageURL = sourcePageURL
        self.eTag = eTag
        self.lastModified = lastModified
        self.linkExpired = linkExpired
        self.requestHeaders = requestHeaders
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.queueID = queueID
    }

    /// Custom decoder: `speedLimitBytesPerSec` (Phase 5) is absent from
    /// resume-store JSON written by older builds and must default to
    /// unlimited (0) instead of failing the whole file. (The synthesized
    /// decoder uses plain `decode` per key even for defaulted properties —
    /// hence the explicit `decodeIfPresent` here, mirroring AppSettings.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        filename = try c.decode(String.self, forKey: .filename)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        downloadedBytes = try c.decode(Int64.self, forKey: .downloadedBytes)
        segments = try c.decode([Segment].self, forKey: .segments)
        state = try c.decode(DownloadState.self, forKey: .state)
        speedBytesPerSec = try c.decode(Double.self, forKey: .speedBytesPerSec)
        category = try c.decode(DownloadCategory.self, forKey: .category)
        sourceSite = try c.decode(SourceSite.self, forKey: .sourceSite)
        destinationURL = try c.decode(URL.self, forKey: .destinationURL)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        sourcePageURL = try c.decodeIfPresent(URL.self, forKey: .sourcePageURL)
        eTag = try c.decodeIfPresent(String.self, forKey: .eTag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        linkExpired = try c.decodeIfPresent(Bool.self, forKey: .linkExpired) ?? false
        speedLimitBytesPerSec = try c.decodeIfPresent(Int64.self, forKey: .speedLimitBytesPerSec) ?? 0
        queueID = try c.decodeIfPresent(UUID.self, forKey: .queueID)
        // requestHeaders is runtime-only and never persisted.
        requestHeaders = nil
    }

    /// 0...1. Uses the server-advertised total when known, otherwise falls back
    /// to the sum of the segment ranges (e.g. size unknown at HEAD time).
    public var progress: Double {
        if let total = totalBytes, total > 0 {
            return min(1.0, Double(downloadedBytes) / Double(total))
        }
        let expected = segments.reduce(0) { $0 + $1.byteCount }
        guard expected > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(expected))
    }

    public var etaSeconds: Double? {
        guard state == .downloading, speedBytesPerSec > 0 else { return nil }
        let remaining: Int64
        if let total = totalBytes, total > 0 {
            remaining = max(0, total - downloadedBytes)
        } else {
            // Unknown total size: there is no meaningful remaining-bytes
            // estimate (the open-ended segment saturates byteCount at .max),
            // so report no ETA instead of an astronomic one.
            return nil
        }
        return Double(remaining) / speedBytesPerSec
    }

    /// Pure function: splits `[0, totalBytes)` into `connections` contiguous,
    /// non-overlapping segments. The last segment absorbs the remainder so the
    /// union always covers the full range exactly.
    public static func makeSegments(totalBytes: Int64, connections: Int) -> [Segment] {
        guard totalBytes > 0 else { return [] }
        // Never create more segments than there are bytes.
        let count = min(max(1, connections), Int(totalBytes))
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        var offset: Int64 = 0
        for i in 0..<count {
            var size = totalBytes / Int64(count)
            if i == count - 1 {
                size += totalBytes % Int64(count)
            }
            segments.append(Segment(index: i, startByte: offset, endByte: offset + size - 1))
            offset += size
        }
        return segments
    }
}

// MARK: - Phase 1 engine helpers (pure, unit-tested)

extension DownloadItem {
    /// QDM-style dynamic growth: find the largest not-yet-started segment with
    /// at least `minSplitBytes` remaining. Returns its index and the split
    /// point; the caller halves it and spawns a connection for the second
    /// half. Only untouched segments are split, so there is no byte-overlap
    /// bookkeeping at all. Open-ended segments (endByte == .max, unknown
    /// total size) are never split — there is no meaningful midpoint.
    public static func growthSplitPoint(
        segments: [Segment],
        maxConnections: Int,
        minSplitBytes: Int64
    ) -> (index: Int, mid: Int64)? {
        let incomplete = segments.filter { !$0.isComplete }
        guard incomplete.count < maxConnections else { return nil }
        guard let target = incomplete
            .filter({ $0.receivedBytes == 0 && $0.endByte != .max && $0.byteCount >= minSplitBytes })
            .max(by: { $0.byteCount < $1.byteCount })
        else { return nil }
        return (target.index, target.startByte + target.byteCount / 2)
    }

    /// Resume honesty (QDM): never trust bookkeeping over the filesystem.
    /// Clamps each segment's `receivedBytes` to what is actually on disk.
    public static func reconciledSegments(_ segments: [Segment], fileSize: Int64) -> [Segment] {
        segments.map { seg in
            var s = seg
            s.receivedBytes = min(seg.receivedBytes, max(0, fileSize - seg.startByte))
            return s
        }
    }

    /// Parses the total out of a `Content-Range` value:
    /// "bytes 0-0/12345" -> 12345. Nil when absent or malformed.
    public static func totalFromContentRange(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// Extracts a filename from a `Content-Disposition` header value.
    /// Handles `filename="a.zip"`, `filename=a.zip`, and RFC 5987
    /// `filename*=UTF-8''a%20b.zip`.
    public static func filenameFromContentDisposition(_ value: String) -> String? {
        if let star = value.range(of: "filename*=", options: .caseInsensitive) {
            let rest = value[star.upperBound...].trimmingCharacters(in: .whitespaces)
            if let sep = rest.range(of: "''") {
                let encoded = rest[sep.upperBound...].prefix { $0 != ";" }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if !encoded.isEmpty {
                    return encoded.removingPercentEncoding ?? String(encoded)
                }
            }
        }
        guard let range = value.range(of: "filename=", options: .caseInsensitive) else { return nil }
        let rest = value[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            let inner = rest.dropFirst()
            if let end = inner.firstIndex(of: "\"") {
                let name = String(inner[..<end])
                return name.isEmpty ? nil : name
            }
            return nil
        }
        let token = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : String(token)
    }

    /// True when the server now reports a validator we stored at probe time
    /// and it differs: the file changed on the server, so resuming would
    /// corrupt the download. Only compares when both sides have the value.
    public static func validatorsChanged(
        storedETag: String?,
        storedLastModified: String?,
        headers: [String: String]
    ) -> Bool {
        if let stored = storedETag, let current = headers["etag"], stored != current {
            return true
        }
        if let stored = storedLastModified, let current = headers["last-modified"], stored != current {
            return true
        }
        return false
    }
}
