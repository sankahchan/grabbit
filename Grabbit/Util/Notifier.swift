import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for download events.
/// Phase 5 "after-completion actions": notifications with semantic names.
public enum Notifier {
    /// Asks once; subsequent launches are a no-op when already decided.
    public static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Download events

    public static func downloadComplete(filename: String, folder: String) {
        post(
            title: NSLocalizedString("notify.download.complete.title", comment: ""),
            body: String(
                format: NSLocalizedString("notify.download.complete.body", comment: ""),
                filename, folder
            )
        )
    }

    public static func downloadFailed(filename: String, message: String) {
        post(
            title: NSLocalizedString("notify.download.failed.title", comment: ""),
            body: String(
                format: NSLocalizedString("notify.download.failed.body", comment: ""),
                filename, message
            )
        )
    }
}
