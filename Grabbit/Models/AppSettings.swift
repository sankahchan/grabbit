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
public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case none
    case http
    case socks5
}

public struct AppSettings: Codable {
    public var language: AppLanguage = .system
    public var theme: ThemeMode = .system
    /// Visual skin (classic neo-brutalist or one of the modern themes).
    public var themeStyle: ThemeStyle = .classic
    public var speedLimitBytesPerSec: Int64 = 0 // 0 = unlimited
    public var clipboardMonitorEnabled = true
    public var autoResumeOnLaunch = false
    /// Completed downloads/torrents leave their lists automatically
    /// (the History tab keeps the permanent record).
    public var autoClearFinished = true
    /// Failed downloads/torrents also leave their lists automatically
    /// (the History tab keeps the record, with retry).
    public var autoClearFailed = true
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
    public var folders: [DownloadCategory: String] = [:]
    // Torrents (Phase 4).
    public var vpnKillSwitchEnabled = false
    /// Interface torrents are bound to when the kill-switch is on (e.g. "utun3").
    public var vpnInterfaceName = ""
    /// Refresh the public tracker list from ngosang/trackerslist at most
    /// once a day (Motrix-style). A failed/never refresh keeps the old list.
    public var autoUpdateTrackers = true
    /// aria2 multi-connection performance profile for torrents.
    public var torrentPerformanceProfile: Aria2PerformanceProfile = .balanced
    /// Minimum hours between tracker-list refreshes.
    public var trackerSyncHours = 24.0
    /// User-added Torznab indexers for the torrent search sheet.
    public var torznabIndexers: [TorznabIndexer] = []
    /// Start configured Jackett/Prowlarr servers with Grabbit.
    public var autoStartIndexers = true
    /// Floating notch/menu-bar drop zone with live progress.
    public var notchModeEnabled = true
    /// Cute system blips for Mochi's little animations.
    public var notchSoundsEnabled = true
    /// Hide the island while another notch app (boring.notch, NotchNook,
    /// notchy, …) is running — two islands stacked at top-center collide.
    public var notchHideWhenOtherApp = true
    /// Pill (floating capsule below the menu bar) or Notch (flush with the
    /// screen top, blacking out the menu-bar strip center) — Notchy-style.
    public var notchShape: NotchShape = .pill
    /// Scales the closed island (1.0 = design size).
    public var notchClosedScale: Double = 1.0
    /// Extra points added to the closed island's height (top-anchored).
    public var notchHeightAdjust: Int = 0
    /// Glass gradient + edge highlight; off = flat dark fill.
    public var notchGlassEnabled = true
    /// Panel opacity (0.8–1.0) — lower lets the desktop show through.
    public var notchTranslucency: Double = 0.97
    /// The state-colored glow along the bottom edge.
    public var notchAuraEnabled = true
    /// Replace the glass fill with a user-picked color.
    public var notchCustomFill = false
    /// Hex ("#RRGGBB") of the custom fill.
    public var notchFillColor = ""
    /// Spring flavor for open/close/hover morphs.
    public var notchAnimationStyle: NotchAnimationStyle = .snappy
    /// Animation speed multiplier (1 = normal).
    public var notchAnimationSpeed: Double = 1.0
    /// Expand the island when the pointer rests on it.
    public var notchExpandOnHover = true
    /// Seconds before the hover expansion starts.
    public var notchHoverDelay: Double = 0.1
    /// Seconds before an open menu folds after the pointer leaves.
    public var notchCollapseDelay: Double = 0.9
    /// Seconds before a parked-open menu closes (0 = never).
    public var notchIdleTimeout: Double = 0
    /// Live download progress on the island.
    public var notchShowProgress = true
    /// Live-activity peek when a download is added.
    public var notchShowAdded = true
    /// Transient popup when a download finishes.
    public var notchShowFinished = true
    /// Seconds transient popups (added / done / failed) stay up.
    public var notchTransientSeconds: Double = 2.5
    /// Exclude the island from screen captures (NSWindow.sharingType).
    public var notchHideFromCapture = false
    /// Show the time on the closed pill (no-notch displays).
    public var notchShowClock = false
    /// When the closed pill is on screen at all.
    public var notchVisibility: NotchVisibilityMode = .always
    /// How lively Mochi is (battery-friendly off).
    public var notchMochiLevel: NotchMochiLevel = .full
    /// Global hotkey (⌃⌘N) opens/closes the island.
    public var notchHotkeyEnabled = false
    /// Double-click (instead of single click) opens the Grabbit window.
    public var notchDoubleClickOpensApp = false
    /// Brightness of the glass's top edge highlight (0–1).
    public var notchEdgeHighlight: Double = 1.0
    /// Strength of the state-colored aura (0–1).
    public var notchAuraIntensity: Double = 1.0
    /// Separate multiplier for the closed pill's width (on top of scale).
    public var notchClosedWidth: Double = 1.0
    /// Corner roundness of the closed pill (1 = fully rounded).
    public var notchCornerScale: Double = 1.0
    /// Transient popup when a download fails.
    public var notchShowFailed = true
    /// Sound flavor for Mochi's moments.
    public var notchSoundPack: NotchSoundPack = .cute
    /// Hide the island in fullscreen apps.
    public var notchHideInFullscreen = false
    /// Bundle ids whose frontmost activation hides the island.
    public var notchHiddenApps: [String] = []
    /// "Hide for sharing": hidden until the user turns it back on.
    public var notchHiddenForSharing = false
    /// Which display carries the island.
    public var notchDisplayScope: NotchDisplayScope = .main
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
    // Media post-processing (yt-dlp).
    /// Embed title/artist metadata into finished media files.
    public var mediaEmbedMetadata = true
    /// Embed the video thumbnail as cover art.
    public var mediaEmbedThumbnail = true
    /// Keep chapter markers inside the container (video presets).
    public var mediaEmbedChapters = true
    /// Download and embed subtitles (video presets).
    public var mediaEmbedSubtitles = true
    /// Subtitle languages requested from yt-dlp (comma-separated patterns).
    public var mediaSubtitleLanguages = "en.*,my.*"
    /// Netscape cookies.txt used by yt-dlp for authenticated sites.
    /// Empty = none.
    public var cookiesFilePath = ""

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
        case language, theme, themeStyle, speedLimitBytesPerSec, clipboardMonitorEnabled
        case autoResumeOnLaunch, autoClearFinished, autoClearFailed, autoUpdateEnabled, notificationsEnabled
        case showCompletionToast, showFailureToast, completionSoundEnabled
        case autoExtractArchives, deleteArchiveAfterExtract
        case completionAction, completionCommand
        case defaultConnections, folders
        case vpnKillSwitchEnabled, vpnInterfaceName
        case autoUpdateTrackers, trackerSyncHours, torrentPerformanceProfile
        case torznabIndexers, autoStartIndexers, notchModeEnabled
        case notchSoundsEnabled
        case notchHideWhenOtherApp
        case notchShape, notchClosedScale, notchHeightAdjust
        case notchGlassEnabled, notchTranslucency, notchAuraEnabled
        case notchCustomFill, notchFillColor
        case notchAnimationStyle, notchAnimationSpeed
        case notchExpandOnHover, notchHoverDelay, notchCollapseDelay
        case notchIdleTimeout
        case notchShowProgress, notchShowAdded, notchShowFinished
        case notchTransientSeconds, notchHideFromCapture
        case notchShowClock, notchVisibility, notchMochiLevel
        case notchHotkeyEnabled, notchDoubleClickOpensApp
        case notchEdgeHighlight, notchAuraIntensity
        case notchClosedWidth, notchCornerScale, notchShowFailed
        case notchSoundPack, notchHideInFullscreen, notchHiddenApps
        case notchHiddenForSharing, notchDisplayScope
        case defaultSeedRatio, defaultSeedTimeMinutes
        case openAtLogin, keepWindowFrame, maxActiveTasks
        case runMode
        case proxyMode, proxyHost, proxyPort, proxyUsername, proxyPassword
        case mediaEmbedMetadata, mediaEmbedThumbnail, mediaEmbedChapters
        case mediaEmbedSubtitles, mediaSubtitleLanguages, cookiesFilePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        themeStyle = try c.decodeIfPresent(ThemeStyle.self, forKey: .themeStyle) ?? .classic
        speedLimitBytesPerSec = try c.decodeIfPresent(Int64.self, forKey: .speedLimitBytesPerSec) ?? 0
        clipboardMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitorEnabled) ?? true
        autoResumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? false
        autoClearFinished = try c.decodeIfPresent(Bool.self, forKey: .autoClearFinished) ?? true
        autoClearFailed = try c.decodeIfPresent(Bool.self, forKey: .autoClearFailed) ?? true
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
        trackerSyncHours = try c.decodeIfPresent(Double.self, forKey: .trackerSyncHours) ?? 24
        torznabIndexers = try c.decodeIfPresent([TorznabIndexer].self, forKey: .torznabIndexers) ?? []
        autoStartIndexers = try c.decodeIfPresent(Bool.self, forKey: .autoStartIndexers) ?? true
        notchModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchModeEnabled) ?? true
        notchSoundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchSoundsEnabled) ?? true
        notchHideWhenOtherApp = try c.decodeIfPresent(Bool.self, forKey: .notchHideWhenOtherApp) ?? true
        notchShape = try c.decodeIfPresent(NotchShape.self, forKey: .notchShape) ?? .pill
        notchClosedScale = try c.decodeIfPresent(Double.self, forKey: .notchClosedScale) ?? 1.0
        notchHeightAdjust = try c.decodeIfPresent(Int.self, forKey: .notchHeightAdjust) ?? 0
        notchGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchGlassEnabled) ?? true
        notchTranslucency = try c.decodeIfPresent(Double.self, forKey: .notchTranslucency) ?? 0.97
        notchAuraEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchAuraEnabled) ?? true
        notchCustomFill = try c.decodeIfPresent(Bool.self, forKey: .notchCustomFill) ?? false
        notchFillColor = try c.decodeIfPresent(String.self, forKey: .notchFillColor) ?? ""
        notchAnimationStyle = try c.decodeIfPresent(NotchAnimationStyle.self, forKey: .notchAnimationStyle) ?? .snappy
        notchAnimationSpeed = try c.decodeIfPresent(Double.self, forKey: .notchAnimationSpeed) ?? 1.0
        notchExpandOnHover = try c.decodeIfPresent(Bool.self, forKey: .notchExpandOnHover) ?? true
        notchHoverDelay = try c.decodeIfPresent(Double.self, forKey: .notchHoverDelay) ?? 0.1
        notchCollapseDelay = try c.decodeIfPresent(Double.self, forKey: .notchCollapseDelay) ?? 0.9
        notchIdleTimeout = try c.decodeIfPresent(Double.self, forKey: .notchIdleTimeout) ?? 0
        notchShowProgress = try c.decodeIfPresent(Bool.self, forKey: .notchShowProgress) ?? true
        notchShowAdded = try c.decodeIfPresent(Bool.self, forKey: .notchShowAdded) ?? true
        notchShowFinished = try c.decodeIfPresent(Bool.self, forKey: .notchShowFinished) ?? true
        notchTransientSeconds = try c.decodeIfPresent(Double.self, forKey: .notchTransientSeconds) ?? 2.5
        notchHideFromCapture = try c.decodeIfPresent(Bool.self, forKey: .notchHideFromCapture) ?? false
        notchShowClock = try c.decodeIfPresent(Bool.self, forKey: .notchShowClock) ?? false
        notchVisibility = try c.decodeIfPresent(NotchVisibilityMode.self, forKey: .notchVisibility) ?? .always
        notchMochiLevel = try c.decodeIfPresent(NotchMochiLevel.self, forKey: .notchMochiLevel) ?? .full
        notchHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchHotkeyEnabled) ?? false
        notchDoubleClickOpensApp = try c.decodeIfPresent(Bool.self, forKey: .notchDoubleClickOpensApp) ?? false
        notchEdgeHighlight = try c.decodeIfPresent(Double.self, forKey: .notchEdgeHighlight) ?? 1.0
        notchAuraIntensity = try c.decodeIfPresent(Double.self, forKey: .notchAuraIntensity) ?? 1.0
        notchClosedWidth = try c.decodeIfPresent(Double.self, forKey: .notchClosedWidth) ?? 1.0
        notchCornerScale = try c.decodeIfPresent(Double.self, forKey: .notchCornerScale) ?? 1.0
        notchShowFailed = try c.decodeIfPresent(Bool.self, forKey: .notchShowFailed) ?? true
        notchSoundPack = try c.decodeIfPresent(NotchSoundPack.self, forKey: .notchSoundPack) ?? .cute
        notchHideInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .notchHideInFullscreen) ?? false
        notchHiddenApps = try c.decodeIfPresent([String].self, forKey: .notchHiddenApps) ?? []
        notchHiddenForSharing = try c.decodeIfPresent(Bool.self, forKey: .notchHiddenForSharing) ?? false
        notchDisplayScope = try c.decodeIfPresent(NotchDisplayScope.self, forKey: .notchDisplayScope) ?? .main
        torrentPerformanceProfile = try c.decodeIfPresent(Aria2PerformanceProfile.self, forKey: .torrentPerformanceProfile) ?? .balanced
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
        mediaEmbedMetadata = try c.decodeIfPresent(Bool.self, forKey: .mediaEmbedMetadata) ?? true
        mediaEmbedThumbnail = try c.decodeIfPresent(Bool.self, forKey: .mediaEmbedThumbnail) ?? true
        mediaEmbedChapters = try c.decodeIfPresent(Bool.self, forKey: .mediaEmbedChapters) ?? true
        mediaEmbedSubtitles = try c.decodeIfPresent(Bool.self, forKey: .mediaEmbedSubtitles) ?? true
        mediaSubtitleLanguages = try c.decodeIfPresent(String.self, forKey: .mediaSubtitleLanguages) ?? "en.*,my.*"
        cookiesFilePath = try c.decodeIfPresent(String.self, forKey: .cookiesFilePath) ?? ""
    }
}

