import SwiftUI
import HomeKit
import UserNotifications

// MARK: - SecurityNotificationsSettingsView

/// Impostazioni per le notifiche di sicurezza:
/// - Toggle master per abilitare/disabilitare tutte le notifiche di sicurezza
/// - Lista degli accessori monitorati (SecuritySystem + sensori di allarme)
/// - Spiegazione del comportamento (solo eventi .alarm: antifurto, fumo, CO, acqua)
struct SecurityNotificationsSettingsView: View {

    @Environment(HomeKitService.self) private var homeKit

    @AppStorage(SecurityNotificationService.enabledKey)
    private var securityNotificationsEnabled: Bool = true

    var body: some View {
        Form {
            // MARK: Master toggle
            Section {
                Toggle(isOn: $securityNotificationsEnabled) {
                    Label(
                        String(localized: "settings.security.notifications.toggle",
                               defaultValue: "Notifiche di sicurezza"),
                        systemImage: "bell.badge.shield.half.filled"
                    )
                }
                .onChange(of: securityNotificationsEnabled) { _, enabled in
                    if enabled {
                        requestNotificationPermission()
                    }
                }
            } footer: {
                Text(securityNotificationsEnabled
                     ? String(localized: "settings.security.notifications.footer.on",
                              defaultValue: "Riceverai una notifica critica quando scatta l'antifurto o viene rilevato fumo, CO o perdita d'acqua. Le notifiche vengono inviate anche con l'app in background.")
                     : String(localized: "settings.security.notifications.footer.off",
                              defaultValue: "Nessuna notifica di sicurezza sarà inviata."))
            }

            // MARK: Accessori monitorati (solo se abilitato)
            if securityNotificationsEnabled {
                monitoredAccessoriesSection
            }

            // MARK: Info comportamento
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    infoRow(
                        icon: "shield.lefthalf.filled",
                        color: .red,
                        title: String(localized: "settings.security.notifications.info.alarm.title",
                                      defaultValue: "Antifurto scattato"),
                        subtitle: String(localized: "settings.security.notifications.info.alarm.subtitle",
                                          defaultValue: "Notifica critica immediata")
                    )
                    infoRow(
                        icon: "smoke.fill",
                        color: .orange,
                        title: String(localized: "settings.security.notifications.info.smoke.title",
                                      defaultValue: "Fumo rilevato"),
                        subtitle: String(localized: "settings.security.notifications.info.smoke.subtitle",
                                          defaultValue: "Notifica critica immediata")
                    )
                    infoRow(
                        icon: "aqi.high",
                        color: .orange,
                        title: String(localized: "settings.security.notifications.info.co.title",
                                      defaultValue: "Monossido di carbonio"),
                        subtitle: String(localized: "settings.security.notifications.info.co.subtitle",
                                          defaultValue: "Notifica critica immediata")
                    )
                    infoRow(
                        icon: "drop.fill",
                        color: .blue,
                        title: String(localized: "settings.security.notifications.info.leak.title",
                                      defaultValue: "Perdita d'acqua"),
                        subtitle: String(localized: "settings.security.notifications.info.leak.subtitle",
                                          defaultValue: "Notifica critica immediata")
                    )
                    Divider()
                    infoRow(
                        icon: "door.left.hand.open",
                        color: .secondary,
                        title: String(localized: "settings.security.notifications.info.contact.title",
                                      defaultValue: "Porte/finestre, movimento, presenza"),
                        subtitle: String(localized: "settings.security.notifications.info.contact.subtitle",
                                          defaultValue: "Nessuna notifica — aggiornano solo l'UI")
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text(String(localized: "settings.security.notifications.info.header",
                            defaultValue: "Cosa genera una notifica"))
            }
        }
        .navigationTitle(String(localized: "settings.security.notifications.title",
                                defaultValue: "Notifiche Sicurezza"))
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Accessori monitorati

    @ViewBuilder
    private var monitoredAccessoriesSection: some View {
        let accessories = securityAccessories
        if accessories.isEmpty {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(String(localized: "settings.security.notifications.noAccessories",
                                defaultValue: "Nessun sensore di sicurezza trovato in HomeKit."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.security.notifications.monitored.header",
                            defaultValue: "Sensori monitorati"))
            }
        } else {
            Section {
                ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                    SecurityAccessoryRow(
                        accessory: accessory,
                        adapter: AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                    )
                }
            } header: {
                Text(String(localized: "settings.security.notifications.monitored.header",
                            defaultValue: "Sensori monitorati"))
            } footer: {
                Text(String(localized: "settings.security.notifications.monitored.footer",
                            defaultValue: "L'antifurto è sempre monitorato. I sensori di fumo, CO e acqua vengono inclusi automaticamente se presenti."))
            }
        }
    }

    /// Tutti gli accessori che possono generare una notifica .alarm
    private var securityAccessories: [HMAccessory] {
        guard let home = homeKit.currentHome else { return [] }
        return home.accessories.filter { acc in
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            // Antifurto
            if adapter is SecuritySystemAdapter { return true }
            // Sensori con urgency .alarm (fumo, CO, leak)
            if let sensorAdapter = adapter as? SensorAdapter {
                let kind = sensorAdapter.primarySensorKind
                return kind == .smoke || kind == .carbonMonoxide || kind == .leak
            }
            return false
        }
    }

    // MARK: - Helpers

    private func infoRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert]
            ) { _, _ in }
        }
    }
}

// MARK: - SecurityAccessoryRow

private struct SecurityAccessoryRow: View {

    let accessory: HMAccessory
    let adapter: any AccessoryAdapter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.subheadline)
                if let roomName = accessory.room?.name {
                    Text(roomName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(localized: "settings.security.notifications.alwaysOn",
                        defaultValue: "Sempre attivo"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if adapter is SecuritySystemAdapter { return "shield.lefthalf.filled" }
        if let sensor = adapter as? SensorAdapter {
            switch sensor.primarySensorKind {
            case .smoke:          return "smoke.fill"
            case .carbonMonoxide: return "aqi.high"
            case .leak:           return "drop.fill"
            default:              break
            }
        }
        return "sensor.tag.radiowaves.forward"
    }

    private var iconColor: Color {
        if adapter is SecuritySystemAdapter { return .red }
        if let sensor = adapter as? SensorAdapter {
            switch sensor.primarySensorKind {
            case .smoke, .carbonMonoxide: return .orange
            case .leak:                   return .blue
            default:                      break
            }
        }
        return .orange
    }
}
