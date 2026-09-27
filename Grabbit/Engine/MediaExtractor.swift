import Foundation

public struct MediaFormat: Codable, Identifiable {
    public var id: String
    public var qualityLabel: String
    public var ext: String
    public var filesize: Int64?
    public var isAudioOnly: Bool

    public init(
        id: String,
        qualityLabel: String,
        ext: String,
        filesize: Int64? = nil,
        isAudioOnly: Bool = false
    ) {
        self.id = id
        self.qualityLabel = qualityLabel
        self.ext = ext
        self.filesize = filesize
        self.isAudioOnly = isAudioOnly
    }
}

public enum ExtractorError: Error, LocalizedError {
    case binaryMissing(expectedPath: String)
    case unsupportedURL(URL)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return "Media extractor binary not found at \(path)"
        case .unsupportedURL(let url):
            return "Unsupported URL: \(url.absoluteString)"
        case .extractionFailed(let message):
            return message
        }
    }
}

public protocol MediaExtractorProtocol {
    func detectSite(url: URL) -> SourceSite
    func listFormats(url: URL) async throws -> [MediaFormat]
    func download(url: URL, format: MediaFormat, to: URL, progress: (Double) -> Void) async throws
}

/// yt-dlp backed extractor. DOCUMENTED STUB: `detectSite` is real (pure host
/// matching); `listFormats`/`download` throw `.binaryMissing` until the bundled
/// binary is wired in a later milestone.
public final class YTDLPMediaExtractor: MediaExtractorProtocol {
    public init() {}

    /// The bundled binary ships at `<App>.app/Contents/Resources/bin/yt-dlp`.
    private var binaryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/yt-dlp")
    }

    public func detectSite(url: URL) -> SourceSite {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("x.com") || host.contains("twitter.com") { return .x }
        if host.contains("tiktok.com") { return .tiktok }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("t.me") || host.hasSuffix("telegram.org") { return .telegram }
        return .direct
    }

    public func listFormats(url: URL) async throws -> [MediaFormat] {
        // Intended wiring (not yet connected — the binary ships in a later milestone):
        //   <bundle>/bin/yt-dlp --dump-json --no-playlist "<url>"
        // Parse each stdout JSON line's "formats" array into [MediaFormat]:
        //   id           <- "format_id"
        //   qualityLabel <- "format_note" ?? "resolution" ?? "format_id"
        //   ext          <- "ext"
        //   filesize     <- "filesize" (may be absent for DASH/HLS)
        //   isAudioOnly  <- "vcodec" == "none"
        // Throw .unsupportedURL for hosts yt-dlp can't handle.
        let expected = binaryURL?.path ?? "<bundle>/bin/yt-dlp"
        throw ExtractorError.binaryMissing(expectedPath: expected)
    }

    public func download(url: URL, format: MediaFormat, to destination: URL, progress: (Double) -> Void) async throws {
        // Intended wiring:
        //   <bundle>/bin/yt-dlp -f <format.id> --no-playlist -o "<destination.path>" "<url>"
        // Drive `progress` by parsing the "[download]  42.3%" lines on stderr.
        // NOTE: for sites with segmented media, an alternative is to hand the
        // resolved direct media URL to DownloadEngine for multi-connection fetch.
        let expected = binaryURL?.path ?? "<bundle>/bin/yt-dlp"
        throw ExtractorError.binaryMissing(expectedPath: expected)
    }
}
