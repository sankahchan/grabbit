import Foundation

/// Locates the aria2-next torrent daemon binary.
///
/// Resolution order (same pattern as `MediaRuntimeResolver`):
/// 1. Bundled app resources (`Contents/Resources/bin/aria2-next`)
/// 2. User copies (`~/Library/Application Support/Grabbit/bin/aria2-next`)
/// 3. Env-var override (`ARIA2_NEXT_PATH`)
/// 4. Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) — `aria2-next` first,
///    then upstream `aria2c` as a fallback (same JSON-RPC protocol)
/// 5. `PATH` lookup
///
/// Every failure produces a human-readable, localized install hint instead
/// of a bare "not found".
public enum TorrentRuntimeResolver {
    public static let binaryName = "aria2-next"
    /// Upstream aria2 speaks the same JSON-RPC; accepted as a fallback.
    public static let fallbackBinaryName = "aria2c"
    public static let envVar = "ARIA2_NEXT_PATH"

    public struct ResolutionError: Error, LocalizedError {
        public var errorDescription: String? {
            NSLocalizedString("torrents.runtime.hint", comment: "")
        }
    }

    /// Application Support override dir — checked before env/PATH so a
    /// user-placed binary wins.
    public static var userBinDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grabbit/bin", isDirectory: true)
    }

    public static func resolve() -> Result<URL, ResolutionError> {
        for candidate in searchOrder() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return .success(candidate)
            }
        }
        return .failure(ResolutionError())
    }

    private static func searchOrder() -> [URL] {
        var urls: [URL] = []
        // 1. Bundled resources.
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("bin/\(binaryName)"))
        }
        // 2. User copies.
        urls.append(userBinDirectory.appendingPathComponent(binaryName))
        // 3. Env-var override.
        if let override = ProcessInfo.processInfo.environment[envVar], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        // 4. Homebrew prefixes + 5. PATH — preferred name first, then fallback.
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        for name in [binaryName, fallbackBinaryName] {
            for dir in dirs {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if !urls.contains(url) { urls.append(url) }
            }
        }
        return urls
    }
}
