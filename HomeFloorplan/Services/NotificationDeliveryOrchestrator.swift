import Foundation
import UserNotifications

// MARK: - NotificationDeliveryOrchestrator

/// Wraps UNUserNotificationCenter — registers categories and delivers
/// system notifications for High/Critical ProactiveNotifications.
/// All methods are nonisolated and safe to call from any actor.
enum NotificationDeliveryOrchestrator {

    // MARK: - Category registration

    static func registerCategories() {
        let open       = UNNotificationAction(
            identifier: "OPEN",
            title: String(localized: "notif.action.open",       defaultValue: "Open"),
            options: .foreground
        )
        let dismiss    = UNNotificationAction(
            identifier: "DISMISS",
            title: String(localized: "notif.action.dismiss",    defaultValue: "Dismiss"),
            options: []
        )
        let doNow      = UNNotificationAction(
            identifier: "DO_NOW",
            title: String(localized: "notif.action.doNow",      defaultValue: "Do it now"),
            options: .foreground
        )
        let createRule = UNNotificationAction(
            identifier: "CREATE_RULE",
            title: String(localized: "notif.action.createRule", defaultValue: "Create Automation"),
            options: .foreground
        )
        let later      = UNNotificationAction(
            identifier: "LATER",
            title: String(localized: "notif.action.later",      defaultValue: "Later"),
            options: []
        )
        let viewFeed   = UNNotificationAction(
            identifier: "VIEW_FEED",
            title: String(localized: "notif.action.viewFeed",   defaultValue: "View Feed"),
            options: .foreground
        )

        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: NotificationCategory.environment.unCategoryIdentifier,
                actions: [open, dismiss],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.behavioralAI.unCategoryIdentifier,
                actions: [doNow, createRule, later],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.automationOpportunity.unCategoryIdentifier,
                actions: [createRule, later, dismiss],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.security.unCategoryIdentifier,
                actions: [open, dismiss],
                intentIdentifiers: [],
                options: .customDismissAction
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.deviceHealth.unCategoryIdentifier,
                actions: [open, dismiss],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.learning.unCategoryIdentifier,
                actions: [viewFeed, dismiss],
                intentIdentifiers: [],
                options: []
            ),
        ]

        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    // MARK: - Delivery

    static func deliver(_ notification: ProactiveNotification, context: ContextSnapshot) async {
        guard notification.priority.sendsSystemNotification else { return }
        guard !context.suppressNonCritical || notification.priority.breaksQuietHours else { return }

        let center   = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title              = notification.headline
        content.body               = notification.body
        content.sound              = notification.priority == .critical ? .defaultCritical : .default
        content.threadIdentifier   = "com.homefloorplan.\(notification.categoryRaw)"
        content.categoryIdentifier = categoryIdentifier(for: notification.category)
        content.userInfo           = ["notificationID": notification.id.uuidString]

        if notification.priority.incrementsBadge {
            content.badge = NSNumber(value: 1)
        }

        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content:    content,
            trigger:    UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
    }

    static func cancelDelivery(for notificationID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID.uuidString])
    }

    // MARK: - Helpers

    private static func categoryIdentifier(for category: NotificationCategory) -> String {
        switch category {
        case .environment, .comfort, .hvac:  return NotificationCategory.environment.unCategoryIdentifier
        case .behavioralAI:                   return NotificationCategory.behavioralAI.unCategoryIdentifier
        case .automationOpportunity:           return NotificationCategory.automationOpportunity.unCategoryIdentifier
        case .security:                        return NotificationCategory.security.unCategoryIdentifier
        case .deviceHealth, .maintenance:      return NotificationCategory.deviceHealth.unCategoryIdentifier
        default:                               return NotificationCategory.learning.unCategoryIdentifier
        }
    }
}
