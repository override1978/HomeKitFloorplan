import Foundation
import UserNotifications

// MARK: - AlertLevel

enum AlertLevel {
    case warning
    case danger
}

// MARK: - AlertNotificationService

/// Gestisce l'invio di notifiche locali per alert ambientali.
/// Deduplicazione tramite cooldown in memoria: stesso tipo+stanza non genera
/// più di una notifica ogni `cooldownInterval` secondi (default 30 min).
final class AlertNotificationService {

    // MARK: Singleton

    static let shared = AlertNotificationService()

    /// Intervallo minimo tra due notifiche per lo stesso sensore+stanza (secondi).
    var cooldownInterval: TimeInterval = 30 * 60   // 30 minuti

    /// Timestamp dell'ultima notifica inviata per identifier tipo+stanza.
    private var lastSentDates: [String: Date] = [:]

    private init() {}

    // MARK: - Permessi

    /// Richiede il permesso per le notifiche (chiamare all'avvio dell'app).
    func requestAuthorization() {
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

    // MARK: - Invio alert

    /// Invia una notifica locale per il superamento di una soglia.
    /// - Suono differenziato per categoria: safety → defaultRingtone, health → default, comfort → nessuno
    /// - Badge incrementale basato sulle notifiche già consegnate
    /// - Cooldown: non reinvia per lo stesso tipo+stanza prima che sia trascorso `cooldownInterval`
    func sendAlert(sensorType: SensorServiceType, roomName: String, value: Double, level: AlertLevel) {
        // NOTIFICHE DISABILITATE — riabilitare rimuovendo questo return
        return

        let identifier = "\(sensorType.rawValue)-\(roomName)"

        // Cooldown: ignora se è già stata inviata una notifica di recente
        if let lastSent = lastSentDates[identifier],
           Date().timeIntervalSince(lastSent) < cooldownInterval {
            dprint("🔕 AlertNotification cooldown attivo per \(identifier), salto invio")
            return
        }
        lastSentDates[identifier] = Date()

        let content = UNMutableNotificationContent()
        content.title = alertTitle(for: sensorType, level: level)
        content.body = alertBody(for: sensorType, roomName: roomName, value: value, level: level)
        content.categoryIdentifier = "ENVIRONMENT_ALERT"

        // Suono in base alla categoria di urgenza del sensore
        switch sensorType.notificationCategory {
        case .safety:
            // Suono ringtone — più prominente di .default per alert di sicurezza
            content.sound = .defaultRingtone
        case .health:
            content.sound = .default
        case .comfort:
            content.sound = nil  // silenzioso — solo banner visivo
        }

        // Badge incrementale tramite setBadgeCount (iOS 16+, non deprecated).
        // Legge il badge corrente dalla delivered notifications count e aggiunge 1.
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            // Usiamo il numero di notifiche consegnate come proxy del badge corrente,
            // poi incrementiamo di 1 per quella in arrivo.
            let newBadge = delivered.count + 1
            UNUserNotificationCenter.current().setBadgeCount(newBadge) { _ in }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    dprint("❌ AlertNotification: \(error)")
                }
            }
        }
    }

    /// Azzera il badge dell'icona app (chiamare quando l'utente apre la Dashboard Ambiente).
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error {
                dprint("❌ AlertNotification clearBadge: \(error)")
            }
        }
    }

    // MARK: - Testi notifica

    private func alertTitle(for type: SensorServiceType, level: AlertLevel) -> String {
        let prefix = level == .danger
            ? String(localized: "alert.prefix.alarm",   defaultValue: "⚠️ ALARM")
            : String(localized: "alert.prefix.warning", defaultValue: "⚠️ Warning")
        switch type {
        case .temperature:
            return "\(prefix): \(String(localized: "alert.title.temperature",    defaultValue: "High Temperature"))"
        case .humidity:
            return "\(prefix): \(String(localized: "alert.title.humidity",       defaultValue: "Humidity Out of Range"))"
        case .airQuality:
            return "\(prefix): \(String(localized: "alert.title.airQuality",     defaultValue: "Poor Air Quality"))"
        case .carbonMonoxide:
            return "\(prefix): \(String(localized: "alert.title.carbonMonoxide", defaultValue: "Carbon Monoxide"))"
        case .carbonDioxide:
            return "\(prefix): \(String(localized: "alert.title.carbonDioxide",  defaultValue: "High CO₂ Level"))"
        case .smoke:
            return "\(prefix): \(String(localized: "alert.title.smoke",          defaultValue: "Smoke Detected"))"
        case .vocDensity:
            return "\(prefix): \(String(localized: "alert.title.vocDensity",     defaultValue: "High VOC Levels"))"
        case .lightSensor:
            return "\(prefix): \(String(localized: "alert.title.lightSensor",    defaultValue: "High Light Level"))"
        case .outdoorTemperature, .outdoorHumidity:
            return "\(prefix): \(type.displayName)"
        }
    }

    private func alertBody(
        for type: SensorServiceType,
        roomName: String,
        value: Double,
        level: AlertLevel
    ) -> String {
        let formattedValue = formatValue(value, for: type)
        let levelText = level == .danger
            ? String(localized: "alert.level.danger",  defaultValue: "critical level")
            : String(localized: "alert.level.warning", defaultValue: "warning level")

        // Build body using localized template strings.
        // Each key maps to a sentence with %1$@ = room, %2$@ = value, %3$@ = level.
        switch type {
        case .temperature:
            let tmpl = String(localized: "alert.body.temperature",
                              defaultValue: "In %1$@ the temperature reached %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .humidity:
            let tmpl = String(localized: "alert.body.humidity",
                              defaultValue: "In %1$@ the humidity is at %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .airQuality:
            let tmpl = String(localized: "alert.body.airQuality",
                              defaultValue: "In %1$@ the air quality reached %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .carbonMonoxide:
            let tmpl = String(localized: "alert.body.carbonMonoxide",
                              defaultValue: "In %1$@ the CO level is %2$@ (%3$@). Ventilate immediately.")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .carbonDioxide:
            let tmpl = String(localized: "alert.body.carbonDioxide",
                              defaultValue: "In %1$@ CO₂ reached %2$@ (%3$@). Ventilate the room.")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .smoke:
            let tmpl = String(localized: "alert.body.smoke",
                              defaultValue: "Smoke detected in %1$@. Please check the area.")
            return String(format: tmpl, roomName)
        case .vocDensity:
            let tmpl = String(localized: "alert.body.vocDensity",
                              defaultValue: "In %1$@ the VOC concentration is %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .lightSensor:
            let tmpl = String(localized: "alert.body.lightSensor",
                              defaultValue: "In %1$@ the light level reached %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .outdoorTemperature, .outdoorHumidity:
            return "\(type.displayName) in \(roomName): \(formattedValue)"
        }
    }

    private func formatValue(_ value: Double, for type: SensorServiceType) -> String {
        let unit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        ) ?? .celsius
        switch type {
        case .temperature:    return unit.format(value)
        case .humidity:       return String(format: "%.0f%%", value)
        case .airQuality:     return String(format: "%.0f/5", value)
        case .carbonMonoxide: return String(format: "%.1f ppm", value)
        case .carbonDioxide:  return String(format: "%.0f ppm", value)
        case .smoke:
            return value >= 1
                ? String(localized: "smoke.detected",    defaultValue: "detected")
                : String(localized: "smoke.notDetected", defaultValue: "not detected")
        case .vocDensity:     return String(format: "%.0f µg/m³", value)
        case .lightSensor:    return String(format: "%.0f lux", value)
        case .outdoorTemperature: return unit.format(value)
        case .outdoorHumidity:    return String(format: "%.0f%%", value)
        }
    }
}
