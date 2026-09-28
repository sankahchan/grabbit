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

    // MARK: - Default tracker list

    func testBtTrackerArgsFormSingleCommaJoinedFlag() {
        let args = Aria2Daemon.btTrackerArgs()
        XCTAssertEqual(args.count, 1)
        XCTAssertTrue(args[0].hasPrefix("--bt-tracker="))
        let list = String(args[0].dropFirst("--bt-tracker=".count))
        XCTAssertEqual(list, Aria2Daemon.btTrackerList)
        XCTAssertFalse(list.isEmpty)
    }

    func testDefaultTrackersAreValidAnnounceURLs() {
        // Every entry must be a usable announce URL: scheme + /announce path.
        // A malformed entry would make aria2 reject the whole flag.
        XCTAssertGreaterThanOrEqual(Aria2Daemon.defaultTrackers.count, 10)
        for tracker in Aria2Daemon.defaultTrackers {
            let url = URL(string: tracker)
            XCTAssertNotNil(url, "not a URL: \(tracker)")
            XCTAssertTrue(
                ["udp", "http", "https"].contains(url?.scheme),
                "bad scheme: \(tracker)")
            XCTAssertTrue(
                tracker.hasSuffix("/announce"),
                "not an announce URL: \(tracker)")
            XCTAssertFalse(tracker.contains(" "), "whitespace: \(tracker)")
            XCTAssertFalse(tracker.contains(","), "comma breaks joining: \(tracker)")
        }
    }

    func testDefaultTrackersHaveNoDuplicates() {
        let trackers = Aria2Daemon.defaultTrackers
        XCTAssertEqual(Set(trackers).count, trackers.count)
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

    @MainActor
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

    @MainActor
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

    // MARK: - HTML entity decoding in magnet names

    func testDecodingHTMLEntitiesNamed() {
        XCTAssertEqual("DDG &ndash; HIT-A-THON".decodingHTMLEntities, "DDG – HIT-A-THON")
        XCTAssertEqual("Fish &amp; Chips".decodingHTMLEntities, "Fish & Chips")
        XCTAssertEqual("&lt;tag&gt;".decodingHTMLEntities, "<tag>")
    }

    func testDecodingHTMLEntitiesNumeric() {
        XCTAssertEqual("A&#8211;B".decodingHTMLEntities, "A–B")
        XCTAssertEqual("A&#x2013;B".decodingHTMLEntities, "A–B")
    }

    func testDecodingHTMLEntitiesLeavesUnknownAlone() {
        XCTAssertEqual("a &bogus; b".decodingHTMLEntities, "a &bogus; b")
        XCTAssertEqual("rock & roll".decodingHTMLEntities, "rock & roll")
        XCTAssertEqual("plain".decodingHTMLEntities, "plain")
    }

    func testMagnetDisplayNameDecodesEntities() {
        let magnet = "magnet:?xt=urn:btih:ABCDEF1234567890&dn=DDG%20%26ndash%3B%20HIT-A-THON"
        XCTAssertEqual(MagnetParser.displayName(for: magnet), "DDG – HIT-A-THON")
    }
}

// MARK: - Tracker auto-update

final class TrackerUpdaterTests: XCTestCase {
    private func clearCache() {
        try? FileManager.default.removeItem(at: TrackerUpdater.cacheFileURL)
        try? FileManager.default.removeItem(at: TrackerUpdater.cacheDateURL)
    }

    override func tearDown() {
        clearCache()
        super.tearDown()
    }

    func testParseStripsBlanksAndComments() {
        let raw = """
        # trackers_best.txt

        udp://tracker.opentrackr.org:1337/announce
          http://tracker.dler.org:6969/announce  \n
        """
        XCTAssertEqual(TrackerUpdater.parse(raw), [
            "udp://tracker.opentrackr.org:1337/announce",
            "http://tracker.dler.org:6969/announce",
        ])
    }

    func testParseEmptyYieldsEmpty() {
        XCTAssertTrue(TrackerUpdater.parse("").isEmpty)
        XCTAssertTrue(TrackerUpdater.parse("# only a comment\n\n").isEmpty)
    }

    func testNeedsRefreshWithNoCache() {
        clearCache()
        XCTAssertTrue(TrackerUpdater.needsRefresh())
    }

