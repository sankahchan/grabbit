import Foundation
import Darwin

/// Owns the aria2-next child process and its JSON-RPC endpoint.
///
/// Daemon ownership manifest (Harbor idea): a versioned plist at
/// `~/Library/Application Support/Grabbit/aria2-daemon.plist` recording the
/// pid, binary path, RPC port, a random start signature, and the RPC secret.
/// On launch we reclaim a live daemon we own (same binary + working RPC
/// secret), kill a stale/foreign record, or start fresh — never leaking
/// orphans and never colliding on the port.
///
/// The daemon only listens on loopback (`--rpc-listen-all=false`); the
/// secret is random per start and the manifest is chmod 600.
public final class Aria2Daemon {
    // MARK: - Manifest

    public struct Manifest: Codable, Equatable {
        public var version: Int = 1
        public var pid: Int32
        public var binaryPath: String
        public var rpcPort: UInt16
        public var secret: String
        public var signature: String
        public var startedAt: Date

        public init(
            pid: Int32,
            binaryPath: String,
            rpcPort: UInt16,
            secret: String,
            signature: String = UUID().uuidString,
            startedAt: Date = Date()
        ) {
            self.pid = pid
            self.binaryPath = binaryPath
            self.rpcPort = rpcPort
            self.secret = secret
            self.signature = signature
            self.startedAt = startedAt
        }
    }

    public enum ReclaimDecision: Equatable {
        /// The recorded daemon is alive, is our binary, and will be verified
        /// via RPC before use.
        case reclaim(Manifest)
        /// Something is alive under the recorded pid but it isn't our binary
        /// (or the RPC secret doesn't work) — terminate it, then start fresh.
        case killStale(pid: Int32)
        case startFresh
    }

    public enum DaemonError: Error, LocalizedError, Equatable {
        case spawnFailed(String)
        case notReady(String)

        public var errorDescription: String? {
            switch self {
            case .spawnFailed(let m): return "Couldn't start the torrent engine: \(m)"
            case .notReady(let m): return m
            }
        }
    }

