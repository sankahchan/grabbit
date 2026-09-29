import Foundation
import Observation

/// Site-media downloads via yt-dlp (YouTube, X, TikTok, IG, …).
///
/// Flow: `probe(url)` → `yt-dlp -J` → quality presets → `download(preset)`
/// runs yt-dlp with `--newline` and parses `[download] N%` progress lines.
/// HLS/DASH and merging are handled inside yt-dlp; the first remux attempt
/// failing falls back to MKV (XDM's MKV-fallback idea) via `--remux-video`.
///
/// Binaries come from `MediaRuntimeResolver`; Deno's dir is injected into
/// PATH so YouTube's JS challenges solve. Pause isn't meaningful for
/// yt-dlp (it owns resume via `--continue`); cancel kills the process group.
@Observable
public final class MediaEngine {
    public enum DownloadState {
        case idle, probing, ready, downloading, failed, completed
    }

    public var state: DownloadState = .idle
    public var probed: ProbedMedia?
    public var sourceURL: URL?
    public var progress: Double = 0
    public var statusLine: String = ""
    public var errorMessage: String?
    /// Phase 5 speed limiter: global cap in bytes/sec, 0 = unlimited.
    /// Synced from Settings by the UI before each download.
    public var speedLimitBytesPerSec: Int64 = 0

    private var process: ManagedProcess?
    /// Serializes probe/download calls.
    private var busy = false
    private let history: HistoryStore

    public init(history: HistoryStore = HistoryStore()) {
        self.history = history
    }

    // MARK: - Probe

    /// Probes the URL for title + quality presets. Returns nil + sets
    /// errorMessage when binaries are missing or the probe fails.
    @MainActor
    public func probe(url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        state = .probing
        probed = nil
        errorMessage = nil
        progress = 0
        statusLine = ""
        sourceURL = url

        let ytDlp: URL
        switch MediaRuntimeResolver.resolve(.ytDlp) {
        case .success(let u): ytDlp = u
        case .failure(let e):
            fail(e.localizedDescription)
            return
        }
        let helpers = helperBinDirs()
        switch await MediaProbe.probe(url: url, ytDlp: ytDlp, helperBinDirs: helpers) {
        case .success(let media):
            probed = media
            state = media.presets.isEmpty ? .failed : .ready
            if media.presets.isEmpty { errorMessage = "No downloadable formats found." }
        case .failure(let e):
            fail(e.localizedDescription)
        }
    }

    // MARK: - Download

    /// Downloads the probed media with the chosen preset into `directory`.
    /// The finished file lands at `directory/<safe title>.<ext>`.
    @MainActor
    public func download(preset: MediaPreset, to directory: URL) async {
        guard !busy, let media = probed, let source = sourceURL else { return }
        busy = true
        defer { busy = false }
        state = .downloading
        errorMessage = nil
        progress = 0

        let ytDlp: URL
        switch MediaRuntimeResolver.resolve(.ytDlp) {
        case .success(let u): ytDlp = u
        case .failure(let e):
            history.record(.media(
                name: media.title,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .failed,
                errorMessage: e.localizedDescription))
            fail(e.localizedDescription)
            return
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = Self.safeFilename(media.title)
        // %(ext)s lets yt-dlp pick the real container (mp4, mkv fallback, mp3).
        let template = directory.appendingPathComponent("\(safeTitle).%(ext)s").path

        var args = [
            "-f", preset.formatSpec,
            "--newline", "--no-playlist", "--no-warnings",
            "--continue",
            "-o", template,
        ]
        if preset.isAudioOnly {
            // Backlog #10: only convert when the preset names a target
            // format (MP3); otherwise keep the original audio container.
            if let fmt = preset.audioConvertFormat {
                args += ["-x", "--audio-format", fmt]
            }
        } else {
            // XDM's MKV fallback: if the mp4 remux fails, yt-dlp retries as mkv
            // instead of failing the download.
            args += ["--remux-video", "mp4/mkv"]
        }
        if let ffmpegDir = binDir(of: .ffmpeg) {
            args += ["--ffmpeg-location", ffmpegDir]
        }
        // Phase 5 speed limiter: yt-dlp enforces its own per-process cap.
        if speedLimitBytesPerSec > 0 {
            args += ["--limit-rate", Self.rateString(speedLimitBytesPerSec)]
        }
        args.append(source.absoluteString)

        let proc = ManagedProcess()
        process = proc
        let progressRE = try? NSRegularExpression(pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#)
        proc.onStdoutLine = { [weak self] line in
            guard let self else { return }
            if let m = progressRE?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line),
               let pct = Double(line[r])
            {
                let clamped = min(1, pct / 100)
                DispatchQueue.main.async {
                    self.progress = clamped
                    self.statusLine = line
                }
            }
        }
        let result = await proc.run(
            executable: ytDlp,
            arguments: args,
            environment: MediaProbe.childEnvironment(extraBinDirs: helperBinDirs()))
        process = nil

        if result.wasCancelled {
            state = .ready
            statusLine = ""
            progress = 0
        } else if result.exitCode == 0 {
            state = .completed
            progress = 1
            statusLine = ""
            history.record(.media(
                name: media.title,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .completed))
        } else {
            let detail = result.stderrTail.split(separator: "\n").last.map(String.init)
                ?? "yt-dlp exited with code \(result.exitCode)"
            history.record(.media(
                name: media.title,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .failed,
                errorMessage: detail))
            fail(detail)
        }
    }

    @MainActor
    public func cancel() {
        process?.cancel()
    }

    @MainActor
    public func reset() {
        process?.cancel()
        process = nil
        state = .idle
        probed = nil
        sourceURL = nil
        progress = 0
        statusLine = ""
        errorMessage = nil
    }

    // MARK: - Helpers

    @MainActor
    private func fail(_ message: String) {
        state = .failed
        errorMessage = message
    }

    /// Dirs of resolved helper binaries (ffmpeg, deno) for PATH injection.
    private func helperBinDirs() -> [String] {
        let components: [MediaRuntimeResolver.Component] = [.ffmpeg, .deno]
        return components.compactMap {
            guard case .success(let url) = MediaRuntimeResolver.resolve($0) else { return nil }
            return url.deletingLastPathComponent().path
        }
    }

    private func binDir(of component: MediaRuntimeResolver.Component) -> String? {
        guard case .success(let url) = MediaRuntimeResolver.resolve(component) else { return nil }
        return url.deletingLastPathComponent().path
    }

    static func safeFilename(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(cleaned.prefix(120))
        return truncated.isEmpty ? "media" : truncated
    }

    /// Phase 5 speed limiter: yt-dlp `--limit-rate` wants "100K"/"1M" style.
    static func rateString(_ bytesPerSec: Int64) -> String {
        if bytesPerSec >= 1_048_576 {
            return "\(bytesPerSec / 1_048_576)M"
        }
        return "\(max(1, bytesPerSec / 1_024))K"
    }

    /// Extension-triggered stream download: probes the URL and downloads the
    /// best quality preset to the given directory. Used for m3u8/mpd URLs
    /// captured by the browser extension.
    public func downloadStream(url: URL, to directory: URL) async {
        await probe(url: url)
        guard let media = probed, !media.presets.isEmpty else { return }
        // Prefer "Best" preset, fall back to first available.
        let preset = media.presets.first(where: { $0.label == "Best" })
            ?? media.presets[0]
        await download(preset: preset, to: directory)
    }
}
