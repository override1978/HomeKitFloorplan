import UIKit
import UserNotifications

// MARK: - AppDelegate

/// AppDelegate minimale richiesto da @UIApplicationDelegateAdaptor.
/// Non modifica la window di SwiftUI — il reset del timer screensaver
/// è gestito da IdleAwareOverlay (un UIViewRepresentable passthrough).
final class HomeFloorplanAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Imposta il delegate per le notifiche locali, necessario per
        // mostrarle anche con l'app in foreground.
        UNUserNotificationCenter.current().delegate = self
        AlertNotificationService.shared.clearBadge()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AlertNotificationService.shared.clearBadge()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension HomeFloorplanAppDelegate: UNUserNotificationCenterDelegate {

    /// Chiamato quando arriva una notifica mentre l'app è in foreground.
    /// Restituiamo .banner + .sound per mostrarla comunque.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

// MARK: - UIWindow subclass
// Nota: non viene usata direttamente — mantenuta per riferimento futuro
// se si dovesse passare a un lifecycle UIKit puro.
