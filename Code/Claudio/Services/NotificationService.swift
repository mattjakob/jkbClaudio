import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private nonisolated static let accessibilityCategoryId = "ACCESSIBILITY"

    private override init() {
        super.init()
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let category = UNNotificationCategory(
            identifier: Self.accessibilityCategoryId,
            actions: [],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func sendUsageMilestone(label: String, percentage: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Claudio"
        content.body = "\(label) usage reached \(percentage)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(label)-\(percentage)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendAccessibilityRequired() {
        let content = UNMutableNotificationContent()
        content.title = "Accessibility Permission Required"
        content.body = "Claudio needs accessibility access for Telegram bridge. Tap to open settings."
        content.sound = .default
        content.categoryIdentifier = Self.accessibilityCategoryId

        let request = UNNotificationRequest(
            identifier: "accessibility",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        if category == Self.accessibilityCategoryId {
            await MainActor.run { Self.openAccessibilitySettings() }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
