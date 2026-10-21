import UserNotifications

/// Local notifications for unattended work; permission is asked once, when
/// the first scheduled task exists.
enum SchedulerNotifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
