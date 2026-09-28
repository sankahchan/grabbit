import Foundation
import Observation

/// LinkGrabber-style staging area (backlog #1): links wait here while they
/// are probed (online/offline + size) so the user can inspect, rename and
/// select before committing them as real downloads.
///
/// Persisted to `linkgrabber.json` (atomic writes, corrupt-file fallback),
/// following the WatchFolderStore pattern. The network probe and the commit
/// action are injectable so the pure staging logic is unit-testable.
///
/// Like the other stores, this is `@Observable` without class-level
/// `@MainActor` so views can read it synchronously; the probe task hops to
/// the main actor for its mutations, and the commit entry points are
/// individually `@MainActor`.
@Observable
public final class LinkGrabberStore {
    public typealias Prober = (URL) async -> DownloadEngine.LinkProbe
    public typealias Committer = (StagedLink) async -> Void

    public private(set) var packages: [LinkPackage] = []
    public private(set) var links: [StagedLink] = []

    private let fileURL: URL
    private var prober: Prober?
    private var committer: Committer?
    private weak var downloadEngine: DownloadEngine?
    private var probeTasks: [UUID: Task<Void, Never>] = [:]

    private struct Snapshot: Codable {
        var packages: [LinkPackage]
        var links: [StagedLink]
    }

    /// `directory`, `prober` and `committer` are test hooks; production uses
    /// the app-support dir, the download engine's probe, and
    /// `DownloadEngine.add` (wired via `configure(downloadEngine:)`).
    public init(directory: URL? = nil, prober: Prober? = nil, committer: Committer? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
        self.fileURL = base.appendingPathComponent("linkgrabber.json")
        self.prober = prober
        self.committer = committer
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            self.packages = snapshot.packages
            self.links = snapshot.links
            // Test path: a stub prober is ready now, so re-probe anything
            // left .checking. Production (prober == nil) leaves them alone —
            // configure(downloadEngine:) re-probes once the engine exists.
            // Probing here unconditionally would cement restored links as
            // .offline before the engine is even configured.
            if prober != nil {
                for link in self.links where link.status == .checking {
                    startProbe(for: link.id)
                }
            }
        }
    }

    /// Production wiring: dedup against active downloads, probe through the
    /// engine, commit via `DownloadEngine.add`.
    public func configure(downloadEngine: DownloadEngine) {
        self.downloadEngine = downloadEngine
        self.committer = { [weak downloadEngine] link in
            await downloadEngine?.add(
                url: link.url,
                filename: link.filenameCustomized ? link.filename : nil,
                sourcePageURL: link.sourcePageURL)
        }
        // Re-probe anything left in .checking (e.g. restored from disk).
        for link in links where link.status == .checking {
            startProbe(for: link.id)
        }
    }

    // MARK: - Staging

    /// Creates an empty package (the "New package" button flow).
    @discardableResult
    public func createPackage(name: String) -> LinkPackage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let package = LinkPackage(name: trimmed)
        packages.append(package)
        save()
        return package
    }

    /// Stages validated http(s) URLs into a new package and probes each one.
    /// `packageName` must be non-empty (callers localize the default).
    public func stage(urls: [URL], packageName: String, sourcePageURL: URL? = nil) {
        guard !urls.isEmpty, let package = createPackage(name: packageName) else { return }
        var seen = Set(links.map { $0.url.absoluteString })
        let engineURLs = Set((downloadEngine?.items ?? []).map { $0.url.absoluteString })
        for url in urls {
            let key = url.absoluteString
            if seen.contains(key) || engineURLs.contains(key) {
                links.append(StagedLink(
                    url: url,
                    filename: Self.displayName(for: url),
                    status: .duplicate,
                    packageID: package.id,
                    sourcePageURL: sourcePageURL,
                    selected: false))
                continue
            }
            seen.insert(key)
            let link = StagedLink(
                url: url,
                filename: Self.displayName(for: url),
                packageID: package.id,
                sourcePageURL: sourcePageURL)
            links.append(link)
            startProbe(for: link.id)
        }
        save()
    }

    public static func displayName(for url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host ?? url.absoluteString
    }

    private func probe(_ url: URL) async -> DownloadEngine.LinkProbe {
        if let prober { return await prober(url) }
        guard let downloadEngine else {
            return DownloadEngine.LinkProbe(online: false, totalBytes: nil, filename: nil)
        }
        return await downloadEngine.probeLink(url)
    }

    private func startProbe(for id: UUID) {
        probeTasks[id]?.cancel()
        // @MainActor: the mutations below must fire @Observable
        // notifications on the main thread; the network probe itself is
        // free to run anywhere.
        probeTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let index = self.links.firstIndex(where: { $0.id == id }) else { return }
            let url = self.links[index].url
            let result = await self.probe(url)
            guard !Task.isCancelled else { return }
            guard let index = self.links.firstIndex(where: { $0.id == id }) else { return }
            // A user rename that landed mid-probe wins over the probe name.
            if !self.links[index].filenameCustomized,
               let name = result.filename, !name.isEmpty
            {
                self.links[index].filename = name
            }
            self.links[index].totalBytes = result.totalBytes
            self.links[index].status = result.online ? .online : .offline
            self.probeTasks[id] = nil
            self.save()
        }
    }

    // MARK: - Commit

    /// Turns staged links into real downloads. Duplicates are never
    /// committed. Returns the committed IDs.
    @MainActor
    @discardableResult
    public func commit(ids: [UUID]) async -> [UUID] {
        guard let committer else { return [] }
        let wanted = Set(ids)
        let targets = links.filter { wanted.contains($0.id) && $0.status != .duplicate }
        for link in targets {
            await committer(link)
        }
        let committed = Set(targets.map(\.id))
        removeLinks(committed)
        return Array(committed)
    }

    @MainActor
    public func commitSelected() async -> [UUID] {
        await commit(ids: links.filter(\.selected).map(\.id))
    }

    @MainActor
    public func commitPackage(_ packageID: UUID) async -> [UUID] {
        await commit(ids: links.filter { $0.packageID == packageID }.map(\.id))
    }

    // MARK: - Editing

    public func remove(ids: [UUID]) {
        removeLinks(Set(ids))
    }

    private func removeLinks(_ condemned: Set<UUID>) {
        for id in condemned {
            probeTasks[id]?.cancel()
            probeTasks[id] = nil
        }
        links.removeAll { condemned.contains($0.id) }
        pruneEmptyPackages()
        save()
    }

    public func removePackage(_ packageID: UUID) {
        remove(ids: links.filter { $0.packageID == packageID }.map(\.id))
    }

    public func renamePackage(_ packageID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = packages.firstIndex(where: { $0.id == packageID })
        else { return }
        packages[index].name = trimmed
        save()
    }

    public func setFilename(_ filename: String, for id: UUID) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = links.firstIndex(where: { $0.id == id })
        else { return }
        links[index].filename = trimmed
        links[index].filenameCustomized = true
        save()
    }

    public func setSelected(_ selected: Bool, for id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].selected = selected
        save()
    }

    public func setAllSelected(_ selected: Bool, in packageID: UUID? = nil) {
        for i in links.indices {
            if let packageID, links[i].packageID != packageID { continue }
            // Duplicates stay unselected: committing them is always a no-op.
            if links[i].status == .duplicate, selected { continue }
            links[i].selected = selected
        }
        save()
    }

    private func pruneEmptyPackages() {
        let used = Set(links.map(\.packageID))
        packages.removeAll { !used.contains($0.id) }
    }

    // MARK: - Queries

    public func links(in packageID: UUID) -> [StagedLink] {
        links.filter { $0.packageID == packageID }.sorted { $0.addedAt < $1.addedAt }
    }

    public var stagedCount: Int { links.count }

    public var selectableCount: Int {
        links.filter { $0.selected && $0.status != .duplicate }.count
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = Snapshot(packages: packages, links: links)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
