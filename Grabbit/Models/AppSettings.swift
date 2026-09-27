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

    public static var `default`: AppSettings {
        AppSettings(folders: [
            .video: "~/Downloads/Grabbit/Video",
            .audio: "~/Downloads/Grabbit/Audio",
            .document: "~/Downloads/Grabbit/Documents",
            .other: "~/Downloads/Grabbit/Other",
        ])
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
    public func folderURL(for category: DownloadCategory) -> URL {
        let raw = settings.folders[category] ?? "~/Downloads/Grabbit/Other"
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
