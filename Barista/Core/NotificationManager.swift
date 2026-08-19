import Cocoa
import UserNotifications

/// Manages macOS notifications for widget alerts.
/// Widgets can fire notifications when thresholds are crossed (e.g., CPU > 90%, stock price change).
class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false
    private var cooldowns: [String: Date] = [:]  // Prevent spam: key -> last fire time
    private let cooldownInterval: TimeInterval = 300  // 5 min between same alerts

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    /// Fire a notification from a widget.
    /// - Parameters:
    ///   - key: Unique key for dedup/cooldown (e.g., "cpu-high")
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - widgetName: Source widget name for the subtitle
    ///   - sound: Whether to play a sound
    func fire(key: String, title: String, body: String, widgetName: String, sound: Bool = true) {
        // Cooldown check
        if let lastFire = cooldowns[key], Date().timeIntervalSince(lastFire) < cooldownInterval {
            return
        }
        cooldowns[key] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = "Barista - \(widgetName)"
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "barista.\(key).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Check if notifications are authorized.
    func checkAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus == .authorized)
            }
        }
    }
}
