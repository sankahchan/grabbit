import Foundation

/// Automatic archive extraction using only macOS system tools
/// (`ditto` for zip, `tar` for tarballs) — no bundled binaries, no
/// license risk. rar/7z are deliberately out of scope for v1.
public enum ArchiveExtractor {
    public enum ArchiveError: Error, LocalizedError {
        case extractionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .extractionFailed(let detail):
                return detail.isEmpty
                    ? NSLocalizedString("toast.extractFailed.title", comment: "")
                    : detail
            }
        }
    }

    /// True for archive types we can extract with system tools.
    public static func isExtractableArchive(filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar") { return true }
        for suffix in [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz"] {
            if lower.hasSuffix(suffix) { return true }
        }
        return false
    }

    /// Sibling folder named after the archive: `/dl/app.zip` -> `/dl/app/`.
    /// Compound extensions are stripped (`app.tar.gz` -> `app`).
    public static func extractionDestination(for archiveURL: URL) -> URL {
        var name = archiveURL.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") {
            name = String(name.dropLast(4))
        }
        return archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Extracts the archive into its destination folder (created if needed).
    /// Blocks the calling thread — call off-main.
    @discardableResult
    public static func extract(archiveURL: URL) throws -> URL {
        let dest = extractionDestination(for: archiveURL)
        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true)
        let lower = archiveURL.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") {
            try run(
                "/usr/bin/ditto",
                ["-x", "-k", archiveURL.path, "--sequesterRsrc", dest.path])
        } else {
            // bsdtar auto-detects compression: .tar, .tar.gz/.tgz,
            // .tar.bz2/.tbz2, .tar.xz/.txz.
            try run("/usr/bin/tar", ["-xf", archiveURL.path, "-C", dest.path])
        }
        return dest
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let raw = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = (String(data: raw, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.extractionFailed(detail)
        }
    }
}