    func testCacheRoundTrip() {
        clearCache()
        let trackers = ["udp://a.example:1337/announce", "http://b.example:6969/announce"]
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        TrackerUpdater.saveCache(trackers, at: stamp)
        XCTAssertEqual(TrackerUpdater.loadCache(), trackers)
        XCTAssertEqual(TrackerUpdater.cacheUpdatedAt()?.timeIntervalSince1970, 1_700_000_000)
        // Fresh cache: no refresh due. Stale cache: refresh due.
        XCTAssertFalse(TrackerUpdater.needsRefresh(now: stamp.addingTimeInterval(3600)))
        XCTAssertTrue(TrackerUpdater.needsRefresh(
            now: stamp.addingTimeInterval(TrackerUpdater.defaultSyncHours * 3600 + 1)))
    }

    func testNeedsRefreshHonorsCustomSyncHours() {
        clearCache()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        TrackerUpdater.saveCache(["udp://a.example:1337/announce"], at: stamp)
        // 6h sync: stale after 6h; 48h sync: still fresh at 12h.
        XCTAssertTrue(TrackerUpdater.needsRefresh(
            now: stamp.addingTimeInterval(6 * 3600 + 1), syncHours: 6))
        XCTAssertFalse(TrackerUpdater.needsRefresh(
            now: stamp.addingTimeInterval(12 * 3600), syncHours: 48))
    }

    func testSourcesHaveCDNFallbacks() {
        XCTAssertEqual(TrackerUpdater.sources.count, 2)
        for source in TrackerUpdater.sources {
            XCTAssertGreaterThanOrEqual(source.urls.count, 2)
            XCTAssertTrue(source.urls.contains { $0.host == "cdn.jsdelivr.net" })
        }
    }

    func testCurrentTrackersFallsBackToDefaults() {
        clearCache()
        XCTAssertEqual(TrackerUpdater.currentTrackers(), Aria2Daemon.defaultTrackers)
    }

    func testCurrentTrackersPrefersCache() {
        clearCache()
        let trackers = ["udp://cached.example:1337/announce"]
        TrackerUpdater.saveCache(trackers)
        XCTAssertEqual(TrackerUpdater.currentTrackers(), trackers)
    }

    func testBtTrackerListUsesUpdater() {
        // Daemon flags and the updater must agree: one source of truth.
        XCTAssertEqual(Aria2Daemon.btTrackerList, TrackerUpdater.currentTrackerList)
        XCTAssertFalse(Aria2Daemon.btTrackerList.isEmpty)
    }

    func testAutoUpdateTrackersDefaultsOn() {
        XCTAssertTrue(AppSettings.default.autoUpdateTrackers)
    }

    func testRefreshSkippedWhenDisabled() async {
        // Disabled: no network, no cache write, apply never runs.
        clearCache()
        var applied = false
        await TrackerUpdater.refreshIfNeeded(autoUpdate: false) { _ in applied = true }
        XCTAssertFalse(applied)
        XCTAssertNil(TrackerUpdater.loadCache())
    }
}

// MARK: - Torrent rename (displayName)

final class TorrentRenameTests: XCTestCase {
    func testCustomNameWinsOverMagnetDn() {
        let magnet = "magnet:?xt=urn:btih:ABCDEF1234567890&dn=Original+Name"
        XCTAssertEqual(
            TorrentEngine.resolveDisplayName(magnetOrURL: magnet, displayName: "My Rename"),
            "My Rename")
    }

    func testCustomNameTrimmedAndBlankFallsBack() {
        let magnet = "magnet:?xt=urn:btih:ABCDEF1234567890&dn=Original%20Name"
        XCTAssertEqual(
            TorrentEngine.resolveDisplayName(magnetOrURL: magnet, displayName: "  "),
            "Original Name")
        XCTAssertEqual(
            TorrentEngine.resolveDisplayName(magnetOrURL: magnet, displayName: nil),
            "Original Name")
    }

    func testUrlFallsBackToLastPathComponent() {
        XCTAssertEqual(
            TorrentEngine.resolveDisplayName(
                magnetOrURL: "https://example.com/files/ubuntu.torrent", displayName: nil),
            "ubuntu.torrent")
    }

