import AppKit
import Foundation
import Observation

public protocol TorrentEngineProtocol: AnyObject {
    var torrents: [TorrentItem] { get }
    func add(magnetOrURL: String, savePath: URL) async throws
    func addTorrentFile(_ data: Data, savePath: URL, name: String?) async throws
    func pause(_ id: UUID)
    func resume(_ id: UUID)
    func remove(_ id: UUID, deleteData: Bool)
}

public enum TorrentError: Error, LocalizedError {
    case noBinary(String)
    case vpnBlocked(interface: String)
    case daemonFailed(String)
    case rpcFailed(String)
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .noBinary(let hint):
            return hint
        case .vpnBlocked(let interface):
            return String(format: String(localized: "torrents.error.vpnBlocked"), interface)
        case .daemonFailed(let message):
            return String(format: String(localized: "torrents.error.daemonFailed"), message)
        case .rpcFailed(let message):
            return String(format: String(localized: "torrents.error.rpcFailed"), message)
        case .invalidInput:
            return String(localized: "torrents.error.invalidInput")
        }
    }
}

/// Torrent downloads via an aria2-next daemon driven over JSON-RPC.
///
/// Lifecycle: `ensureStarted()` resolves the binary, reclaims or spawns the
/// daemon (see `Aria2Daemon`), applies global seeding options, then
/// reconciles the persisted torrent list with the daemon's live state. A
/// 1s poll loop maps `tellActive`/`tellWaiting`/`tellStopped` onto
/// `TorrentItem`s, migrating GIDs when magnets resolve (`followedBy`).
///
/// VPN kill-switch: while enabled and the configured interface is down, all
/// torrents are paused, the daemon is stopped, and `ensureStarted()` refuses
/// to start. When the interface returns, exactly the suspended set resumes.
@MainActor
@Observable
public final class TorrentEngine: TorrentEngineProtocol {
    public enum DaemonState: Equatable {
        case stopped
        case starting
        case running
        case suspendedVPN
        case failed(String)
    }

    public private(set) var torrents: [TorrentItem] = []
    public private(set) var daemonState: DaemonState = .stopped
    public var vpnHolding: Bool { daemonState == .suspendedVPN }

    private let settings: SettingsStore
    private let daemon = Aria2Daemon()
    private var rpc: Aria2RPC?
    private var lineage = GidLineage()
    private var pollTask: Task<Void, Never>?
    private var vpnTask: Task<Void, Never>?
    private var pollFailures = 0
    /// GIDs that were active when the VPN kill-switch suspended the engine.
    private var suspendedGids: [String] = []
    /// Items re-added this run after the daemon lost them (prevents loops).
    private var readdedThisRun = Set<UUID>()

    private static var storeURL: URL {
        Aria2Daemon.supportDir.appendingPathComponent("torrents.json")
    }

