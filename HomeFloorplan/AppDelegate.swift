import UIKit
import UserNotifications
import CloudKit

extension Notification.Name {
    static let cloudKitRemoteNotificationReceived = Notification.Name("cloudKitRemoteNotificationReceived")
}

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
        application.registerForRemoteNotifications()
        SyncDiagnosticsLogger.log("App didFinishLaunching; registered for remote notifications")
        AlertNotificationService.shared.clearBadge()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        SyncDiagnosticsLogger.log("App didBecomeActive")
        AlertNotificationService.shared.clearBadge()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        SyncDiagnosticsLogger.log("Remote notifications registration succeeded")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SyncDiagnosticsLogger.log("Remote notifications registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let keys = userInfo.keys.map { "\($0)" }.sorted().joined(separator: ",")
        SyncDiagnosticsLogger.log("Remote notification received keys=[\(keys)]")
        if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            SyncDiagnosticsLogger.log("CloudKit remote notification accepted; posted deterministic fetch trigger")
            NotificationCenter.default.post(name: .cloudKitRemoteNotificationReceived, object: nil)
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
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