    func testCustomNameWinsOverUrl() {
        XCTAssertEqual(
            TorrentEngine.resolveDisplayName(
                magnetOrURL: "https://example.com/files/ubuntu.torrent",
                displayName: "Ubuntu 24.04"),
            "Ubuntu 24.04")
    }
}

// MARK: - Tracker UDP prober (pure packet helpers)

final class TrackerProberTests: XCTestCase {
    func testConnectRequestPacket() {
        let txID: UInt32 = 0x12345678
        let req = TrackerProber.connectRequest(transactionID: txID)
        XCTAssertEqual(req.count, 16)
        // Byte-wise decode — no unsafe aligned loads.
        let bytes = Array(req)
        func u64(_ r: Range<Int>) -> UInt64 {
            r.reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[$1]) }
        }
        func u32(_ r: Range<Int>) -> UInt32 {
            r.reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[$1]) }
        }
        XCTAssertEqual(u64(0..<8), 0x41727101980)
        XCTAssertEqual(u32(8..<12), 0)
        XCTAssertEqual(u32(12..<16), txID)
    }

    func testParseConnectResponse() {
        let txID: UInt32 = 0xAABBCCDD
        // Byte-wise packet construction — no unsafe aligned loads, so this
        // is safe regardless of Data's buffer alignment.
        var bytes: [UInt8] = []
        bytes += [0, 0, 0, 0]                       // action = 0 (connect)
        bytes += [0xAA, 0xBB, 0xCC, 0xDD]           // transaction id
        bytes += [0, 0, 0, 0, 0, 0, 0x12, 0x34]     // connection id
        let resp = Data(bytes)
        XCTAssertEqual(TrackerProber.parseConnectResponse(resp), txID)
        // Wrong action.
        var badBytes = bytes
        badBytes[3] = 3
        XCTAssertNil(TrackerProber.parseConnectResponse(Data(badBytes)))
        // Truncated.
        XCTAssertNil(TrackerProber.parseConnectResponse(Data(count: 8)))
    }

    func testUdpEndpointParsing() {
        let ep = TrackerProber.udpEndpoint(for: "udp://tracker.opentrackr.org:1337/announce")
        XCTAssertEqual(ep?.host, "tracker.opentrackr.org")
        XCTAssertEqual(ep?.port, 1337)
        // Not UDP.
        XCTAssertNil(TrackerProber.udpEndpoint(for: "http://tracker.dler.org:6969/announce"))
        // No port.
        XCTAssertNil(TrackerProber.udpEndpoint(for: "udp://tracker.example/announce"))
        // Garbage.
        XCTAssertNil(TrackerProber.udpEndpoint(for: "not a url"))
    }
}

// MARK: - aria2 performance profiles

final class Aria2PerformanceProfileTests: XCTestCase {
    func testBalancedMatchesMotrix() {
        let p = Aria2PerformanceProfile.balanced
        XCTAssertEqual(p.maxConnectionPerServer, 16)
        XCTAssertEqual(p.split, 16)
        XCTAssertEqual(p.minSplitSize, "10M")
        XCTAssertEqual(p.diskCache, "32M")
    }

    func testMaximumIsMostAggressive() {
        let p = Aria2PerformanceProfile.maximum
        XCTAssertEqual(p.maxConnectionPerServer, 64)
        XCTAssertEqual(p.split, 64)
        XCTAssertEqual(p.minSplitSize, "1M")
        XCTAssertEqual(p.diskCache, "64M")
        XCTAssertTrue(p.launchArgs.contains("--max-connection-per-server=64"))
        XCTAssertTrue(p.launchArgs.contains("--split=64"))
    }

    func testRpcOptionsMirrorLaunchArgs() {
        for profile in Aria2PerformanceProfile.allCases {
            XCTAssertEqual(
                profile.globalRpcOptions["max-connection-per-server"],
                "\(profile.maxConnectionPerServer)")
            XCTAssertEqual(
                profile.globalRpcOptions["split"], "\(profile.split)")
            // disk-cache is global-only — it must ride the global push,
            // never a per-download changeOption.
            XCTAssertEqual(
                profile.globalRpcOptions["disk-cache"], profile.diskCache)
        }
    }
}
