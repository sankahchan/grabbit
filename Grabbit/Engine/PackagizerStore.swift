import Foundation
import Observation

/// Packagizer-style rules (backlog #4): regex URL match → rename template
/// and/or category override, applied automatically at add time.
/// `@Observable` without class-level `@MainActor` (store convention);
/// persisted to `packagizer.json` (atomic writes, corrupt-file fallback).
@Observable
public final class PackagizerStore {
    public private(set) var rules: [PackagizerRule] = []

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("packagizer.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PackagizerRule].self, from: data)
        {
            self.rules = decoded
        }
    }

    /// First enabled rule whose regex matches the URL.
    public func rule(for url: URL) -> PackagizerRule? {
        rules.first { $0.matches(url: url) }
    }

    public func add(_ rule: PackagizerRule) {
        rules.append(rule)
        save()
    }

    public func update(_ rule: PackagizerRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        save()
    }

    public func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(id: UUID, enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].isEnabled = enabled
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
