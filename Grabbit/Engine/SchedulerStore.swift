import Foundation
import Observation

/// Phase 5 scheduler backend: persisted schedule entries + a 1-minute
/// firing timer (the XDM `Scheduler` idea, kept dead simple).
///
/// The Scheduler tab UI shipped as a scaffold (@State entries, no
/// persistence, no triggers); this store is the real backend it now binds
/// to. Entries live as JSON at
/// `~/Library/Application Support/Grabbit/schedule.json` (atomic writes;
/// a corrupt file falls back to an empty schedule).
@Observable
public final class SchedulerStore {
    public private(set) var entries: [ScheduleEntry] = []

    private let fileURL: URL
    private var timer: Timer?

    /// `directory` is a test hook; production uses the app-support dir.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("schedule.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.entries = Self.load(from: fileURL)
    }

    // MARK: - Mutations

    public func add(_ entry: ScheduleEntry) {
        entries.append(entry)
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func update(_ entry: ScheduleEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        save()
    }

    // MARK: - Firing

    /// Starts the 1-minute timer; also checks immediately so an entry due
    /// in the launch minute isn't missed. Call once from the app layer.
    public func start(
        downloadEngine: DownloadEngine,
        torrentEngine: TorrentEngine,
        settings: SettingsStore
    ) {
        stop()
        fire(
            downloadEngine: downloadEngine, torrentEngine: torrentEngine,
            settings: settings, now: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fire(
                downloadEngine: downloadEngine, torrentEngine: torrentEngine,
                settings: settings, now: Date())
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fire(
        downloadEngine: DownloadEngine,
        torrentEngine: TorrentEngine,
        settings: SettingsStore,
        now: Date
    ) {
        var changed = false
        for i in entries.indices {
            guard Self.isDue(entries[i], now: now) else { continue }
            entries[i].lastFired = now
            changed = true
            let action = entries[i].action
            let speedLimit = entries[i].speedLimitBytesPerSec
            Task { @MainActor in
                switch action {
                case .download:
                    downloadEngine.startAllEligible()
                    torrentEngine.resumeAllEligible()
                case .stop:
                    downloadEngine.pauseAll()
                    torrentEngine.pauseAll()
                case .speedLimit:
                    // Backlog #8: off-peak profiles — push the cap into
                    // Settings (persisted), the live download bucket, and
                    // the torrent daemon (same as the Settings UI does).
                    settings.settings.speedLimitBytesPerSec = max(0, speedLimit)
                    settings.save()
                    downloadEngine.syncSpeedLimit()
                    await torrentEngine.applySpeedLimit()
                }
            }
        }
        if changed { save() }
    }

    /// Pure, unit-tested: is this entry due at `now`? The entry must be
    /// enabled, its weekday bitmask must include today, its hour+minute
    /// must match, and it must not have fired already today.
    static func isDue(_ entry: ScheduleEntry, now: Date, calendar: Calendar = .current) -> Bool {
        guard entry.isEnabled else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute
        else { return false }
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        guard entry.weekdays & (1 << (weekday - 1)) != 0 else { return false }
        let entryComps = calendar.dateComponents([.hour, .minute], from: entry.time)
        guard entryComps.hour == hour, entryComps.minute == minute else { return false }
        if let last = entry.lastFired, calendar.isDate(last, inSameDayAs: now) { return false }
        return true
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [ScheduleEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ScheduleEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