    public init(settings: SettingsStore) {
        self.settings = settings
        load()
        for item in torrents {
            if let gid = item.gid {
                lineage.register(gid: gid, item: item.id)
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Best-effort: ask the daemon to persist its session on quit.
            // torrents.json is saved on every mutation, so our own restore
            // never depends on this completing.
            Task { await self?.shutdown() }
        }
    }

    // MARK: - Startup

    /// Idempotent. Throws when the VPN kill-switch blocks, the binary is
    /// missing, or the daemon won't come up.
    public func ensureStarted() async throws {
        if rpc != nil { return }
        // The interface monitor must run even when the kill-switch blocks
        // startup: otherwise a relaunch-while-suspended leaves the engine in
        // .suspendedVPN with no watcher, and torrents stay paused forever
        // even after the user turns the kill-switch off.
        startVPNMonitor()
        if vpnBlockedNow() {
            daemonState = .suspendedVPN
            throw TorrentError.vpnBlocked(interface: settings.settings.vpnInterfaceName)
        }
        daemonState = .starting
        let binary: URL
        switch TorrentRuntimeResolver.resolve() {
        case .success(let url):
            binary = url
        case .failure(let error):
            daemonState = .failed(error.localizedDescription)
            throw TorrentError.noBinary(error.localizedDescription)
        }
        do {
            let (client, _) = try await daemon.start(
                binary: binary,
                downloadDir: settings.folderURL(for: .other),
                seedRatio: settings.settings.defaultSeedRatio,
                seedTimeMinutes: settings.settings.defaultSeedTimeMinutes,
                interfaceName: boundInterfaceName())
            rpc = client
            try? await client.changeGlobalOption([
                "seed-ratio": Self.ratioString(settings.settings.defaultSeedRatio),
                "seed-time": "\(settings.settings.defaultSeedTimeMinutes)",
            ])
            await reconcileAfterStart()
            daemonState = .running
            pollFailures = 0
            startPollLoop()
            // startVPNMonitor() already runs (started above, before the
            // kill-switch check, so it also watches while blocked).
        } catch {
            daemonState = .failed(error.localizedDescription)
            rpc = nil
            throw TorrentError.daemonFailed(error.localizedDescription)
        }
    }

    public func shutdown() async {
        pollTask?.cancel()
        pollTask = nil
        vpnTask?.cancel()
        vpnTask = nil
        await daemon.stop()
        rpc = nil
        if daemonState == .running || daemonState == .suspendedVPN {
            daemonState = .stopped
        }
        save()
    }

    // MARK: - Adding torrents

    /// Returns a usable download directory: the requested one when it really
    /// is a directory, otherwise a repaired fallback from Settings. Never
    /// returns a file path (aria2 fails those with "Not a directory").
    func resolvedSaveDir(_ url: URL) -> URL {
        if SettingsStore.isExistingDirectory(url) { return url }
        NSLog("[Grabbit] TorrentEngine: save path %@ is not a directory; re-resolving", url.path)
        return settings.folderURL(for: .other)
    }

    public func add(magnetOrURL: String, savePath: URL) async throws {
        let input = magnetOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw TorrentError.invalidInput }
        let dir = resolvedSaveDir(savePath)
        // A .torrent file URL: fetch the bytes first, then addTorrent.
        if input.lowercased().hasSuffix(".torrent"),
           let url = URL(string: input),
           url.scheme?.lowercased().hasPrefix("http") == true
        {
            let (data, _) = try await URLSession.shared.data(from: url)
            try await addTorrentFile(data, savePath: dir, name: url.lastPathComponent)
            return
        }
        try await ensureStarted()
        guard let rpc else { throw TorrentError.daemonFailed("RPC not connected") }

        let isMagnet = MagnetParser.isMagnet(input)
        let name = isMagnet
            ? (MagnetParser.displayName(for: input) ?? input)
            : (URL(string: input)?.lastPathComponent.isEmpty == false
                ? URL(string: input)!.lastPathComponent : input)
        let item = TorrentItem(
            name: name,
            magnetURI: isMagnet ? input : "",
            sourceURI: input,
            infoHash: isMagnet ? MagnetParser.infoHash(from: input) : nil,
            state: .downloading,
            savePath: dir)
        // Persist before the RPC call (cross-cutting crash-recovery rule):
        // a lost response retries by GID/info-hash lookup, never double-adds.
        torrents.append(item)
        save()
        do {
            let gid = try await rpc.addUri([input], options: addOptions(dir: dir))
            setGid(item.id, gid: gid)
            lineage.register(gid: gid, item: item.id)
        } catch {
            markFailed(item.id, message: error.localizedDescription)
            throw TorrentError.rpcFailed(error.localizedDescription)
        }
    }

    public func addTorrentFile(_ data: Data, savePath: URL, name: String? = nil) async throws {
        guard !data.isEmpty else { throw TorrentError.invalidInput }
        let dir = resolvedSaveDir(savePath)
        try await ensureStarted()
        guard let rpc else { throw TorrentError.daemonFailed("RPC not connected") }

        var item = TorrentItem(
            name: name ?? "torrent",
            magnetURI: "",
            sourceURI: "",
            state: .downloading,
            savePath: dir)
        if data.count < 2_000_000 {
            item.torrentFileBase64 = data.base64EncodedString()
        }
        torrents.append(item)
        save()
        do {
            let gid = try await rpc.addTorrent(data.base64EncodedString(), options: addOptions(dir: dir))
            setGid(item.id, gid: gid)
            lineage.register(gid: gid, item: item.id)
        } catch {
            markFailed(item.id, message: error.localizedDescription)
            throw TorrentError.rpcFailed(error.localizedDescription)
        }
    }

