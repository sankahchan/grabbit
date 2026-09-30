import Foundation
import Sparkle

/// Bridges SwiftUI views to the Sparkle updater without threading the
/// controller through the environment. `GrabbitApp` assigns this only when
/// the updater is configured (signed Release builds with a real
/// `SUPublicEDKey`); it stays nil in dev builds.
@MainActor
enum UpdaterBridge {
    static weak var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool { controller != nil }

    /// Applies the user's "automatically check for updates" preference to
    /// Sparkle (the persisted setting alone was previously a no-op).
    static func applyAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    /// Settings > Check Now.
    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