/// The island's closed shape: a floating pill or a flush fake-notch.
public enum NotchShape: String, Codable, CaseIterable, Sendable {
    case pill
    case notch
}

/// Spring flavors for the island's morphs.
public enum NotchAnimationStyle: String, Codable, CaseIterable, Sendable {
    case calm
    case snappy
    case bouncy
}

/// When the closed pill is on screen.
public enum NotchVisibilityMode: String, Codable, CaseIterable, Sendable {
    case always
    case activeOnly
    case hoverOnly
}

/// How lively Mochi's idle animation is.
public enum NotchMochiLevel: String, Codable, CaseIterable, Sendable {
    case full
    case subtle
    case off
}

/// Sound flavor for Mochi's moments.
public enum NotchSoundPack: String, Codable, CaseIterable, Sendable {
    case cute
    case subtle
    case off
}

/// Which display carries the island.
public enum NotchDisplayScope: String, Codable, CaseIterable, Sendable {
    case main
    case active
}

// MARK: - Reset

extension AppSettings {
    /// Restores every Notch & Pill setting to its default (the card's
    /// "Reset to Defaults" button). Nothing outside the card is touched.
    public mutating func resetNotchSettings() {
        notchModeEnabled = true
        notchShape = .pill
        notchClosedScale = 1.0
        notchHeightAdjust = 0
        notchClosedWidth = 1.0
        notchCornerScale = 1.0
        notchGlassEnabled = true
        notchTranslucency = 0.97
        notchAuraEnabled = true
        notchAuraIntensity = 1.0
        notchEdgeHighlight = 1.0
        notchCustomFill = false
        notchFillColor = ""
        notchAnimationStyle = .snappy
        notchAnimationSpeed = 1.0
        notchExpandOnHover = true
        notchHoverDelay = 0.1
        notchCollapseDelay = 0.9
        notchIdleTimeout = 0
        notchShowProgress = true
        notchShowAdded = true
        notchShowFinished = true
        notchShowFailed = true
        notchTransientSeconds = 2.5
        notchSoundsEnabled = true
        notchSoundPack = .cute
        notchHideWhenOtherApp = true
        notchHideFromCapture = false
        notchShowClock = false
        notchVisibility = .always
        notchMochiLevel = .full
        notchHotkeyEnabled = false
        notchDoubleClickOpensApp = false
        notchHideInFullscreen = false
        notchHiddenApps = []
        notchHiddenForSharing = false
        notchDisplayScope = .main
    }
}

