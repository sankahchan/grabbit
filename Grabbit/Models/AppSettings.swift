import Foundation
import Observation

public enum AppLanguage: String, Codable, CaseIterable {
    case system
    case en
    case my
}

public enum ThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

public struct AppSettings: Codable {
    public var language: AppLanguage = .system
    public var theme: ThemeMode = .system
    public var speedLimitBytesPerSec: Int64 = 0 // 0 = unlimited
    public var clipboardMonitorEnabled = true
    public var autoResumeOnLaunch = false
    public var autoUpdateEnabled = true
    public var notificationsEnabled = true
    public var defaultConnections = 16
    public var folders: [DownloadCategory: String]
    // Torrents (Phase 4).
    public var vpnKillSwitchEnabled = false
    /// Interface torrents are bound to when the kill-switch is on (e.g. "utun3").
    public var vpnInterfaceName = ""
    /// 0 = seed forever.
    public var defaultSeedRatio: Double = 0
    /// Minutes; 0 = no time limit.
    public var defaultSeedTimeMinutes: Int = 0

    public static var `default`: AppSettings {
        AppSettings(folders: [
            .video: "~/Downloads/Grabbit/Video",
            .audio: "~/Downloads/Grabbit/Audio",
            .document: "~/Downloads/Grabbit/Documents",
            .other: "~/Downloads/Grabbit/Other",
        ])
    }
}

// Backward-compatible decoding: settings saved before the torrent fields
// existed still decode, with the new fields defaulted. Lives in an
// extension so the memberwise initializer is preserved.
extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case language, theme, speedLimitBytesPerSec, clipboardMonitorEnabled
        case autoResumeOnLaunch, autoUpdateEnabled, notificationsEnabled
        case defaultConnections, folders
        case vpnKillSwitchEnabled, vpnInterfaceName
        case defaultSeedRatio, defaultSeedTimeMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        speedLimitBytesPerSec = try c.decodeIfPresent(Int64.self, forKey: .speedLimitBytesPerSec) ?? 0
        clipboardMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitorEnabled) ?? true
        autoResumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? false
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        defaultConnections = try c.decodeIfPresent(Int.self, forKey: .defaultConnections) ?? 16
        folders = try c.decodeIfPresent([DownloadCategory: String].self, forKey: .folders) ?? [:]
        vpnKillSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .vpnKillSwitchEnabled) ?? false
        vpnInterfaceName = try c.decodeIfPresent(String.self, forKey: .vpnInterfaceName) ?? ""
        defaultSeedRatio = try c.decodeIfPresent(Double.self, forKey: .defaultSeedRatio) ?? 0
        defaultSeedTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultSeedTimeMinutes) ?? 0
    }
}

@Observable
public final class SettingsStore {
    public var settings: AppSettings

    private static let userDefaultsKey = "com.sankahchan.grabbit.settings"

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    /// Resolves the download folder for a category: expands `~`, falls back to
    /// `~/Downloads/Grabbit/Other` when unconfigured, and creates it on demand.
    /// If a *file* (or anything uncreatable) blocks the wanted path, falls
    /// back to `<name>-2`, `<name>-3`, … and logs the switch. Never returns
    /// a file path as a directory (aria2 fails those with "Not a directory").
    public func folderURL(for category: DownloadCategory) -> URL {
        let raw = settings.folders[category] ?? "~/Downloads/Grabbit/Other"
        let expanded = (raw as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: expanded, isDirectory: true)
        for attempt in 1..<100 {
            let candidate = attempt == 1
                ? base
                : base.deletingLastPathComponent().appendingPathComponent(
                    "\(base.lastPathComponent)-\(attempt)", isDirectory: true)
            try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            if Self.isExistingDirectory(candidate) {
                if candidate != base {
                    NSLog("[Grabbit] folderURL: %@ is blocked by a file; using fallback %@",
                          base.path, candidate.path)
                }
                return candidate
            }
        }
        return base
    }

    /// True when the URL exists and is really a directory. Never throws.
    public static func isExistingDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
