import XCTest
@testable import Grabbit

final class TorrentTests: XCTestCase {

    // MARK: - Aria2RPC.encodeCall

    func testEncodeCallPutsTokenFirst() throws {
        let data = try Aria2RPC.encodeCall(
            id: "test-id",
            method: "aria2.addUri",
            secret: "s3cr3t",
            params: [.array([.string("magnet:?xt=urn:btih:abc")])])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "test-id")
        XCTAssertEqual(json["method"] as? String, "aria2.addUri")
        let params = json["params"] as! [Any]
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0] as? String, "token:s3cr3t")
        XCTAssertEqual((params[1] as! [String]).first, "magnet:?xt=urn:btih:abc")
    }

    func testEncodeCallWithoutParams() throws {
        let data = try Aria2RPC.encodeCall(id: "1", method: "system.listMethods", secret: "x")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let params = json["params"] as! [Any]
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params[0] as? String, "token:x")
    }

    // MARK: - RPCResponse error decoding

    func testRPCErrorResponseDecodes() throws {
        let raw = #"{"id":"1","error":{"code":1,"message":"Unauthorized"}}"#
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.error?.code, 1)
        XCTAssertEqual(decoded.error?.message, "Unauthorized")
        XCTAssertNil(decoded.result)
    }

    // MARK: - TorrentStatus.parse

    private func sampleStatusJSON() throws -> JSONValue {
        let dict: [String: Any] = [
            "gid": "abc123",
            "status": "active",
            "totalLength": "1000",
            "completedLength": "250",
            "uploadLength": "100",
            "downloadSpeed": "50000",
            "uploadSpeed": "1000",
            "connections": "12",
            "numSeeders": "3",
            "dir": "/tmp/dl",
            "infoHash": "ABCDEF1234567890ABCDEF1234567890ABCDEF12",
            "followedBy": ["def456"],
            "bittorrent": ["info": ["name": "My Torrent"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testTorrentStatusParse() throws {
        let status = try XCTUnwrap(TorrentStatus.parse(sampleStatusJSON()))
        XCTAssertEqual(status.gid, "abc123")
        XCTAssertEqual(status.status, "active")
        XCTAssertEqual(status.totalLength, 1000)
        XCTAssertEqual(status.completedLength, 250)
        XCTAssertEqual(status.downloadSpeed, 50000)
        XCTAssertEqual(status.connections, 12)
        XCTAssertEqual(status.numSeeders, 3)
        XCTAssertEqual(status.dir, "/tmp/dl")
        XCTAssertEqual(status.name, "My Torrent")
        XCTAssertEqual(status.followedBy, ["def456"])
        XCTAssertNil(status.errorMessage)
    }

    func testTorrentStatusParseMissingGidFails() throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": "active"])
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertNil(TorrentStatus.parse(json))
    }

    func testTorrentStatusParseErrorFields() throws {
        let dict: [String: Any] = [
            "gid": "zzz", "status": "error",
            "errorCode": "24", "errorMessage": "HTTP 403",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let status = try XCTUnwrap(TorrentStatus.parse(json))
        XCTAssertEqual(status.errorCode, "24")
        XCTAssertEqual(status.errorMessage, "HTTP 403")
        XCTAssertTrue(status.followedBy.isEmpty)
    }

    // MARK: - Aria2File.parse

    func testAria2FileParse() throws {
        let dict: [String: Any] = [
            "index": "2", "path": "/tmp/dl/a/b.mkv",
            "length": "700000000", "completedLength": "100",
            "selected": "true",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let file = try XCTUnwrap(Aria2File.parse(json))
        XCTAssertEqual(file.index, 2)
        XCTAssertEqual(file.path, "/tmp/dl/a/b.mkv")
        XCTAssertEqual(file.length, 700_000_000)
        XCTAssertTrue(file.selected)
        XCTAssertEqual(file.id, 2)
    }

    // MARK: - Aria2StatusMapper

    private func status(named status: String, completed: Int64, total: Int64) -> TorrentStatus {
        TorrentStatus(
            gid: "g", status: status, totalLength: total, completedLength: completed,
            uploadLength: 0, downloadSpeed: 0, uploadSpeed: 0, connections: 0,
            numSeeders: 0, dir: "", name: nil, infoHash: nil,
            followedBy: [], following: nil, errorCode: nil, errorMessage: nil)
    }

    func testStatusMapping() {
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "active", completed: 10, total: 100)), .downloading)
        // Metadata not yet known (total 0) must not report seeding.
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "active", completed: 0, total: 0)), .downloading)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "active", completed: 100, total: 100)), .seeding)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "waiting", completed: 0, total: 100)), .downloading)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "paused", completed: 50, total: 100)), .paused)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "error", completed: 50, total: 100)), .failed)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "removed", completed: 50, total: 100)), .failed)
        XCTAssertEqual(Aria2StatusMapper.map(status(named: "complete", completed: 100, total: 100)), .completed)
    }

    // MARK: - GidLineage

    func testGidLineageMigration() {
        var lineage = GidLineage()
        let id = UUID()
        lineage.register(gid: "magnet-gid", item: id)
        XCTAssertEqual(lineage.itemID(for: "magnet-gid"), id)

        // Magnet resolves: daemon retires the magnet GID, real download
        // continues under the new GID.
        let moved = lineage.migrate(from: "magnet-gid", to: "torrent-gid")
        XCTAssertEqual(moved, id)
        XCTAssertNil(lineage.itemID(for: "magnet-gid"))
        XCTAssertEqual(lineage.itemID(for: "torrent-gid"), id)
    }

    func testGidLineageMigrateUnknownReturnsNil() {
        var lineage = GidLineage()
        XCTAssertNil(lineage.migrate(from: "nope", to: "new"))
        XCTAssertNil(lineage.itemID(for: "new"))
    }

    func testGidLineageForgetItem() {
        var lineage = GidLineage()
        let id = UUID()
        lineage.register(gid: "a", item: id)
        lineage.register(gid: "b", item: id)
        lineage.forgetItem(id)
        XCTAssertNil(lineage.itemID(for: "a"))
        XCTAssertNil(lineage.itemID(for: "b"))
    }

    // MARK: - Aria2Daemon.decide

    private func sampleManifest() -> Aria2Daemon.Manifest {
        Aria2Daemon.Manifest(
            pid: 1234, binaryPath: "/Applications/Grabbit.app/Contents/Resources/bin/aria2-next",
            rpcPort: 6800, secret: "s")
    }

    func testDecideNoManifestStartsFresh() {
        XCTAssertEqual(
            Aria2Daemon.decide(manifest: nil, pidAlive: false, binaryPath: "/x"),
            .startFresh)
    }

    func testDecideDeadPidStartsFresh() {
        XCTAssertEqual(
            Aria2Daemon.decide(manifest: sampleManifest(), pidAlive: false, binaryPath: sampleManifest().binaryPath),
            .startFresh)
    }

    func testDecideLiveOwnBinaryReclaims() {
        let m = sampleManifest()
        XCTAssertEqual(
            Aria2Daemon.decide(manifest: m, pidAlive: true, binaryPath: m.binaryPath),
            .reclaim(m))
    }

    func testDecideLiveForeignBinaryKillsStale() {
        let m = sampleManifest()
        XCTAssertEqual(
            Aria2Daemon.decide(manifest: m, pidAlive: true, binaryPath: "/other/aria2c"),
            .killStale(pid: 1234))
    }

    // MARK: - NetworkInterfaceMonitor.isBlocked

    func testVPNNotBlockedWhenDisabled() {
        XCTAssertFalse(NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: false, interfaceName: "utun3", upNames: []))
    }

    func testVPNNotBlockedWhenNoInterfaceConfigured() {
        XCTAssertFalse(NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: true, interfaceName: "", upNames: []))
        XCTAssertFalse(NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: true, interfaceName: "   ", upNames: []))
    }

    func testVPNBlockedWhenInterfaceDown() {
        XCTAssertTrue(NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: true, interfaceName: "utun3", upNames: ["en0", "lo0"]))
    }

    func testVPNNotBlockedWhenInterfaceUp() {
        XCTAssertFalse(NetworkInterfaceMonitor.isBlocked(
            killSwitchEnabled: true, interfaceName: "utun3", upNames: ["en0", "utun3"]))
    }

    // MARK: - MagnetParser

    func testMagnetInfoHashHex() {
        let magnet = "magnet:?xt=urn:btih:ABCDEF1234567890ABCDEF1234567890ABCDEF12&dn=Test"
        XCTAssertEqual(
            MagnetParser.infoHash(from: magnet),
            "abcdef1234567890abcdef1234567890abcdef12")
        XCTAssertTrue(MagnetParser.isMagnet(magnet))
        XCTAssertEqual(MagnetParser.displayName(for: magnet), "Test")
    }

    func testMagnetInfoHashBase32NotNormalized() {
        // 32-char base32 hashes can't be matched against the daemon's hex
        // infoHash, so they normalize to nil (falls back to GID tracking).
        XCTAssertNil(MagnetParser.infoHash(from: "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"))
    }

    func testMagnetInfoHashNonMagnet() {
        XCTAssertNil(MagnetParser.infoHash(from: "https://example.com/x.torrent"))
        XCTAssertFalse(MagnetParser.isMagnet("https://example.com/x.torrent"))
    }

    // MARK: - TorrentRuntimeResolver

    func testResolverEnvOverride() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabbit-test-aria2-next")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        setenv("ARIA2_NEXT_PATH", tmp.path, 1)
        defer {
            unsetenv("ARIA2_NEXT_PATH")
            try? FileManager.default.removeItem(at: tmp)
        }
        let resolved = try TorrentRuntimeResolver.resolve().get()
        XCTAssertEqual(resolved.path, tmp.path)
    }

    // MARK: - Backward-compatible decoding

    func testAppSettingsDecodesWithoutTorrentFields() throws {
        let old = """
        {"language":"en","theme":"dark","speedLimitBytesPerSec":0,\
        "clipboardMonitorEnabled":true,"autoResumeOnLaunch":false,\
        "autoUpdateEnabled":true,"notificationsEnabled":false,\
        "defaultConnections":8,"folders":[]}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.language, .en)
        XCTAssertEqual(settings.defaultConnections, 8)
        XCTAssertFalse(settings.vpnKillSwitchEnabled)
        XCTAssertEqual(settings.vpnInterfaceName, "")
        XCTAssertEqual(settings.defaultSeedRatio, 0)
        XCTAssertEqual(settings.defaultSeedTimeMinutes, 0)
    }

    func testTorrentItemDecodesOldStubFormat() throws {
        let old: [String: Any] = [
            "id": UUID().uuidString,
            "name": "old",
            "magnetURI": "magnet:?xt=urn:btih:abc",
            "totalBytes": 100 as Int64,
            "downloadedBytes": 10 as Int64,
            "seeds": 1, "peers": 2, "ratio": 0.5,
            "state": "paused",
            "savePath": "/tmp",
            "addedAt": Date().timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: old)
        let item = try JSONDecoder().decode(TorrentItem.self, from: data)
        XCTAssertEqual(item.name, "old")
        XCTAssertEqual(item.state, .paused)
        XCTAssertNil(item.gid)
        XCTAssertNil(item.infoHash)
        XCTAssertEqual(item.downloadSpeed, 0)
        XCTAssertNil(item.errorMessage)
    }

    // MARK: - DHT bootstrap (Bug D)

    func testDhtArgsContainPublicBootstrapNodes() {
        let args = Aria2Daemon.dhtArgs()
        XCTAssertEqual(args, [
            "--dht-entry-point=dht.transmissionbt.com:6881",
            "--dht-entry-point=router.bittorrent.com:6881",
        ])
    }

    func testKillSwitchDefaultsOff() {
        // The kill-switch must be opt-in: a default-ON switch with a
        // missing interface would pause every torrent forever.
        XCTAssertFalse(AppSettings.default.vpnKillSwitchEnabled)
        XCTAssertEqual(AppSettings.default.vpnInterfaceName, "")
    }

    // MARK: - TorrentDisplayStatus (Bug D)

    private func displayItem(
        magnetURI: String = "",
        totalBytes: Int64 = 0,
        seeders: Int = 0,
        peers: Int = 0,
        state: TorrentState = .downloading
    ) -> TorrentItem {
        TorrentItem(
            name: "t",
            magnetURI: magnetURI,
            sourceURI: magnetURI,
            totalBytes: totalBytes,
            seeds: seeders,
            peers: peers,
            numSeeders: seeders,
            connections: peers,
            state: state,
            savePath: URL(fileURLWithPath: "/tmp"))
    }

    func testDisplayStatusMagnetWithoutMetadata() {
        let item = displayItem(
            magnetURI: "magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12",
            totalBytes: 0)
        XCTAssertEqual(TorrentDisplayStatus.of(item), .waitingForMetadata)
    }

    func testDisplayStatusMagnetWithMetadataNoPeers() {
        let item = displayItem(
            magnetURI: "magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12",
            totalBytes: 1_000_000)
        XCTAssertEqual(TorrentDisplayStatus.of(item), .connecting)
    }

    func testDisplayStatusConnectingForPeerlessTorrentFile() {
        let item = displayItem(totalBytes: 1_000_000)
        XCTAssertEqual(TorrentDisplayStatus.of(item), .connecting)
    }

    func testDisplayStatusDownloadingWithPeers() {
        let item = displayItem(totalBytes: 1_000_000, seeders: 3, peers: 5)
        XCTAssertEqual(TorrentDisplayStatus.of(item), .downloading)
    }

    func testDisplayStatusPassesThroughTerminalStates() {
        XCTAssertEqual(
            TorrentDisplayStatus.of(displayItem(state: .paused)), .paused)
        XCTAssertEqual(
            TorrentDisplayStatus.of(displayItem(state: .seeding)), .seeding)
        XCTAssertEqual(
            TorrentDisplayStatus.of(displayItem(state: .completed)), .completed)
        XCTAssertEqual(
            TorrentDisplayStatus.of(displayItem(state: .failed)), .failed)
    }

    // MARK: - SettingsStore.folderURL fallback

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func blockFile(at url: URL) throws {
        try "blocked".write(to: url, atomically: true, encoding: .utf8)
    }

    func testFolderURLFallsBackWhenBlockedByFile() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let blocked = tmp.appendingPathComponent("Other")
        try blockFile(at: blocked)

        let store = SettingsStore()
        store.settings.folders[.other] = blocked.path
        let resolved = store.folderURL(for: .other)

        XCTAssertTrue(SettingsStore.isExistingDirectory(resolved))
        XCTAssertNotEqual(resolved, blocked)
        XCTAssertEqual(resolved.lastPathComponent, "Other-2")
    }

    func testFolderURLFallsBackTwiceWhenBothBlocked() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let blocked = tmp.appendingPathComponent("Other")
        try blockFile(at: blocked)
        try blockFile(at: tmp.appendingPathComponent("Other-2"))

        let store = SettingsStore()
        store.settings.folders[.other] = blocked.path
        let resolved = store.folderURL(for: .other)

        XCTAssertTrue(SettingsStore.isExistingDirectory(resolved))
        XCTAssertEqual(resolved.lastPathComponent, "Other-3")
    }

    func testFolderURLPassesThroughRealDirectory() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = SettingsStore()
        store.settings.folders[.other] = tmp.path
        XCTAssertEqual(store.folderURL(for: .other), tmp)
    }

    func testIsExistingDirectoryRejectsFiles() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("f")
        try blockFile(at: file)
        XCTAssertFalse(SettingsStore.isExistingDirectory(file))
        XCTAssertTrue(SettingsStore.isExistingDirectory(tmp))
        XCTAssertFalse(SettingsStore.isExistingDirectory(tmp.appendingPathComponent("missing")))
    }

    // MARK: - TorrentEngine.resolvedSaveDir

    func testResolvedSaveDirRepairsFilePath() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("notadir")
        try blockFile(at: file)
        let fallback = tmp.appendingPathComponent("Fallback", isDirectory: true)

        let store = SettingsStore()
        store.settings.folders[.other] = fallback.path
        let engine = TorrentEngine(settings: store)

        let resolved = engine.resolvedSaveDir(file)
        XCTAssertTrue(SettingsStore.isExistingDirectory(resolved))
        XCTAssertEqual(resolved, fallback)
    }

    func testResolvedSaveDirPassesThroughRealDirectory() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let engine = TorrentEngine(settings: SettingsStore())
        XCTAssertEqual(engine.resolvedSaveDir(tmp), tmp)
    }

    // MARK: - TorrentStatus.errorDisplay

    private func errorStatus(code: String?, message: String?) -> TorrentStatus {
        TorrentStatus(
            gid: "g", status: "error",
            totalLength: 0, completedLength: 0, uploadLength: 0,
            downloadSpeed: 0, uploadSpeed: 0, connections: 0, numSeeders: 0,
            dir: "", name: nil, infoHash: nil,
            followedBy: [], following: nil,
            errorCode: code, errorMessage: message)
    }

    func testErrorDisplayIncludesCode() {
        XCTAssertEqual(
            errorStatus(code: "1", message: "Not a directory").errorDisplay,
            "Not a directory (code 1)")
    }

    func testErrorDisplayOmitsZeroCode() {
        XCTAssertEqual(
            errorStatus(code: "0", message: "Not a directory").errorDisplay,
            "Not a directory")
    }

    func testErrorDisplayOmitsMissingCode() {
        XCTAssertEqual(
            errorStatus(code: nil, message: "Boom").errorDisplay, "Boom")
    }

    func testErrorDisplayFallsBackToUnknown() {
        XCTAssertEqual(
            errorStatus(code: "24", message: nil).errorDisplay,
            "Unknown error (code 24)")
    }
}
