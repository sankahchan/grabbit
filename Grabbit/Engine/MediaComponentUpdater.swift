import Foundation
import CryptoKit

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
    private static let checksumsURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!

    /// Extracts the SHA-256 for `asset` from yt-dlp's `SHA2-256SUMS` file
    /// (`<hex>  <name>` lines; some entries carry a `*` binary marker).
    static func expectedHash(for asset: String, in checksums: String) -> String? {
        for line in checksums.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            var name = String(parts[1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name == asset { return String(parts[0]).lowercased() }
        }
        return nil
    }

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

        // The in-app updater has no other integrity check — verify the
        // binary against the release's published SHA-256 before swapping
        // it in. A checksum that cannot be fetched or does not match aborts
        // the update (the installed binary is left untouched).
        var sumsRequest = URLRequest(url: checksumsURL)
        sumsRequest.setValue("Grabbit", forHTTPHeaderField: "User-Agent")
        guard let (sumsData, sumsResponse) = try? await URLSession.shared.data(for: sumsRequest),
              let sumsHTTP = sumsResponse as? HTTPURLResponse,
              (200...299).contains(sumsHTTP.statusCode),
              let sums = String(data: sumsData, encoding: .utf8),
              let expected = expectedHash(for: "yt-dlp_macos", in: sums)
        else {
            throw UpdateError.network("Could not fetch the yt-dlp checksums — update aborted.")
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expected else {
            throw UpdateError.network("yt-dlp checksum mismatch — update aborted.")
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
