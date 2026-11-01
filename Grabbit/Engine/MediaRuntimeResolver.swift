import Foundation

/// Locates the media helper binaries (yt-dlp, ffmpeg, ffprobe, deno).
///
/// Resolution order (Harbor `MediaRuntimeResolver` idea):
/// 1. Env-var override (`YTDLP_PATH`, `FFMPEG_PATH`, `FFPROBE_PATH`, `DENO_PATH`)
///    — explicit user intent wins.
/// 2. User-updated copies (`~/Library/Application Support/Grabbit/bin/<name>`)
///    — the component updater drops newer binaries here, so they must win
///    over the bundled copy or an in-app yt-dlp update is silently ignored.
/// 3. Bundled app resources (`Contents/Resources/bin/<name>`)
/// 4. Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`)
/// 5. `PATH` lookup
///
/// A candidate is only accepted if it actually runs (`<name> -version`, or
/// `--version` for yt-dlp). An architecture mismatch — an x86_64 helper on an
/// arm64 Mac without Rosetta — passes `isExecutableFile` but fails at `exec`,
/// which yt-dlp then reports as "ffmpeg not found". Skipping unrunnable
/// candidates lets a working Homebrew copy take over.
///
/// Every failure produces a human-readable install hint instead of a bare
/// "not found".
public enum MediaRuntimeResolver {
    public enum Component: String, CaseIterable {
        case ytDlp = "yt-dlp"
        case ffmpeg
        case ffprobe
        case deno

        /// Env var that overrides the lookup for this component.
        var envVar: String {
            switch self {
            case .ytDlp: "YTDLP_PATH"
            case .ffmpeg: "FFMPEG_PATH"
            case .ffprobe: "FFPROBE_PATH"
            case .deno: "DENO_PATH"
            }
        }

        /// Human-readable install hint shown when resolution fails.
        var installHint: String {
            switch self {
            case .ytDlp:
                "Install yt-dlp: brew install yt-dlp — or it ships inside Grabbit.app."
            case .ffmpeg:
                "Install ffmpeg: brew install ffmpeg — or it ships inside Grabbit.app."
            case .ffprobe:
                "Install ffprobe: brew install ffmpeg (ffprobe ships with it)."
            case .deno:
                "Install Deno (needed for YouTube's JS challenges): brew install deno."
            }
        }
    }

    public struct ResolutionError: Error, LocalizedError {
        public let component: Component
        /// First candidate that existed but could not execute (wrong
        /// architecture, missing dylib, …), if any.
        public let unrunnable: URL?

        public init(component: Component, unrunnable: URL? = nil) {
            self.component = component
            self.unrunnable = unrunnable
        }

        public var errorDescription: String? {
            if let unrunnable {
                return "Found \(component.rawValue) at \(unrunnable.path), but it can't run on this Mac. \(component.installHint)"
            }
            return "Couldn't find \(component.rawValue). \(component.installHint)"
        }
    }

    /// Application Support override dir — where the component updater drops
    /// newer binaries. Checked before the bundled copy so updates win.
    public static var userBinDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grabbit/bin", isDirectory: true)
    }

    public static func resolve(_ component: Component) -> Result<URL, ResolutionError> {
        var unrunnable: URL?
        for candidate in searchOrder(for: component) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                  !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate.path)
            else { continue }
            if isRunnable(candidate, component: component) {
                return .success(candidate)
            }
            if unrunnable == nil { unrunnable = candidate }
        }
        return .failure(ResolutionError(component: component, unrunnable: unrunnable))
    }

    // MARK: - Runnability

    /// Probe results keyed by path + size + mtime, so replacing a binary
    /// (the component updater, a Homebrew upgrade) invalidates its entry.
    private static let runnableCache = NSCache<NSString, NSNumber>()

    /// True when `url` can actually start on this machine. `isExecutableFile`
    /// is not enough: an x86_64 binary on arm64 without Rosetta is executable
    /// but `posix_spawn` fails with EBADARCH.
    static func isRunnable(_ url: URL, component: Component) -> Bool {
        let key = cacheKey(for: url) as NSString
        if let cached = runnableCache.object(forKey: key) {
            return cached.boolValue
        }
        let ok = probeRuns(url, arguments: versionArguments(for: component))
        runnableCache.setObject(NSNumber(value: ok), forKey: key)
        return ok
    }

    private static func cacheKey(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)"
    }

    private static func versionArguments(for component: Component) -> [String] {
        component == .ytDlp ? ["--version"] : ["-version"]
    }

    /// Spawns the helper and waits up to 3 s. A launch that exits 0 proves the
    /// kernel accepted its architecture and every linked dylib resolved.
    private static func probeRuns(_ url: URL, arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false // EBADARCH, ENOEXEC, missing dylib, …
        }
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
    }

    /// Candidate order; internal so tests can assert precedence.
    static func searchOrder(for component: Component) -> [URL] {
        var urls: [URL] = []
        let name = component.rawValue
        // 1. Env-var override — explicit user intent wins over everything.
        if let override = ProcessInfo.processInfo.environment[component.envVar],
           !override.isEmpty
        {
            urls.append(URL(fileURLWithPath: override))
        }
        // 2. User-updated copies (component updater). Newer than the bundle,
        //    so they must win — otherwise the in-app yt-dlp update is
        //    downloaded and silently ignored.
        urls.append(userBinDirectory.appendingPathComponent(name))
        // 3. Bundled resources.
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("bin/\(name)"))
        }
        // 4. Homebrew prefixes + 5. PATH.
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// Convenience: resolve yt-dlp + ffmpeg together (the common need).
    public static func resolveMediaPair() -> Result<(ytDlp: URL, ffmpeg: URL), ResolutionError> {
        switch (resolve(.ytDlp), resolve(.ffmpeg)) {
        case (.success(let y), .success(let f)): return .success((y, f))
        case (.failure(let e), _): return .failure(e)
        case (_, .failure(let e)): return .failure(e)
        }
    }
}
