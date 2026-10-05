import XCTest
import SwiftUI
import AppKit
@testable import Grabbit

final class ThemeStyleTests: XCTestCase {
    func testThemeStyleDefaultsToClassic() {
        XCTAssertEqual(AppSettings.default.themeStyle, .classic)
    }

    func testThemeStyleDecodesLegacyJSONWithoutKey() throws {
        let data = #"{"language":"system"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.themeStyle, .classic)
    }

    func testThemeStyleRoundTripsThroughJSON() throws {
        for style in ThemeStyle.allCases {
            var settings = AppSettings.default
            settings.themeStyle = style
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.themeStyle, style)
        }
    }

    func testAllStylesResolveDistinctInkAndPaper() {
        for style in ThemeStyle.allCases {
            let tokens = ThemeCatalog.tokens(for: style)
            for scheme in [ColorScheme.light, .dark] {
                let ink = NSColor(tokens.ink(scheme)).usingColorSpace(.sRGB)!
                let paper = NSColor(tokens.paper(scheme)).usingColorSpace(.sRGB)!
                let distance = abs(ink.redComponent - paper.redComponent)
                    + abs(ink.greenComponent - paper.greenComponent)
                    + abs(ink.blueComponent - paper.blueComponent)
                XCTAssertGreaterThan(
                    distance, 0.5,
                    "\(style) \(scheme) ink and paper must contrast")
            }
        }
    }

    func testModernThemesUseSoftShadowsAndClassicStaysBrutalist() {
        XCTAssertTrue(ThemeCatalog.tokens(for: .classic).shape.brutalist)
        for style in ThemeStyle.allCases where style != .classic {
            let shape = ThemeCatalog.tokens(for: style).shape
            XCTAssertFalse(shape.brutalist, "\(style) should be modern")
            XCTAssertEqual(shape.cardHardOffset, 0, "\(style) must not use the hard offset")
            XCTAssertGreaterThan(
                shape.cardShadowRadius, 0, "\(style) needs a soft shadow")
        }
    }

    func testProgressStylesMatchThePreviews() {
        XCTAssertEqual(ThemeCatalog.tokens(for: .classic).shape.progress, .blocks)
        XCTAssertEqual(ThemeCatalog.tokens(for: .aura).shape.progress, .dotted)
        XCTAssertEqual(ThemeCatalog.tokens(for: .pulse).shape.progress, .segments)
        XCTAssertEqual(ThemeCatalog.tokens(for: .velvet).shape.progress, .segments)
        XCTAssertEqual(ThemeCatalog.tokens(for: .grove).shape.progress, .smooth)
        XCTAssertEqual(ThemeCatalog.tokens(for: .liquid).shape.progress, .smooth)
        XCTAssertTrue(ThemeCatalog.tokens(for: .pulse).shape.progressMarker)
        XCTAssertFalse(ThemeCatalog.tokens(for: .velvet).shape.progressMarker)
    }

    func testSignatureThemeDetailsArePresent() {
        XCTAssertTrue(ThemeCatalog.tokens(for: .pulse).shape.cardEdgeGlow)
        XCTAssertTrue(ThemeCatalog.tokens(for: .pulse).shape.sidebarIconTiles)
        XCTAssertTrue(ThemeCatalog.tokens(for: .pulse).shape.tileButtons)
        XCTAssertNotNil(ThemeCatalog.tokens(for: .aura).brandDot)
        XCTAssertFalse(ThemeCatalog.tokens(for: .aura).backgroundGlows.isEmpty)
        XCTAssertFalse(ThemeCatalog.tokens(for: .liquid).canvasGradientDark.isEmpty)
        XCTAssertFalse(ThemeCatalog.tokens(for: .liquid).canvasGradientLight.isEmpty)
        XCTAssertFalse(ThemeCatalog.tokens(for: .velvet).backgroundGlows.isEmpty)
    }

    func testRuntimeResolvesAssignedStyle() {
        let previous = ThemeRuntime.current
        defer { ThemeRuntime.current = previous }

        ThemeRuntime.current = .pulse
        XCTAssertEqual(ThemeRuntime.tokens.yellow, ThemeCatalog.tokens(for: .pulse).yellow)

        ThemeRuntime.current = .classic
        XCTAssertEqual(ThemeRuntime.tokens.yellow, Color(hex: 0xFFD02F))
    }

    func testDisplayNamesAreNonEmpty() {
        for style in ThemeStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
        }
    }
}
