import SwiftUI

// MARK: - EnvironmentNotificationsSettingsView

/// Impostazioni per le notifiche ambientali:
/// - Toggle master per abilitare/disabilitare tutte le notifiche di soglia
/// - NavigationLink verso AlertThresholdSettingsView per configurare le singole soglie
struct EnvironmentNotificationsSettingsView: View {

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $alertNotificationsEnabled) {
                    Label(
                        String(localized: "settings.notifications.toggle",
                               defaultValue: "Environmental notifications"),
                        systemImage: "bell.badge"
                    )
                }
                .onChange(of: alertNotificationsEnabled) { _, enabled in
                    if enabled {
                        AlertNotificationService.shared.requestAuthorization()
                    }
                }

                if alertNotificationsEnabled {
                    NavigationLink {
                        AlertThresholdSettingsView()
                    } label: {
                        Label(
                            String(localized: "settings.notifications.thresholds",
                                   defaultValue: "Configure thresholds"),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }
            } footer: {
                Text(alertNotificationsEnabled
                     ? String(localized: "settings.notifications.footer.on",
                              defaultValue: "Notifications are sent at most every 30 minutes per sensor.")
                     : String(localized: "settings.notifications.footer.off",
                              defaultValue: "No alerts will be sent while notifications are disabled."))
            }
        }
        .navigationTitle(String(localized: "settings.notifications.environment.title",
                                defaultValue: "Environment Notifications"))
        .navigationBarTitleDisplayMode(.large)
    }
}
