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
    /// Completion/failure toast cards (wired by GrabbitApp, like the other
    /// engines). Media downloads previously finished silently.
    public weak var toastCenter: ToastCenter?
    /// Optional settings — drives notification/sound preferences.
    public weak var settingsStore: SettingsStore?

    private var process: ManagedProcess?
    /// Serializes probe/download calls.
    private var busy = false
    private let history: HistoryStore
    /// Browser-captured headers for the current probe/download (Referer,
    /// Cookie, …). Set by `probe`/`downloadStream`, replayed by `download`.
    private var probeHeaders: [String: String] = [:]
    /// Preferred display/file name for an extension-triggered stream (the
    /// page title). Nil for interactive probes — yt-dlp's own title wins.
    private var preferredTitle: String?

    public init(history: HistoryStore = HistoryStore()) {
        self.history = history
    }

    // MARK: - Probe

    /// Probes the URL for title + quality presets. Returns nil + sets
    /// errorMessage when binaries are missing or the probe fails. `headers`
    /// are browser-captured request headers and are replayed on the probe.
    @MainActor
    public func probe(url: URL, headers: [String: String]? = nil) async {
        guard !busy else {
            NSLog("[Grabbit] MediaEngine.probe skipped: busy")
            return
        }
        busy = true
        defer { busy = false }
        state = .probing
        probed = nil
        errorMessage = nil
        progress = 0
        statusLine = ""
        sourceURL = url
        probeHeaders = headers ?? [:]
        preferredTitle = nil

        let ytDlp: URL
        switch MediaRuntimeResolver.resolve(.ytDlp) {
        case .success(let u): ytDlp = u
        case .failure(let e):
            NSLog("[Grabbit] yt-dlp resolve failed: %@", e.localizedDescription)
            fail(e.localizedDescription)
            return
        }
        NSLog("[Grabbit] probing with yt-dlp at %@", ytDlp.path)
        let helpers = helperBinDirs()
        switch await MediaProbe.probe(
            url: url, ytDlp: ytDlp, helperBinDirs: helpers, headers: probeHeaders
        ) {
        case .success(let media):
            NSLog("[Grabbit] probe ok: presets=%d", media.presets.count)
            probed = media
            state = media.presets.isEmpty ? .failed : .ready
            if media.presets.isEmpty { errorMessage = "No downloadable formats found." }
        case .failure(let e):
            NSLog("[Grabbit] probe failed: %@", e.localizedDescription)
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
        // Extension captures carry a page title; a bare m3u8 URL would
        // otherwise be named after its playlist file ("master").
        let displayTitle = preferredTitle.flatMap { $0.isEmpty ? nil : $0 } ?? media.title

        let ytDlp: URL
        switch MediaRuntimeResolver.resolve(.ytDlp) {
        case .success(let u): ytDlp = u
        case .failure(let e):
            history.record(.media(
                name: displayTitle,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .failed,
                errorMessage: e.localizedDescription))
            fail(e.localizedDescription)
            return
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = Self.safeFilename(displayTitle)
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
        // Browser-captured request context (Referer/Cookie/User-Agent/…):
        // CDN-gated HLS/DASH URLs only answer when they look like the page.
        args += MediaProbe.headerArguments(probeHeaders)
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
                name: displayTitle,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .completed))
            notifyMediaComplete(name: displayTitle, directory: directory, title: safeTitle)
        } else {
            let detail = result.stderrTail.split(separator: "\n").last.map(String.init)
                ?? "yt-dlp exited with code \(result.exitCode)"
            history.record(.media(
                name: displayTitle,
                sourceURL: source.absoluteString,
                saveDirectory: directory,
                status: .failed,
                errorMessage: detail))
            notifyMediaFailure(name: displayTitle, message: detail)
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
        probeHeaders = [:]
        preferredTitle = nil
    }

    // MARK: - Helpers

    @MainActor
    private func fail(_ message: String) {
        state = .failed
        errorMessage = message
    }

    /// Completion card/notification for a finished yt-dlp download. `title`
    /// is the sanitized base name used for the output template; the finished
    /// file is matched by prefix so Open File lands on it.
    @MainActor
    private func notifyMediaComplete(name: String, directory: URL, title: String) {
        let file = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(title) }
        if settingsStore?.settings.notificationsEnabled ?? false {
            Notifier.downloadComplete(
                filename: file?.lastPathComponent ?? name,
                folder: directory.lastPathComponent)
        }
        if settingsStore?.settings.showCompletionToast ?? false {
            toastCenter?.push(AppToast(
                kind: .completed,
                source: .download,
                title: NSLocalizedString("toast.completed.title", comment: ""),
                message: file?.lastPathComponent ?? name,
                fileURL: file ?? directory))
        }
        if settingsStore?.settings.completionSoundEnabled ?? false {
            ToastCenter.playSound(for: .completed)
        }
    }

    @MainActor
    private func notifyMediaFailure(name: String, message: String) {
        if settingsStore?.settings.notificationsEnabled ?? false {
            Notifier.downloadFailed(filename: name, message: message)
        }
        if settingsStore?.settings.showCompletionToast ?? false {
            toastCenter?.push(AppToast(
                kind: .failed,
                source: .download,
                title: NSLocalizedString("toast.failed.title", comment: ""),
                message: name))
        }
        if settingsStore?.settings.completionSoundEnabled ?? false {
            ToastCenter.playSound(for: .failed)
        }
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
    /// captured by the browser extension. `headers` are the browser-captured
    /// request headers (Referer, Cookie, …) the CDN expects; `preferredName`
    /// is the page title, so files aren't named after the playlist ("master").
    public func downloadStream(
        url: URL,
        to directory: URL,
        headers: [String: String] = [:],
        preferredName: String? = nil
    ) async {
        NSLog("[Grabbit] downloadStream start: %@", url.absoluteString)
        await probe(url: url, headers: headers)
        NSLog("[Grabbit] downloadStream after probe: presets=%d", probed?.presets.count ?? -1)
        let trimmedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let media = probed, !media.presets.isEmpty else {
            // Extension-triggered downloads have no visible Media tab, so a
            // silent no-op looked like "nothing happened". Say it out loud.
            await notifyMediaFailure(
                name: (trimmedName?.isEmpty == false ? trimmedName! : url.lastPathComponent),
                message: errorMessage ?? NSLocalizedString("media.error.noFormats", comment: ""))
            return
        }
        // Name the file after the page when we have it.
        preferredTitle = (trimmedName?.isEmpty == false) ? trimmedName : nil
        // Prefer "Best" preset, fall back to first available.
        let preset = media.presets.first(where: { $0.label == "Best" })
            ?? media.presets[0]
        await download(preset: preset, to: directory)
    }
}
