import XCTest
@testable import Grabbit

final class TorznabDiscoveryTests: XCTestCase {

    // MARK: - Jackett config

    func testParseJackettConfigPascalCase() throws {
        let json = """
        { "Port": 9117, "APIKey": "jackett-key", "ListenPublicly": false }
        """
        let config = try XCTUnwrap(
            TorznabDiscovery.parseJackettConfig(data: Data(json.utf8)))
        XCTAssertEqual(config.apiKey, "jackett-key")
        XCTAssertEqual(config.port, 9117)
    }

    func testParseJackettConfigDefaultsPortAndRejectsNoKey() {
        let json = """
        { "APIKey": "abc" }
        """
        XCTAssertEqual(
            TorznabDiscovery.parseJackettConfig(data: Data(json.utf8))?.port,
            9117)
        XCTAssertNil(TorznabDiscovery.parseJackettConfig(
            data: Data("{}".utf8)))
        XCTAssertNil(TorznabDiscovery.parseJackettConfig(
            data: Data("not json".utf8)))
    }

    // MARK: - Prowlarr config

    func testParseProwlarrConfig() throws {
        let xml = """
        <Config>
          <Port>9696</Port>
          <AuthenticationMethod>None</AuthenticationMethod>
          <ApiKey>prowlarr-key</ApiKey>
        </Config>
        """
        let config = try XCTUnwrap(
            TorznabDiscovery.parseProwlarrConfig(data: Data(xml.utf8)))
        XCTAssertEqual(config.apiKey, "prowlarr-key")
        XCTAssertEqual(config.port, 9696)
    }

    func testParseProwlarrConfigWithoutKeyIsNil() {
        let xml = "<Config><Port>9696</Port></Config>"
        XCTAssertNil(TorznabDiscovery.parseProwlarrConfig(
            data: Data(xml.utf8)))
    }

    // MARK: - Prowlarr indexer list

    func testEnabledTorrentIndexersFiltersDisabledAndUsenet() {
        let json = """
        [
          {"id": 1, "name": "1337x", "enable": true, "protocol": "torrent"},
          {"id": 2, "name": "Off", "enable": false, "protocol": "torrent"},
          {"id": 3, "name": "NZBGeek", "enable": true, "protocol": "usenet"},
          {"id": 4, "name": "NoFields"}
        ]
        """
        let indexers = TorznabDiscovery.enabledTorrentIndexers(
            data: Data(json.utf8))
        XCTAssertEqual(indexers.map(\.name), ["1337x", "NoFields"])
    }

    // MARK: - URL shapes

    func testDiscoveredURLShapes() {
        XCTAssertEqual(
            TorznabDiscovery.jackettTorznabURL(port: 9117),
            "http://localhost:9117/api/v2.0/indexers/all/results/torznab")
        XCTAssertEqual(
            TorznabDiscovery.prowlarrTorznabURL(port: 9696, indexerID: 7),
            "http://localhost:9696/7/api")
    }
}
