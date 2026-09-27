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
    func download(url: URL, format: MediaFormat, to: URL, progress: @Sendable @escaping (Double) -> Void) async throws
}

/// yt-dlp backed extractor, fully wired: `listFormats` runs `yt-dlp -J`
/// through `MediaRuntimeResolver`, `download` streams progress from a
/// supervised `ManagedProcess`.
public final class YTDLPMediaExtractor: MediaExtractorProtocol {
    public init() {}

    private var ytDlpURL: URL? {
        try? MediaRuntimeResolver.resolve(.ytDlp).get()
    }

    private func helperBinDirs() -> [String] {
        let components: [MediaRuntimeResolver.Component] = [.ffmpeg, .deno]
        return components.compactMap {
            guard let url = try? MediaRuntimeResolver.resolve($0).get() else { return nil }
            return url.deletingLastPathComponent().path
        }
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
        guard let ytDlp = ytDlpURL else {
            throw ExtractorError.binaryMissing(expectedPath: expectedBinaryPath)
        }
        let probed = try await MediaProbe.probe(url: url, ytDlp: ytDlp, helperBinDirs: helperBinDirs()).get()
        return probed.presets.map { preset in
            MediaFormat(
                // id carries the yt-dlp -f spec so download() can use it directly.
                id: preset.formatSpec,
                qualityLabel: preset.label,
                ext: preset.isAudioOnly ? "mp3" : "mp4",
                filesize: preset.estimatedSize,
                isAudioOnly: preset.isAudioOnly)
        }
    }

    public func download(
        url: URL,
        format: MediaFormat,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let ytDlp = ytDlpURL else {
            throw ExtractorError.binaryMissing(expectedPath: expectedBinaryPath)
        }
        var args = [
            "-f", format.id,
            "--newline", "--no-playlist", "--no-warnings", "--continue",
            "-o", destination.path,
        ]
        if format.isAudioOnly {
            args += ["-x", "--audio-format", "mp3"]
        } else {
            args += ["--remux-video", "mp4/mkv"]
        }
        if let ffmpeg = try? MediaRuntimeResolver.resolve(.ffmpeg).get() {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        args.append(url.absoluteString)

        let proc = ManagedProcess()
        let progressRE = try? NSRegularExpression(pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#)
        proc.onStdoutLine = { line in
            guard let m = progressRE?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line),
                  let pct = Double(line[r])
            else { return }
            progress(min(1, pct / 100))
        }
        let result = await proc.run(
            executable: ytDlp,
            arguments: args,
            environment: MediaProbe.childEnvironment(extraBinDirs: helperBinDirs()))
        guard result.exitCode == 0 else {
            let detail = result.stderrTail.split(separator: "\n").last.map(String.init)
                ?? "yt-dlp exited with code \(result.exitCode)"
            throw ExtractorError.extractionFailed(detail)
        }
        progress(1)
    }

    private var expectedBinaryPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("bin/yt-dlp").path
            ?? "<bundle>/bin/yt-dlp"
    }
}