    // MARK: - Controls

    public func pause(_ id: UUID) {
        setLocalState(id, .paused)
        guard let gid = torrents.first(where: { $0.id == id })?.gid,
              let rpc
        else { return }
        Task { try? await rpc.pause(gid: gid) }
    }

    public func resume(_ id: UUID) {
        // While the kill-switch holds, nothing may start.
        guard !vpnHolding else { return }
        setLocalState(id, .downloading)
        Task {
            try? await self.ensureStarted()
            guard let gid = self.torrents.first(where: { $0.id == id })?.gid,
                  let rpc = self.rpc
            else { return }
            try? await rpc.unpause(gid: gid)
        }
    }

    /// Retries a failed torrent: purges the dead daemon entry and re-adds
    /// from the original source (magnet / URL / .torrent bytes). Files
    /// already on disk are hash-checked by aria2, so completed pieces are
    /// kept. No-op unless the item is currently `.failed`.
    public func retry(_ id: UUID) {
        guard let index = torrents.firstIndex(where: { $0.id == id }),
              torrents[index].state == .failed else { return }
        torrents[index].state = .downloading
        torrents[index].errorMessage = nil
        save()
        Task {
            try? await self.ensureStarted()
            guard let rpc = self.rpc,
                  let item = self.torrents.first(where: { $0.id == id })
            else { return }
            // Drop the errored daemon download first: re-adding while it
            // lingers would dedup back onto the dead entry.
            if let gid = item.gid {
                try? await rpc.removeDownloadResult(gid: gid)
            }
            await self.readd(item)
        }
    }

    public func remove(_ id: UUID, deleteData: Bool) {
        guard let item = torrents.first(where: { $0.id == id }) else { return }
        if let gid = item.gid, let rpc {
            if deleteData {
                Task { await self.deleteData(gid: gid, saveDir: item.savePath) }
            }
            Task { try? await rpc.remove(gid: gid) }
        } else if deleteData {
            // No daemon entry — best effort on the save dir's top-level file.
            try? FileManager.default.removeItem(at: item.savePath)
        }
        lineage.forgetItem(id)
        torrents.removeAll { $0.id == id }
        save()
    }

    // MARK: - Files & seeding

    public func fetchFiles(_ id: UUID) async throws -> [Aria2File] {
        try await ensureStarted()
        guard let gid = torrents.first(where: { $0.id == id })?.gid,
              let rpc
        else { throw TorrentError.invalidInput }
        return try await rpc.getFiles(gid: gid)
    }

    /// Applies a 1-based file selection via `select-file`.
    public func setFileSelection(_ id: UUID, indices: [Int]) async throws {
        try await ensureStarted()
        guard let gid = torrents.first(where: { $0.id == id })?.gid,
              let rpc
        else { throw TorrentError.invalidInput }
        let value = indices.sorted().map(String.init).joined(separator: ",")
        try await rpc.changeOption(gid: gid, options: ["select-file": value])
    }

    /// Per-torrent seeding limits. nil = fall back to the global defaults.
    public func setSeeding(_ id: UUID, ratio: Double?, timeMinutes: Int?) async throws {
        if let index = torrents.firstIndex(where: { $0.id == id }) {
            torrents[index].seedRatio = ratio
            torrents[index].seedTimeMinutes = timeMinutes
            save()
        }
        guard let gid = torrents.first(where: { $0.id == id })?.gid else { return }
        try await ensureStarted()
        guard let rpc else { return }
        var options: [String: String] = [:]
        options["seed-ratio"] = Self.ratioString(ratio ?? settings.settings.defaultSeedRatio)
        options["seed-time"] = "\(timeMinutes ?? settings.settings.defaultSeedTimeMinutes)"
        try await rpc.changeOption(gid: gid, options: options)
    }

    // MARK: - Poll loop

