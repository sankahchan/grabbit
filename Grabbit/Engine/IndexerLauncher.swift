import AppKit
import Foundation

/// Set-and-forget indexer servers: when Grabbit launches and a previously
/// configured Jackett/Prowlarr isn't running, start it quietly in the
/// background. Toggle: Settings → Torrents → Torznab indexers →
/// "Start with Grabbit". Servers that were never configured (no config
/// file) are never launched.
@MainActor
enum IndexerLauncher {
    /// Retains the Jackett child process so ARC can't reclaim it while
    /// the server runs (the process outlives Grabbit by design).
    private static var jackettProcess: Process?

    static func autoStartIfNeeded(enabled: Bool) {
        guard enabled else { return }
        Task { await startMissingServers() }
    }

    private static func startMissingServers() async {
        if let config = TorznabDiscovery.jackettConfig(),
           !(await TorznabDiscovery.isReachable(port: config.port)),
           let binary = jackettBinary()
        {
            launchJackett(binary: binary)
        }

        if let config = TorznabDiscovery.prowlarrConfig(),
           !(await TorznabDiscovery.isReachable(port: config.port)),
           let app = prowlarrApp()
        {
            launchProwlarr(app: app)
        }
    }

    // MARK: - Jackett (CLI binary)

    private static func jackettBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Applications/Jackett/Jackett"),
            URL(fileURLWithPath: "/Applications/Jackett/Jackett"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func launchJackett(binary: URL) {
        let process = Process()
        process.executableURL = binary
        // Jackett resolves its Content folder relative to the working dir.
        process.currentDirectoryURL = binary.deletingLastPathComponent()

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jackett.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
            jackettProcess = process
        } catch {
            NSLog("[Grabbit] Jackett auto-start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Prowlarr (.app bundle)

    private static func prowlarrApp() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Applications/Prowlarr.app"),
            URL(fileURLWithPath: "/Applications/Prowlarr.app"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func launchProwlarr(app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        // Server app: never steal focus from what the user is doing.
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