@Observable
public final class SettingsStore {
    public var settings: AppSettings

    /// Keychain account holding the global proxy password.
    public static let proxyPasswordAccount = "proxy-password"

    static let userDefaultsKey = "com.sankahchan.grabbit.settings"

    /// Keychain account this instance reads/writes (the production one by
    /// default; tests inject an isolated account).
    private let keychainAccount: String
    /// True once the Keychain password state is definitively known
    /// (loaded, confirmed absent, or migrated). While false, `save()`
    /// never deletes the Keychain item — a transient Keychain error must
    /// not wipe a credential it never saw.
    private var proxyPasswordKeychainKnown = false

    public init(keychainAccount: String? = nil) {
        self.keychainAccount = keychainAccount ?? Self.proxyPasswordAccount
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        ThemeRuntime.current = settings.themeStyle
        migrateProxyPasswordToKeychain()
    }

    /// One-way migration: a plaintext password left in UserDefaults by
    /// older builds moves to the Keychain, and the in-memory working copy
    /// is repopulated from the Keychain. See `save()` for the guarantee:
    /// the UserDefaults copy is scrubbed only once the Keychain holds the
    /// secret — a Keychain failure keeps the old copy so the proxy keeps
    /// working, and the migration retries on the next launch.
    private func migrateProxyPasswordToKeychain() {
        // A plaintext password from an older build migrates regardless of
        // whether the proxy is currently configured — those builds persisted
        // it even for parked configs, and leaving it in UserDefaults would
        // violate the "secrets live in the Keychain" invariant.
        if !settings.proxyPassword.isEmpty {
            save() // moves it to the Keychain when possible; else keeps it
            return
        }
        // No password to migrate: only touch the Keychain when the user has
        // actually configured a proxy. Otherwise every fresh install prompts
        // for Keychain access on first launch, which looks like data
        // collection.
        guard settings.proxyMode != .none, !settings.proxyHost.isEmpty else {
            proxyPasswordKeychainKnown = true // nothing to load
            return
        }
        switch KeychainStore.load(account: keychainAccount) {
        case .success(let password):
            settings.proxyPassword = password
            proxyPasswordKeychainKnown = true
        case .failure(.notFound):
            proxyPasswordKeychainKnown = true // definitively no password
        case .failure:
            break // transient error: leave the working copy alone
        }
    }

    public func save() {
        var toPersist = settings
        if !settings.proxyPassword.isEmpty {
            if KeychainStore.save(
                settings.proxyPassword, account: keychainAccount)
            {
                // The Keychain holds the secret — it never touches
                // UserDefaults.
                toPersist.proxyPassword = ""
                proxyPasswordKeychainKnown = true
            } else {
                // Keychain failed: keep the plaintext fallback in
                // UserDefaults so the credential (and the proxy) survives;
                // the migration retries on a later save/launch.
                proxyPasswordKeychainKnown = false
            }
        } else if proxyPasswordKeychainKnown {
            // No password configured (or it was cleared): drop any stale
            // Keychain item. Skipped while the Keychain state is unknown —
            // never delete a credential we never saw.
            KeychainStore.delete(account: keychainAccount)
        }
        ThemeRuntime.current = settings.themeStyle
        if let data = try? JSONEncoder().encode(toPersist) {
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
