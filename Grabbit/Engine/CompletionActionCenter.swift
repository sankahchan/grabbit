import AppKit
import Foundation
import Observation

/// What Grabbit does when every download/torrent has reached a terminal
/// state (completed or failed) and nothing is still downloading.
public enum CompletionAction: String, Codable, CaseIterable, Sendable, Equatable {
    case none
    case sleep
    case shutdown
    case quitGrabbit
    case runCommand

    public var localizationKey: String {
        switch self {
        case .none: "settings.completion.action.none"
        case .sleep: "settings.completion.action.sleep"
        case .shutdown: "settings.completion.action.shutdown"
        case .quitGrabbit: "settings.completion.action.quit"
        case .runCommand: "settings.completion.action.command"
        }
    }
}

/// Fires the configured `CompletionAction` when the queue drains.
/// `@Observable` without class-level `@MainActor` (store convention);
/// `taskDidSettle` hops to main when called off-main (torrent poll loop).
@Observable
public final class CompletionActionCenter {
    private let settings: SettingsStore
    private var activeTaskCount: () -> Int
    private let executor: (CompletionAction, String) -> Void
    /// Terminal settles since the last firing. Guards against firing on
    /// a fresh launch (no settles yet) or twice for one drain.
    private var settledSinceIdle = 0

    public init(
        settings: SettingsStore,
        activeTaskCount: @escaping () -> Int = { 0 },
        executor: @escaping (CompletionAction, String) -> Void = Self.execute
    ) {
        self.settings = settings
        self.activeTaskCount = activeTaskCount
        self.executor = executor
    }

    /// Production wiring: counts `.downloading` tasks across both engines.
    public func configure(downloads: DownloadEngine, torrents: TorrentEngine) {
        activeTaskCount = { [weak downloads, weak torrents] in
            let d = downloads?.items.filter { $0.state == .downloading }.count ?? 0
            let t = torrents?.torrents.filter { $0.state == .downloading }.count ?? 0
            return d + t
        }
    }

    /// Called whenever a download/torrent reaches a terminal state.
    public func taskDidSettle() {
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in self?.taskDidSettle() }
            return
        }
        settledSinceIdle += 1
        let action = settings.settings.completionAction
        guard action != .none else { return }
        // Only fire on a real drain: something settled AND nothing is
        // still running. Reset so one drain fires exactly once.
        guard activeTaskCount() == 0 else { return }
        settledSinceIdle = 0
        executor(action, settings.settings.completionCommand)
    }

    private static func execute(_ action: CompletionAction, command: String) {
        Task.detached {
            switch action {
            case .none:
                break
            case .sleep:
                run("/usr/bin/pmset", ["sleepnow"])
            case .shutdown:
                // First use prompts for Automation permission (System Events).
                run("/usr/bin/osascript", [
                    "-e", "tell application \"System Events\" to shut down",
                ])
            case .quitGrabbit:
                await MainActor.run { NSApp.terminate(nil) }
            case .runCommand:
                let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cmd.isEmpty else { return }
                run("/bin/sh", ["-c", cmd])
            }
        }
    }

    private static func run(_ launchPath: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try? process.run()
    }
}
