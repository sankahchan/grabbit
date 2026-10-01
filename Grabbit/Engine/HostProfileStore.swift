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
            var foundLegacyPlaintext = false
            self.profiles = decoded.map { profile in
                if !profile.password.isEmpty { foundLegacyPlaintext = true }
                return Self.adoptingKeychain(profile)
            }
            // Rewrite the file so migrated plaintext does not linger on disk.
            if foundLegacyPlaintext { save() }
        }
    }

    /// First enabled profile whose host matches (suffix match).
    public func profile(for host: String?) -> HostProfile? {
        profiles.first { $0.matches(host: host) }
    }

    public func add(_ profile: HostProfile) {
        profiles.append(Self.storingKeychain(profile))
        save()
    }

    public func update(_ profile: HostProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = Self.storingKeychain(profile)
        save()
    }

    public func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        KeychainStore.delete(account: HostProfile.keychainAccount(for: id))
        save()
    }

    public func setEnabled(id: UUID, enabled: Bool) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].isEnabled = enabled
        save()
    }

    // MARK: - Keychain-backed passwords

    /// Load path: migrates a legacy plaintext password into the Keychain, or
    /// repopulates an empty password from the Keychain. Never clears a
    /// credential when the Keychain errors (the flag keeps the fallback).
    private static func adoptingKeychain(_ profile: HostProfile) -> HostProfile {
        var p = profile
        let account = HostProfile.keychainAccount(for: p.id)
        if !p.password.isEmpty {
            p.passwordKeychainFailed = !KeychainStore.save(p.password, account: account)
        } else if case .success(let saved) = KeychainStore.load(account: account) {
            p.password = saved
        }
        return p
    }

    /// Write path (add/update): an empty password means the user cleared it,
    /// so the Keychain item is removed rather than re-populated.
    private static func storingKeychain(_ profile: HostProfile) -> HostProfile {
        var p = profile
        let account = HostProfile.keychainAccount(for: p.id)
        if p.password.isEmpty {
            KeychainStore.delete(account: account)
            p.passwordKeychainFailed = false
        } else {
            p.passwordKeychainFailed = !KeychainStore.save(p.password, account: account)
        }
        return p
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
