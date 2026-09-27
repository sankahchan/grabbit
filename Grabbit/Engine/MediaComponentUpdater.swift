import Foundation

/// Independent updater for the media helper binaries (XDM
/// `UpdateMode.YoutubeDLUpdateOnly` idea) — yt-dlp moves fast (sites break
/// weekly), so it updates on its own cadence instead of waiting for app
/// releases. Updated binaries land in `~/Library/Application Support/Grabbit/bin/`,
/// which `MediaRuntimeResolver` prefers over bundled/PATH copies.
public enum MediaComponentUpdater {
    public enum UpdateError: Error, LocalizedError {
        case network(String)
        case upToDate
        public var errorDescription: String? {
            switch self {
            case .network(let m): return m
            case .upToDate: return "Already up to date."
            }
        }
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private static let downloadBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

    /// Tag like "2026.09.27", or nil on network failure.
    public static func latestYtDlpTag() async -> String? {
        var request = URLRequest(url: apiURL)
        request.setValue("Grabbit", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return tag
    }

    /// Installed version via `yt-dlp --version` (e.g. "2026.09.27").
    public static func installedYtDlpVersion() -> String? {
        guard case .success(let bin) = MediaRuntimeResolver.resolve(.ytDlp) else { return nil }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = (try? pipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) }
        return out?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Downloads the latest `yt-dlp_macos` into the user bin dir and makes it
    /// executable. Throws `.upToDate` when the installed version already
    /// matches the latest tag.
    @discardableResult
    public static func updateYtDlp() async throws -> URL {
        if let latest = await latestYtDlpTag(),
           let installed = installedYtDlpVersion(),
           installed == latest
        {
            throw UpdateError.upToDate
        }
        let dir = MediaRuntimeResolver.userBinDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("yt-dlp")
        let tmp = dir.appendingPathComponent("yt-dlp.download")
        try? FileManager.default.removeItem(at: tmp)

        var request = URLRequest(url: URL(string: downloadBase)!)
        request.setValue("Grabbit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.network("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        // Atomic swap: never leave a half-written binary in place.
        if FileManager.default.fileExists(atPath: dest.path) {
            let backup = dir.appendingPathComponent("yt-dlp.bak")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: dest, to: backup)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                try? FileManager.default.removeItem(at: backup)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: dest)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
