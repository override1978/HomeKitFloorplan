import SwiftUI
import SwiftData

// MARK: - EnvironmentSettingsView

/// Impostazioni Ambiente unificate:
/// - Sensore esterno (outdoor room)
/// - Toggle notifiche + soglie di allerta
struct EnvironmentSettingsView: View {

    @Environment(\.modelContext) private var modelContext

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = true

    @AppStorage("outdoorRoomName")
    private var outdoorRoomName: String = ""

    @State private var availableRooms: [String] = []

    var body: some View {
        Form {
            // MARK: - Sensore Esterno
            Section {
                if availableRooms.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(String(localized: "settings.environment.noReadings",
                                    defaultValue: "No readings available. Go to the Environment Dashboard to sample sensors."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(selection: $outdoorRoomName) {
                        Text(String(localized: "settings.environment.outdoorRoom.none",
                                    defaultValue: "None")).tag("")
                        ForEach(availableRooms, id: \.self) { room in
                            Text(room).tag(room)
                        }
                    } label: {
                        Label(String(localized: "settings.environment.outdoorRoom",
                                     defaultValue: "Outdoor room"), systemImage: "cloud.sun")
                    }
                }
            } header: {
                Text(String(localized: "settings.environment.outdoor.header",
                            defaultValue: "Outdoor Sensor"))
            } footer: {
                Text(String(localized: "settings.environment.footer",
                            defaultValue: "Select the HomeKit room containing your outdoor sensor (e.g. an external Netatmo module). The AI will not suggest HVAC or ventilation actions for it."))
            }

            // MARK: - Notifiche
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
        .navigationTitle(String(localized: "settings.environment.header",
                                defaultValue: "Environment"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadAvailableRooms() }
    }

    private func loadAvailableRooms() {
        let all = (try? modelContext.fetch(FetchDescriptor<SensorReading>())) ?? []
        availableRooms = Array(Set(all.map(\.roomName))).sorted()
    }
}