    private func startPollLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        // `client` (not `rpc`) — the poll loop may nil out the property
        // after repeated failures, which the shadowed name would forbid.
        guard let client = rpc else { return }
        do {
            let active = try await client.tellActive()
            let waiting = try await client.tellWaiting()
            let stopped = try await client.tellStopped()
            pollFailures = 0

            var byGid: [String: TorrentStatus] = [:]
            var byInfoHash: [String: TorrentStatus] = [:]
            for status in active + waiting + stopped {
                byGid[status.gid] = status
                if let hash = status.infoHash {
                    byInfoHash[hash.lowercased()] = status
                }
            }

            var changed = false
            var toDrop: [UUID] = []
            for index in torrents.indices {
                var item = torrents[index]
                var status = item.gid.flatMap { byGid[$0] }
                // GID unknown (daemon restarted, manifest reclaimed): match
                // by info hash and adopt the new GID.
                if status == nil,
                   let hash = item.infoHash?.lowercased(),
                   let found = byInfoHash[hash]
                {
                    status = found
                    if let old = item.gid { lineage.forget(gid: old) }
                    item.gid = found.gid
                    lineage.register(gid: found.gid, item: item.id)
                    changed = true
                }
                guard let st = status else {
                    // Unknown to the daemon — re-add once per run (the
                    // session file may be stale), then leave it alone.
                    if item.state == .downloading || item.state == .seeding,
                       !readdedThisRun.contains(item.id)
                    {
                        readdedThisRun.insert(item.id)
                        await readd(item)
                    }
                    continue
                }
                // Magnet metadata continuation: the daemon retired this GID
                // and the real download continues under followedBy.
                if let next = st.followedBy.first, next != item.gid {
                    lineage.migrate(from: item.gid ?? "", to: next)
                    item.gid = next
                    torrents[index] = item
                    changed = true
                    continue // fresh status arrives on the next poll
                }
                if st.status == "removed" {
                    toDrop.append(item.id)
                    changed = true
                    continue
                }
                if let name = st.name, !name.isEmpty, item.name != name {
                    item.name = name
                    changed = true
                }
                if let hash = st.infoHash, item.infoHash == nil {
                    item.infoHash = hash.lowercased()
                    changed = true
                }
                item.totalBytes = st.totalLength
                item.downloadedBytes = st.completedLength
                item.uploadedBytes = st.uploadLength
                item.downloadSpeed = st.downloadSpeed
                item.uploadSpeed = st.uploadSpeed
                item.numSeeders = st.numSeeders
                item.connections = st.connections
                item.seeds = st.numSeeders
                item.peers = st.connections
                if st.totalLength > 0 {
                    item.ratio = Double(st.uploadLength) / Double(st.totalLength)
                }
                let newState = Aria2StatusMapper.map(st)
                if item.state != newState {
                    item.state = newState
                    changed = true
                }
                if st.status == "error" {
                    let message = st.errorDisplay
                    if item.errorMessage != message {
                        item.errorMessage = message
                        changed = true
                    }
                } else if item.errorMessage != nil {
                    item.errorMessage = nil
                    changed = true
                }
                torrents[index] = item
            }
            for id in toDrop {
                lineage.forgetItem(id)
                torrents.removeAll { $0.id == id }
            }
            if changed { save() }
        } catch {
            pollFailures += 1
            if pollFailures >= 5 {
                pollTask?.cancel()
                pollTask = nil
                rpc = nil
                daemonState = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-adds a torrent the daemon lost (stale session). aria2 dedups by
    /// info hash, so this is idempotent — a duplicate add resolves to the
    /// existing download instead of double-adding.
    private func readd(_ item: TorrentItem) async {
        guard let rpc else { return }
        do {
            if !item.sourceURI.isEmpty {
                let gid = try await rpc.addUri([item.sourceURI], options: addOptions(dir: item.savePath))
                setGid(item.id, gid: gid)
                lineage.register(gid: gid, item: item.id)
            } else if let base64 = item.torrentFileBase64 {
                let gid = try await rpc.addTorrent(base64, options: addOptions(dir: item.savePath))
                setGid(item.id, gid: gid)
                lineage.register(gid: gid, item: item.id)
            }
        } catch {
            // Leave the item for the next poll / manual retry.
        }
    }

    private func reconcileAfterStart() async {
        guard let rpc else { return }
        // Adopt whatever the daemon restored from its session file, then let
        // the first poll fill in the details. Items the daemon doesn't know
        // are re-added lazily by the poll loop.
        let active = (try? await rpc.tellActive()) ?? []
        let waiting = (try? await rpc.tellWaiting()) ?? []
        var byInfoHash: [String: String] = [:] // infoHash -> gid
        for status in active + waiting {
            if let hash = status.infoHash {
                byInfoHash[hash.lowercased()] = status.gid
            }
        }
        var changed = false
        for index in torrents.indices {
            var item = torrents[index]
            if item.gid == nil,
               let hash = item.infoHash?.lowercased(),
               let gid = byInfoHash[hash]
            {
                item.gid = gid
                lineage.register(gid: gid, item: item.id)
                torrents[index] = item
                changed = true
            }
            // Paused-at-quit items stay paused: the daemon restores them as
            // paused only if the session recorded it; enforce our record.
            if item.state == .paused, let gid = item.gid {
                try? await rpc.pause(gid: gid)
            }
        }
        if changed { save() }
    }

    // MARK: - VPN kill-switch

    private func boundInterfaceName() -> String? {
        guard settings.settings.vpnKillSwitchEnabled else { return nil }
        let name = settings.settings.vpnInterfaceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func vpnBlockedNow() -> Bool {
        NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: settings.settings.vpnKillSwitchEnabled,
            interfaceName: settings.settings.vpnInterfaceName,
            upNames: NetworkInterfaceMonitor.upInterfaceNames())
    }

    private func startVPNMonitor() {
        vpnTask?.cancel()
        vpnTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.vpnCheck()
            }
        }
    }

