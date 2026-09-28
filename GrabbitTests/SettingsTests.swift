import XCTest
import ObjectiveC
@testable import Grabbit

final class SettingsTests: XCTestCase {
    func testAutoClearFinishedDefaultsTrue() {
        XCTAssertTrue(AppSettings.default.autoClearFinished)
    }

    func testAutoClearFinishedDecodesLegacyJSON() throws {
        // Settings saved before the key existed must decode with the default.
        let data = #"{"language":"system"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.autoClearFinished)
    }

    func testAutoClearFinishedRespectsExplicitFalse() throws {
        let data = #"{"autoClearFinished":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.autoClearFinished)
    }

    func testTorrentsSidebarIconIsSet() {
        // Regression: "magnet" is not a real SF Symbol and rendered blank.
        XCTAssertEqual(SidebarSelection.torrents.icon, "arrow.triangle.2.circlepath")
    }

    func testBundleLocalizationApplyFallsBackGracefully() {
        // The swizzle must never break lookup, even when the .lproj is
        // absent (e.g. unit-test host): unknown keys fall back to the key.
        BundleLocalization.apply(.system)
        XCTAssertFalse(String(localized: "definitely.not.a.real.key").isEmpty)
        BundleLocalization.apply(.my)
        XCTAssertFalse(String(localized: "definitely.not.a.real.key").isEmpty)
        BundleLocalization.apply(.en)
        XCTAssertFalse(String(localized: "definitely.not.a.real.key").isEmpty)
        BundleLocalization.apply(.system)
    }

    func testDiagnoseLocalizationPaths() {
        // Diagnostic: which lookup paths does the swizzle intercept?
        // The log lines below show exactly where String(localized:) resolves.
        BundleLocalization.apply(.my)
        let direct = Bundle.main.localizedString(
            forKey: "settings.title", value: nil, table: nil)
        let viaMacro = NSLocalizedString("settings.title", comment: "")
        let viaInit = String(localized: "settings.title")
        print("DIAG direct=\(direct)")
        print("DIAG NSLocalizedString=\(viaMacro)")
        print("DIAG String(localized:)=\(viaInit)")
        print("DIAG mainBundleClass=\(object_getClass(Bundle.main))")
        print("DIAG my.lproj=\(Bundle.main.path(forResource: "my", ofType: "lproj") ?? "nil")")
        XCTAssertEqual(direct, "ဆက်တင်များ")
        XCTAssertEqual(viaMacro, "ဆက်တင်များ")
        XCTAssertEqual(viaInit, "ဆက်တင်များ")
        BundleLocalization.apply(.system)
    }
}
