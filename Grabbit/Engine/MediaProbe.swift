import Foundation

/// A download-ready quality choice derived from `yt-dlp -J` output.
public struct MediaPreset: Identifiable {
    public var id: String
    /// "Best", "1080p", "720p", "480p", "360p", "Audio (MP3)"
    public var label: String
    /// Passed to `yt-dlp -f`.
    public var formatSpec: String
    public var isAudioOnly: Bool
    public var estimatedSize: Int64?
    /// Backlog #10: video-only rows (no audio track merged).
    public var videoOnly: Bool
    /// Backlog #10: audio extraction format ("mp3"); nil keeps the
    /// original audio container.
    public var audioConvertFormat: String?

    public init(
        id: String,
        label: String,
        formatSpec: String,
        isAudioOnly: Bool = false,
        estimatedSize: Int64? = nil,
        videoOnly: Bool = false,
        audioConvertFormat: String? = nil
    ) {
        self.id = id
        self.label = label
        self.formatSpec = formatSpec
        self.isAudioOnly = isAudioOnly
        self.estimatedSize = estimatedSize
        self.videoOnly = videoOnly
        self.audioConvertFormat = audioConvertFormat
    }
}

public struct ProbedMedia {
    public var title: String
    public var duration: Double?
    public var webpageURL: URL?
    /// Backlog #10: `yt-dlp -J` "thumbnail" for the result card.
    public var thumbnailURL: URL?
    public var presets: [MediaPreset]
}

public enum MediaProbeError: Error, LocalizedError {
    case probeFailed(String)
    public var errorDescription: String? {
        if case .probeFailed(let m) = self { return m }
        return nil
    }
}

/// Runs `yt-dlp -J` and builds QDM-style quality presets from the format list.
public enum MediaProbe {
    /// Probes the URL. `ffmpeg`/`deno` dirs are injected into PATH so
    /// yt-dlp can use them (Deno is required for YouTube's JS challenges).
    /// `headers` are browser-captured request headers (Referer, Cookie, …)
    /// replayed on every yt-dlp request.
    public static func probe(
        url: URL,
        ytDlp: URL,
        helperBinDirs: [String] = [],
        headers: [String: String] = [:]
    ) async -> Result<ProbedMedia, Error> {
        let proc = ManagedProcess()
        let jsonBox = LockedBox(Data())
        proc.onStdoutLine = { line in
            // -J prints one JSON blob; accumulate raw lines.
            if let d = (line + "\n").data(using: .utf8) { jsonBox.append(d) }
        }
        let env = childEnvironment(extraBinDirs: helperBinDirs)
        let result = await proc.run(
            executable: ytDlp,
            arguments: ["-J", "--no-playlist", "--no-warnings"]
                + headerArguments(headers)
                + [url.absoluteString],
            environment: env)
        let jsonData = jsonBox.value
        guard result.exitCode == 0, !jsonData.isEmpty else {
            let detail = result.stderrTail.split(separator: "\n").last.map(String.init)
                ?? "yt-dlp exited with code \(result.exitCode)"
            return .failure(MediaProbeError.probeFailed(detail))
        }
        do {
            return .success(try parse(jsonData))
        } catch {
            return .failure(MediaProbeError.probeFailed("Couldn't parse yt-dlp output: \(error.localizedDescription)"))
        }
    }