    private func vpnCheck() async {
        switch (vpnBlockedNow(), daemonState) {
        case (true, .running):
            await suspendForVPN()
        case (false, .suspendedVPN):
            await resumeFromVPN()
        default:
            break
        }
    }

    private func suspendForVPN() async {
        if let rpc {
            suspendedGids = torrents
                .filter { $0.state == .downloading || $0.state == .seeding }
                .compactMap { $0.gid }
            for gid in suspendedGids {
                try? await rpc.pause(gid: gid)
            }
        } else {
            suspendedGids = []
        }
        pollTask?.cancel()
        pollTask = nil
        await daemon.stop()
        rpc = nil
        daemonState = .suspendedVPN
    }

    private func resumeFromVPN() async {
        let toResume = suspendedGids
        suspendedGids = []
        do {
            try await ensureStarted()
            if let rpc {
                for gid in toResume {
                    try? await rpc.unpause(gid: gid)
                }
            }
        } catch {
            // ensureStarted already recorded the failure state.
        }
    }

    // MARK: - Helpers

    private func addOptions(dir: URL) -> [String: String] {
        [
            "dir": dir.path,
            "seed-ratio": Self.ratioString(settings.settings.defaultSeedRatio),
            "seed-time": "\(settings.settings.defaultSeedTimeMinutes)",
        ]
    }

    static func ratioString(_ ratio: Double) -> String {
        String(format: "%.1f", ratio)
    }

    private func setGid(_ id: UUID, gid: String) {
        if let index = torrents.firstIndex(where: { $0.id == id }) {
            torrents[index].gid = gid
            save()
        }
    }

    private func setLocalState(_ id: UUID, _ state: TorrentState) {
        if let index = torrents.firstIndex(where: { $0.id == id }) {
            torrents[index].state = state
            save()
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        if let index = torrents.firstIndex(where: { $0.id == id }) {
            torrents[index].state = .failed
            torrents[index].errorMessage = message
            save()
        }
    }

    /// Deletes downloaded files, staying strictly inside the torrent dir.
    private func deleteData(gid: String, saveDir: URL) async {
        guard let rpc else { return }
        let dir = saveDir.standardizedFileURL
        guard let files = try? await rpc.getFiles(gid: gid) else { return }
        for file in files {
            let url = URL(fileURLWithPath: file.path).standardizedFileURL
            guard url.path.hasPrefix(dir.path + "/") || url.path == dir.path else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        // Remove newly-emptied parent dirs, up to (not including) saveDir.
        // A non-empty dir fails silently and is left alone.
        var queue = files.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.deletingLastPathComponent().path
        }
        var seen = Set<String>()
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            guard !seen.contains(parent),
                  parent.hasPrefix(dir.path),
                  parent != dir.path
            else { continue }
            seen.insert(parent)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: parent))
            queue.append(URL(fileURLWithPath: parent).deletingLastPathComponent().path)
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(torrents) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let items = try? JSONDecoder().decode([TorrentItem].self, from: data)
        else { return }
        torrents = items
    }
}