    // MARK: - Paths

    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grabbit", isDirectory: true)
    }

    /// aria2 session file, DHT caches, and daemon log live here.
    public static var stateDir: URL {
        supportDir.appendingPathComponent("aria2", isDirectory: true)
    }

    public static var manifestURL: URL {
        supportDir.appendingPathComponent("aria2-daemon.plist")
    }

    // MARK: - State

    private var process: Process?
    public private(set) var manifest: Manifest?

    public init() {}

    // MARK: - Reclaim logic (pure — unit-tested)

    public static func decide(
        manifest: Manifest?,
        pidAlive: Bool,
        binaryPath: String
    ) -> ReclaimDecision {
        guard let manifest else { return .startFresh }
        guard pidAlive else { return .startFresh }
        if manifest.binaryPath == binaryPath {
            return .reclaim(manifest)
        }
        return .killStale(pid: manifest.pid)
    }

    public static func pidAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: - Start / stop

    /// Starts the daemon, reclaiming a live owned one when possible.
    /// Returns the connected RPC client and the active manifest.
    public func start(
        binary: URL,
        downloadDir: URL,
        seedRatio: Double,
        seedTimeMinutes: Int,
        interfaceName: String?,
        maxConcurrentDownloads: Int = 5,
        proxy: ProxyConfig = ProxyConfig(),
        performanceProfile: Aria2PerformanceProfile = .balanced
    ) async throws -> (rpc: Aria2RPC, manifest: Manifest) {
        try FileManager.default.createDirectory(at: Self.stateDir, withIntermediateDirectories: true)

        let stored = Self.loadManifest()
        switch Self.decide(
            manifest: stored,
            pidAlive: stored.map { Self.pidAlive($0.pid) } ?? false,
            binaryPath: binary.path)
        {
        case .reclaim(let m):
            // Prove it's really ours: the RPC secret must be accepted.
            let rpc = Aria2RPC(port: m.rpcPort, secret: m.secret)
            if (try? await rpc.listMethods()) != nil {
                self.manifest = m
                return (rpc, m)
            }
            await Self.terminate(pid: m.pid)
            // The manifest pid may be long gone while a foreign daemon
            // still listens on the port — evict the real holder too.
            await Self.killPortHolder(port: m.rpcPort)
        case .killStale(let pid):
            await Self.terminate(pid: pid)
            if let stored {
                await Self.killPortHolder(port: stored.rpcPort)
            }
        case .startFresh:
            break
        }
        return try await spawnFresh(
            binary: binary,
            downloadDir: downloadDir,
            seedRatio: seedRatio,
            seedTimeMinutes: seedTimeMinutes,
            interfaceName: interfaceName,
            maxConcurrentDownloads: maxConcurrentDownloads,
            proxy: proxy,
            performanceProfile: performanceProfile)
    }

    /// Asks the daemon to save its session and exit, SIGTERMs it if it
    /// lingers, SIGKILLs as a last resort. Clears the manifest.
    public func stop() async {
        if let proc = process {
            if let m = manifest {
                let rpc = Aria2RPC(port: m.rpcPort, secret: m.secret)
                // The daemon is dying; a transport error here is expected.
                try? await rpc.shutdown()
                let deadline = Date().addingTimeInterval(3)
                while proc.isRunning, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if proc.isRunning {
                await Self.terminate(pid: proc.processIdentifier)
            }
            process = nil
        } else if let m = manifest {
            // Reclaimed daemon (not our child) — shut it down via RPC so it
            // doesn't linger after we exit.
            let rpc = Aria2RPC(port: m.rpcPort, secret: m.secret)
            try? await rpc.shutdown()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Self.pidAlive(m.pid) {
                await Self.terminate(pid: m.pid)
            }
        }
        Self.clearManifest()
        manifest = nil
    }

    // MARK: - Spawning

    /// Public DHT bootstrap nodes. aria2 ships with no default entry
    /// points: on a fresh install (empty dht.dat) a node with no entry
    /// points can never join the DHT network, so magnet metadata never
    /// resolves and the torrent sits at 0 peers forever.
    public static let dhtEntryPoints = [
        "dht.transmissionbt.com:6881",
        "router.bittorrent.com:6881",
    ]

    /// `--dht-entry-point=` flags for the daemon command line. Pure — tested.
    public static func dhtArgs() -> [String] {
        dhtEntryPoints.map { "--dht-entry-point=\($0)" }
    }

    /// Default public BitTorrent trackers, announced to every torrent.
    /// aria2 has no built-in tracker list: a magnet whose own `tr` params
    /// are missing or dead only finds peers via DHT/LPD, so tracker-side
    /// seeds stay invisible (0 seeds while the site reports dozens).
    /// `--bt-tracker` adds these *in addition to* the torrent's own
    /// trackers. Sourced from ngosang/trackerslist `trackers_best`
    /// (20 trackers, refreshed 2026-09-26); a stale entry is harmless —
    /// aria2 just skips unreachable trackers.
    public static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.skynetcloud.site:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker.nyaa.vc:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://tracker.corpscorp.online:80/announce",
        "udp://tracker.bittor.pw:1337/announce",
        "udp://explodie.org:6969/announce",
        "udp://retracker01-msk-virt.corbina.net:80/announce",
        "udp://tracker-udp.gbitt.info:80/announce",
        "udp://tracker.ducks.party:1984/announce",
        "http://tracker.dler.com:6969/announce",
        "http://tracker2.dler.org:80/announce",
        "http://tracker.dler.org:6969/announce",
        "http://tracker.renfei.net:8080/announce",
        "udp://tracker.farted.net:6969/announce",
        "udp://tracker.peerfect.org:6969/announce",
    ]

    /// Comma-joined tracker list for `--bt-tracker` / RPC options.
    /// Prefers the auto-updated cache (`TrackerUpdater`), falling back to
    /// the compiled-in defaults when nothing was ever cached.
    public static var btTrackerList: String {
        TrackerUpdater.currentTrackerList
    }

    /// `--bt-tracker=` flag for the daemon command line. Pure — tested.
    public static func btTrackerArgs() -> [String] {
        ["--bt-tracker=\(btTrackerList)"]
    }

    private func spawnFresh(
        binary: URL,
        downloadDir: URL,
        seedRatio: Double,
        seedTimeMinutes: Int,
        interfaceName: String?,
        maxConcurrentDownloads: Int = 5,
        proxy: ProxyConfig = ProxyConfig(),
        performanceProfile: Aria2PerformanceProfile = .balanced
    ) async throws -> (rpc: Aria2RPC, manifest: Manifest) {
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let state = Self.stateDir.path
        // aria2 exits if --input-file doesn't exist, so touch it first.
        let sessionPath = "\(state)/session"
        if !FileManager.default.fileExists(atPath: sessionPath) {
            FileManager.default.createFile(atPath: sessionPath, contents: nil)
        }
        var args: [String] = [
            "--enable-rpc",
            "--rpc-listen-all=false",
            "--rpc-secret=\(secret)",
            "--dir=\(downloadDir.path)",
            // Session persistence: the daemon restores its own downloads
            // (magnets included, via bt-save-metadata) across restarts.
            "--save-session=\(sessionPath)",
            "--input-file=\(sessionPath)",
            "--save-session-interval=30",
            "--bt-save-metadata=true",
            "--bt-load-saved-metadata=true",
            "--dht-file-path=\(state)/dht.dat",
            "--dht-file-path6=\(state)/dht6.dat",
            "--enable-dht=true",
            "--bt-enable-lpd=true",
        ]
        args += Self.dhtArgs()
        args += Self.btTrackerArgs()
        args += [
            "--file-allocation=none",
            "--allow-overwrite=true",
            "--log-level=warn",
            "--log=\(state)/aria2.log",
            "--seed-ratio=\(String(format: "%.1f", seedRatio))",
            "--seed-time=\(seedTimeMinutes)",
            "--max-concurrent-downloads=\(max(1, maxConcurrentDownloads))",
        ]
        // Performance profile (balanced/high/maximum): separate appends keep
        // the type-checker fast — one long `+` chain times it out.
        args += performanceProfile.launchArgs
        args += proxy.aria2Arguments()
        if let interfaceName, !interfaceName.isEmpty {
            // VPN kill-switch: bind every socket to the VPN interface.
            args.append("--interface=\(interfaceName)")
        }

        var lastError: Error?
        for port in Self.candidatePorts() {
            if Self.portInUse(port) { continue }
            do {
                return try await launch(
                    binary: binary,
                    args: args + ["--rpc-listen-port=\(port)"],
                    port: port,
                    secret: secret)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DaemonError.spawnFailed("no free RPC port in 6800–6899")
    }

    private func launch(
        binary: URL,
        args: [String],
        port: UInt16,
        secret: String
    ) async throws -> (rpc: Aria2RPC, manifest: Manifest) {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw DaemonError.spawnFailed(error.localizedDescription)
        }
        process = proc

        let rpc = Aria2RPC(port: port, secret: secret)
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while Date() < deadline {
            if (try? await rpc.listMethods()) != nil {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready else {
            await Self.terminate(pid: proc.processIdentifier)
            process = nil
            throw DaemonError.notReady("torrent engine RPC did not come up on port \(port)")
        }

        let manifest = Manifest(
            pid: proc.processIdentifier,
            binaryPath: binary.path,
            rpcPort: port,
            secret: secret)
        Self.saveManifest(manifest)
        self.manifest = manifest
        return (rpc, manifest)
    }

    /// PIDs currently listening on a TCP port (via lsof). Used to evict a
    /// foreign daemon that holds a port but doesn't answer to our secret —
    /// e.g. a Debug build run from Xcode whose daemon outlived it while a
    /// stale manifest pointed elsewhere.
    static func listenerPIDs(port: UInt16) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Terminates whatever is actually listening on the port (never our own
    /// process).
    static func killPortHolder(port: UInt16) async {
        for pid in listenerPIDs(port: port) where pid != getpid() {
            await terminate(pid: pid)
        }
    }

    /// SIGTERM, 2s grace, then SIGKILL if still alive.
    static func terminate(pid: Int32) async {
        guard pidAlive(pid) else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if pidAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Manifest persistence

    static func loadManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? PropertyListDecoder().decode(Manifest.self, from: data)
    }

    static func saveManifest(_ manifest: Manifest) {
        guard let data = try? PropertyListEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
        // The manifest holds the RPC secret — owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    static func clearManifest() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    // MARK: - Ports

    static func candidatePorts() -> [UInt16] {
        Array(6800...6899)
    }

    /// True if something on loopback already accepts TCP on this port.
    static func portInUse(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Network interface monitor

/// VPN kill-switch support: checks whether a named interface (e.g. `utun3`)
/// currently exists and is up.
public enum NetworkInterfaceMonitor {
    /// Names of interfaces that are currently up, via getifaddrs.
    public static func upInterfaceNames() -> Set<String> {
        var names = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return names }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = current.pointee.ifa_flags
            if (flags & UInt32(IFF_UP)) != 0, let namePtr = current.pointee.ifa_name {
                names.insert(String(cString: namePtr))
            }
            cursor = current.pointee.ifa_next
        }
        return names
    }

    /// Pure kill-switch decision — unit-tested.
    public static func isBlocked(
        killSwitchEnabled: Bool,
        interfaceName: String,
        upNames: Set<String>
    ) -> Bool {
        guard killSwitchEnabled else { return false }
        let name = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return !upNames.contains(name)
    }
}
