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

/// How Grabbit presents itself: a normal Dock app, a menu-bar (tray)
/// app with live speed, or fully hidden (no Dock, no menu bar icon).
public enum RunMode: String, Codable, CaseIterable {
    case standard
    case tray
    case hidden
}

/// Custom proxy for Grabbit's own engines (native direct downloads +
/// aria2 torrents). `.none` = direct connection (the URLSession-based size
/// probe still honors the *system* proxy automatically).
public enum ProxyMode: String, Codable, CaseIterable {
    case none
    case http
    case socks5
}

public struct AppSettings: Codable {
    public var language: AppLanguage = .system
    public var theme: ThemeMode = .system
    public var speedLimitBytesPerSec: Int64 = 0 // 0 = unlimited
    public var clipboardMonitorEnabled = true
    public var autoResumeOnLaunch = false
    /// Completed downloads/torrents leave their lists automatically
    /// (the History tab keeps the permanent record).
    public var autoClearFinished = true
    public var autoUpdateEnabled = true
    public var notificationsEnabled = true
    /// In-app toast cards (bottom-right) on download completion / failure,
    /// with Open File / Open Folder / Try Again actions.
    public var showCompletionToast = true
    public var showFailureToast = true
    /// Subtle system alert sound alongside the toast cards.
    public var completionSoundEnabled = true
    /// Auto-extract zip/tar archives after download (system tools only).
    public var autoExtractArchives = true
    /// Move the archive to Trash after a successful extraction.
    public var deleteArchiveAfterExtract = false
    /// Action when every download/torrent has finished (or failed).
    public var completionAction: CompletionAction = .none
    /// Shell command for the `.runCommand` completion action.
    public var completionCommand = ""
    public var defaultConnections = 16
    public var folders: [DownloadCategory: String]
    // Torrents (Phase 4).
    public var vpnKillSwitchEnabled = false
    /// Interface torrents are bound to when the kill-switch is on (e.g. "utun3").
    public var vpnInterfaceName = ""
    /// Refresh the public tracker list from ngosang/trackerslist at most
    /// once a day (Motrix-style). A failed/never refresh keeps the old list.
    public var autoUpdateTrackers = true
    /// 0 = seed forever.
    public var defaultSeedRatio: Double = 0
    /// Minutes; 0 = no time limit.
    public var defaultSeedTimeMinutes: Int = 0
    // Basic card: startup + task management.
    public var openAtLogin = false
    public var keepWindowFrame = false
    /// Max simultaneously downloading tasks (downloads engine queue +
    /// aria2 max-concurrent-downloads). At least 1.
    public var maxActiveTasks: Int = 5
    /// Standard (Dock), tray (menu bar, no Dock), or hidden (neither).
    public var runMode: RunMode = .standard
    // Proxy (Phase 5): native engine + aria2.
    public var proxyMode: ProxyMode = .none
    public var proxyHost: String = ""
    /// 1–65535.
    public var proxyPort: Int = 8080
    public var proxyUsername: String = ""
    /// Stored in Grabbit's own settings file, like the rest of AppSettings.
    public var proxyPassword: String = ""

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
        case autoResumeOnLaunch, autoClearFinished, autoUpdateEnabled, notificationsEnabled
        case showCompletionToast, showFailureToast, completionSoundEnabled
        case autoExtractArchives, deleteArchiveAfterExtract
        case completionAction, completionCommand
        case defaultConnections, folders
        case vpnKillSwitchEnabled, vpnInterfaceName
        case autoUpdateTrackers
        case defaultSeedRatio, defaultSeedTimeMinutes
        case openAtLogin, keepWindowFrame, maxActiveTasks
        case runMode
        case proxyMode, proxyHost, proxyPort, proxyUsername, proxyPassword
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        speedLimitBytesPerSec = try c.decodeIfPresent(Int64.self, forKey: .speedLimitBytesPerSec) ?? 0
        clipboardMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitorEnabled) ?? true
        autoResumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? false
        autoClearFinished = try c.decodeIfPresent(Bool.self, forKey: .autoClearFinished) ?? true
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        showCompletionToast = try c.decodeIfPresent(Bool.self, forKey: .showCompletionToast) ?? true
        showFailureToast = try c.decodeIfPresent(Bool.self, forKey: .showFailureToast) ?? true
        completionSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .completionSoundEnabled) ?? true
        autoExtractArchives = try c.decodeIfPresent(Bool.self, forKey: .autoExtractArchives) ?? true
        deleteArchiveAfterExtract = try c.decodeIfPresent(Bool.self, forKey: .deleteArchiveAfterExtract) ?? false
        completionAction = try c.decodeIfPresent(CompletionAction.self, forKey: .completionAction) ?? .none
        completionCommand = try c.decodeIfPresent(String.self, forKey: .completionCommand) ?? ""
        defaultConnections = try c.decodeIfPresent(Int.self, forKey: .defaultConnections) ?? 16
        folders = try c.decodeIfPresent([DownloadCategory: String].self, forKey: .folders) ?? [:]
        vpnKillSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .vpnKillSwitchEnabled) ?? false
        vpnInterfaceName = try c.decodeIfPresent(String.self, forKey: .vpnInterfaceName) ?? ""
        autoUpdateTrackers = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateTrackers) ?? true
        defaultSeedRatio = try c.decodeIfPresent(Double.self, forKey: .defaultSeedRatio) ?? 0
        defaultSeedTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultSeedTimeMinutes) ?? 0
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false
        keepWindowFrame = try c.decodeIfPresent(Bool.self, forKey: .keepWindowFrame) ?? false
        maxActiveTasks = try c.decodeIfPresent(Int.self, forKey: .maxActiveTasks) ?? 5
        runMode = try c.decodeIfPresent(RunMode.self, forKey: .runMode) ?? .standard
        proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? .none
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8080
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        proxyPassword = try c.decodeIfPresent(String.self, forKey: .proxyPassword) ?? ""
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
