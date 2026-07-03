import Foundation
import UserNotifications

// MARK: - AlertNotificationService

/// Manages notification authorization and badge cleanup for environmental alerts.
/// Alert delivery is sourced from the unified Home Intelligence notification pipeline.
final class AlertNotificationService {

    static let shared = AlertNotificationService()

    private init() {}

    /// Richiede il permesso per le notifiche quando l'utente abilita esplicitamente gli alert.
    func requestAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { granted, error in
                if let error {
                    dprint("❌ Notifiche: permesso negato – \(error)")
                } else {
                    dprint("🔔 Notifiche: permesso \(granted ? "concesso" : "negato")")
                }
            }
        }
    }

    /// Azzera il badge dell'icona app.
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error {
                dprint("❌ AlertNotification clearBadge: \(error)")
            }
        }
    }
}
