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
                               defaultValue: "Notifiche ambientali"),
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
                                   defaultValue: "Configura soglie"),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }
            } footer: {
                Text(alertNotificationsEnabled
                     ? String(localized: "settings.notifications.footer.on",
                              defaultValue: "Le notifiche vengono inviate al massimo ogni 30 minuti per sensore.")
                     : String(localized: "settings.notifications.footer.off",
                              defaultValue: "Nessun alert sarà inviato finché le notifiche sono disabilitate."))
            }
        }
        .navigationTitle(String(localized: "settings.notifications.environment.title",
                                defaultValue: "Notifiche Ambiente"))
        .navigationBarTitleDisplayMode(.large)
    }
}
