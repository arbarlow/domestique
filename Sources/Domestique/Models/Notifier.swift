import AppKit
import UserNotifications

/// macOS notifications for things worth looking up for (checks passed/failed, PR merged).
/// Needs a real app bundle; silently does nothing under `swift run`.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        let center = UNUserNotificationCenter.current()
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
