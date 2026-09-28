import Foundation
import Observation

/// Per-host profiles (backlog #3): saved credentials, thread count, and
/// user-agent per host. `@Observable` without class-level `@MainActor`
/// (store convention); persisted to `hostprofiles.json` (atomic writes,
/// corrupt-file fallback).
@Observable
public final class HostProfileStore {
    public private(set) var profiles: [HostProfile] = []

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("hostprofiles.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data)
        {
            self.profiles = decoded
        }
    }

    /// First enabled profile whose host matches (suffix match).
    public func profile(for host: String?) -> HostProfile? {
        profiles.first { $0.matches(host: host) }
    }

    public func add(_ profile: HostProfile) {
        profiles.append(profile)
        save()
    }

    public func update(_ profile: HostProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
    }

    public func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(id: UUID, enabled: Bool) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].isEnabled = enabled
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
