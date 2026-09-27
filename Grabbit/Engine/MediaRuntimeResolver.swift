import Foundation

/// Locates the media helper binaries (yt-dlp, ffmpeg, ffprobe, deno).
///
/// Resolution order (Harbor `MediaRuntimeResolver` idea):
/// 1. Bundled app resources (`Contents/Resources/bin/<name>`)
/// 2. User-updated copies (`~/Library/Application Support/Grabbit/bin/<name>`)
/// 3. Env-var override (`YTDLP_PATH`, `FFMPEG_PATH`, `FFPROBE_PATH`, `DENO_PATH`)
/// 4. Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`)
/// 5. `PATH` lookup
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
        public var errorDescription: String? {
            "Couldn't find \(component.rawValue). \(component.installHint)"
        }
    }

    /// Application Support override dir — where the component updater drops
    /// newer binaries. Checked before env/PATH so updates win.
    public static var userBinDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grabbit/bin", isDirectory: true)
    }

    public static func resolve(_ component: Component) -> Result<URL, ResolutionError> {
        for candidate in searchOrder(for: component) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return .success(candidate)
            }
        }
        return .failure(ResolutionError(component: component))
    }

    private static func searchOrder(for component: Component) -> [URL] {
        var urls: [URL] = []
        let name = component.rawValue
        // 1. Bundled resources.
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("bin/\(name)"))
        }
        // 2. User-updated copies (component updater).
        urls.append(userBinDirectory.appendingPathComponent(name))
        // 3. Env-var override.
        if let override = ProcessInfo.processInfo.environment[component.envVar],
           !override.isEmpty
        {
            urls.append(URL(fileURLWithPath: override))
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
