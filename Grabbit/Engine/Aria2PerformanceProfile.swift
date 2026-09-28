import Foundation

/// aria2 performance profiles (Motrix's `ENGINE_PERFORMANCE_PROFILES`).
/// These knobs govern multi-connection fetching (HTTP(S) seeds, webseeds)
/// inside the torrent daemon. Applied as launch args for fresh daemons and
/// pushed per-download via RPC when the user switches profile at runtime.
public enum Aria2PerformanceProfile: String, Codable, CaseIterable, Sendable {
    case balanced
    case high
    case maximum

    public var maxConnectionPerServer: Int {
        switch self {
        case .balanced: 16
        case .high: 32
        case .maximum: 64
        }
    }

    public var split: Int {
        switch self {
        case .balanced: 16
        case .high: 32
        case .maximum: 64
        }
    }

    /// aria2 K/M suffix form.
    public var minSplitSize: String {
        switch self {
        case .balanced: "10M"
        case .high: "4M"
        case .maximum: "1M"
        }
    }

    /// aria2 K/M suffix form.
    public var diskCache: String {
        switch self {
        case .balanced: "32M"
        case .high: "64M"
        case .maximum: "64M"
        }
    }

    /// Launch args for a fresh daemon.
    public var launchArgs: [String] {
        [
            "--max-connection-per-server=\(maxConnectionPerServer)",
            "--split=\(split)",
            "--min-split-size=\(minSplitSize)",
            "--disk-cache=\(diskCache)",
        ]
    }

    /// Global RPC options pushed via `aria2.changeGlobalOption` when the
    /// profile changes while the daemon is already running. `disk-cache`
    /// is global-only (aria2 rejects it per-download), and a profile is a
    /// daemon-wide engine setting — matching Motrix, which applies these
    /// as global engine config, not per-task.
    public var globalRpcOptions: [String: String] {
        [
            "max-connection-per-server": "\(maxConnectionPerServer)",
            "split": "\(split)",
            "min-split-size": minSplitSize,
            "disk-cache": diskCache,
        ]
    }

    public var localizedName: String {
        NSLocalizedString(
            "settings.torrents.profile.\(rawValue)", comment: "")
    }
}