    /// PATH with helper bin dirs first so yt-dlp finds ffmpeg/deno.
    public static func childEnvironment(extraBinDirs: [String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? "/usr/bin:/bin"
        let extra = extraBinDirs.filter { !$0.isEmpty }.joined(separator: ":")
        if !extra.isEmpty { env["PATH"] = extra + ":" + current }
        return env
    }

    /// Browser-captured request headers as yt-dlp arguments. `Referer` maps to
    /// `--referer` (yt-dlp rewrites it correctly for HLS/DASH children); every
    /// other header is replayed verbatim with `--add-header`. Sorted for
    /// deterministic arguments (unit-testable).
    public static func headerArguments(_ headers: [String: String]) -> [String] {
        var args: [String] = []
        if let referer = headers["Referer"], !referer.isEmpty {
            args += ["--referer", referer]
        }
        let remaining = headers
            .filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
            .sorted { $0.key < $1.key }
        for (name, value) in remaining where !value.isEmpty {
            args += ["--add-header", "\(name): \(value)"]
        }
        return args
    }

    // MARK: - Parsing (pure, unit-testable)

    static func parse(_ data: Data) throws -> ProbedMedia {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "media"
        let duration = json["duration"] as? Double
        let webpageURL = (json["webpage_url"] as? String).flatMap(URL.init(string:))
        let thumbnailURL = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        let formats = (json["formats"] as? [[String: Any]]) ?? []
        return ProbedMedia(
            title: title,
            duration: duration,
            webpageURL: webpageURL,
            thumbnailURL: thumbnailURL,
            presets: buildPresets(from: formats))
    }

    private struct Format {
        var height: Int?
        var filesize: Int64?
        var vcodec: String
        var acodec: String
    }

    private static func buildPresets(from raw: [[String: Any]]) -> [MediaPreset] {
        let formats: [Format] = raw.compactMap { f in
            Format(
                height: f["height"] as? Int,
                filesize: (f["filesize"] as? Int64) ?? (f["filesize_approx"] as? Int64),
                vcodec: (f["vcodec"] as? String) ?? "none",
                acodec: (f["acodec"] as? String) ?? "none")
        }
        guard !formats.isEmpty else { return [] }
        let videos = formats.filter { $0.vcodec != "none" }
        let audios = formats.filter { $0.acodec != "none" && $0.vcodec == "none" }
        let bestAudioSize = audios.compactMap(\.filesize).max()

        // HLS/DASH variants carry no filesize metadata, so a size must never
        // be a prerequisite for a preset — otherwise m3u8/mpd captures yield
        // zero presets and the media engine silently does nothing.
        let bestVideoSize = videos.compactMap(\.filesize).max()

        var presets: [MediaPreset] = []
        // Best: highest video + best audio merged. Added even when no
        // filesize is advertised (live/HLS streams).
        if !videos.isEmpty {
            presets.append(MediaPreset(
                id: "best", label: NSLocalizedString("media.preset.best", comment: ""),
                formatSpec: "bv*+ba/b",
                estimatedSize: bestVideoSize.map { $0 + (bestAudioSize ?? 0) }))
        }
        // Height-capped presets, highest first. A row is only added when the
        // probe actually lists a format in that height bucket (above the next
        // lower cap), so 4K/1440p appear only when available and lower rows
        // never duplicate a higher one.
        let rows: [(id: String, label: String, lower: Int, cap: Int)] = [
            ("2160p", NSLocalizedString("media.preset.2160p", comment: ""), 1440, 2160),
            ("1440p", NSLocalizedString("media.preset.1440p", comment: ""), 1080, 1440),
            ("1080p", NSLocalizedString("media.preset.1080p", comment: ""), 720, 1080),
            ("720p", NSLocalizedString("media.preset.720p", comment: ""), 480, 720),
            ("480p", NSLocalizedString("media.preset.480p", comment: ""), 360, 480),
            ("360p", NSLocalizedString("media.preset.360p", comment: ""), 0, 360),
        ]
        for (id, label, lower, cap) in rows {
            let bucketVideos = videos.filter {
                let h = $0.height ?? Int.max
                return h > lower && h <= cap
            }
            guard !bucketVideos.isEmpty else { continue }
            let bucketSize = bucketVideos.compactMap(\.filesize).max()
            presets.append(MediaPreset(
                id: id, label: label,
                formatSpec: "bv*[height<=\(cap)]+ba/b[height<=\(cap)]",
                estimatedSize: bucketSize.map { $0 + (bestAudioSize ?? 0) }))
        }
        if !videos.isEmpty {
            // Backlog #10: video-only row — best video track, no audio.
            presets.append(MediaPreset(
                id: "videoOnly", label: NSLocalizedString("media.preset.videoOnly", comment: ""),
                formatSpec: "bv*",
                estimatedSize: bestVideoSize,
                videoOnly: true))
        }
        if !audios.isEmpty {
            presets.append(MediaPreset(
                id: "audio", label: NSLocalizedString("media.preset.audio", comment: ""),
                formatSpec: "bestaudio",
                isAudioOnly: true,
                estimatedSize: bestAudioSize,
                audioConvertFormat: "mp3"))
            // Backlog #10: M4A extraction (AAC, Apple-friendly, no MP3
            // recompression artifacts beyond the one transcode).
            presets.append(MediaPreset(
                id: "audioM4A", label: NSLocalizedString("media.preset.audioM4A", comment: ""),
                formatSpec: "bestaudio",
                isAudioOnly: true,
                estimatedSize: bestAudioSize,
                audioConvertFormat: "m4a"))
            // Backlog #10: audio-only keeping the original container
            // (e.g. m4a/opus/webm) instead of forcing MP3.
            presets.append(MediaPreset(
                id: "audioOriginal", label: NSLocalizedString("media.preset.audioOriginal", comment: ""),
                formatSpec: "bestaudio",
                isAudioOnly: true,
                estimatedSize: bestAudioSize))
        }
        return presets
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Tiny lock-protected box for values mutated from pipe callbacks.
final class LockedBox<T> {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func append(_ data: Data) where T == Data {
        lock.withLock { _value.append(data) }
    }
}
