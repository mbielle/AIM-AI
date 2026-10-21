import AIMApplication
import AppKit
import UserNotifications

/// Local notifications following Settings › Notifications (no server push, no e-mail).
@MainActor
enum AIMNotifier {
    private static var authorized: Bool?

    static func post(_ kind: NotificationKind, title: String, body: String, preferences: AppPreferences, evenWhenActive: Bool = false) {
        // UserNotifications needs a real app bundle (not the test runner or the debug binary).
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil,
              preferences.allowsNotification(kind, appActive: evenWhenActive ? false : (NSApp?.isActive ?? false)) else { return }
        Task {
            if authorized == nil {
                authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(400))
            switch preferences.notificationSound {
            case "none": break
            case "default": content.sound = .default
            default: NSSound(named: NSSound.Name(preferences.notificationSound))?.play()
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// The macOS alert sounds offered in Settings.
    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
}
