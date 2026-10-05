import Foundation
import ObjectiveC

/// Instant in-app language switching.
///
/// The main bundle's `localizedString(forKey:value:table:)` is re-pointed at
/// a tiny subclass that serves the chosen language's compiled `.lproj`, so
/// the whole UI re-localizes the moment the setting changes.
/// `AppleLanguages` is kept in sync so a relaunch lands on the same
/// language, and a missing `.lproj` falls back to the default lookup.
///
/// CRITICAL: app code must use `NSLocalizedString` (or call
/// `localizedString(forKey:value:table:)` directly). Swift's
/// `String(localized:)` resolves BELOW the swizzled method and will NOT
/// follow the in-app language — proven by CI diagnostic 2026-09-28
/// (direct call → ဆက်တင်များ, String(localized:) → Settings).
public enum BundleLocalization {
    /// Applies the language immediately. Main-actor only (called from UI).
    public static func apply(_ language: AppLanguage) {
        let code: String? = switch language {
        case .system: nil
        case .en: "en"
        case .my: "my"
        }
        if object_getClass(Bundle.main) != LocalizedBundle.self {
            object_setClass(Bundle.main, LocalizedBundle.self)
        }
        (Bundle.main as? LocalizedBundle)?.languageCode = code
        // Keep the launch-time default in sync.
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// Serves localized strings from the selected language's `.lproj`.
/// Everything else falls through to the normal bundle behavior.
///
/// NOTE: the main bundle's instance was allocated as `Bundle`, so a Swift
/// stored property here would write past its allocation (heap corruption).
/// The language code lives in an associated object instead.
private var localizedBundleLanguageKey: UInt8 = 0

private final class LocalizedBundle: Bundle, @unchecked Sendable {
    var languageCode: String? {
        get { objc_getAssociatedObject(self, &localizedBundleLanguageKey) as? String }
        set {
            objc_setAssociatedObject(
                self, &localizedBundleLanguageKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    override func localizedString(
        forKey key: String, value: String?, table tableName: String?
    ) -> String {
        guard let code = languageCode,
              let path = super.path(forResource: code, ofType: "lproj"),
              let langBundle = Bundle(path: path)
        else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return langBundle.localizedString(forKey: key, value: value, table: tableName)
    }
}
