import Foundation

public enum DownloadState: String, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case interrupted
}

public enum DownloadCategory: String, Codable, CaseIterable {
    case video
    case audio
    case document
    case other
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
        max(0, endByte - startByte + 1)
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
        errorMessage: String? = nil
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
            let expected = segments.reduce(0) { $0 + $1.byteCount }
            remaining = max(0, expected - downloadedBytes)
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
