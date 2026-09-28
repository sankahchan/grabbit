import XCTest
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
        XCTAssertFalse(NSLocalizedString("definitely.not.a.real.key", comment: "").isEmpty)
        BundleLocalization.apply(.my)
        XCTAssertFalse(NSLocalizedString("definitely.not.a.real.key", comment: "").isEmpty)
        BundleLocalization.apply(.en)
        XCTAssertFalse(NSLocalizedString("definitely.not.a.real.key", comment: "").isEmpty)
        BundleLocalization.apply(.system)
    }

    func testInstantLanguageSwitchServesMyanmar() {
        // Regression: Swift's String(localized:) resolves BELOW
        // -[NSBundle localizedStringForKey:value:table:], so the
        // BundleLocalization override never sees it (proven by CI
        // diagnostic 2026-09-28: direct=ဆက်တင်များ, String(localized:)=Settings).
        // App code must use NSLocalizedString — this test pins the
        // supported path end-to-end.
        BundleLocalization.apply(.my)
        XCTAssertEqual(
            Bundle.main.localizedString(forKey: "settings.title", value: nil, table: nil),
            "ဆက်တင်များ")
        XCTAssertEqual(
            NSLocalizedString("settings.title", comment: ""), "ဆက်တင်များ")
        BundleLocalization.apply(.en)
        XCTAssertEqual(
            NSLocalizedString("settings.title", comment: ""), "Settings")
        BundleLocalization.apply(.system)
    }
}
