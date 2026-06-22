import Foundation
import UIKit
import UserNotifications

// MARK: - AlertLevel

enum AlertLevel: String, Codable {
    case warning
    case danger

    var priority: Int {
        switch self {
        case .warning: return 1
        case .danger: return 2
        }
    }
}

struct EnvironmentalAlertCandidate {
    let sensorType: SensorServiceType
    let roomName: String
    let value: Double
    let level: AlertLevel
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
    private var lastSentLevels: [String: AlertLevel] = [:]

    private static let cooldownStoreKey = "environment.alertNotificationCooldowns.v1"
    private let cooldownRetentionInterval: TimeInterval = 24 * 60 * 60

    private struct PersistedCooldown: Codable {
        let sentAt: Date
        let level: AlertLevel
    }

    private init() {
        loadCooldowns()
        pruneExpiredCooldowns()
    }

    // MARK: - Permessi

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

    // MARK: - Invio alert

    /// Invia una notifica locale per il superamento di una soglia.
    /// - Suono differenziato per categoria: safety → defaultRingtone, health → default, comfort → nessuno
    /// - Badge incrementale basato sulle notifiche già consegnate
    /// - Cooldown: non reinvia per lo stesso tipo+stanza prima che sia trascorso `cooldownInterval`
    func sendAlert(sensorType: SensorServiceType, roomName: String, value: Double, level: AlertLevel) {
        guard UserDefaults.standard.bool(forKey: "alertNotificationsEnabled") else { return }

        let identifier = notificationIdentifier(sensorType: sensorType, roomName: roomName)
        let roomThread = roomThreadIdentifier(roomName)

        // Cooldown: salta solo se lo stato è equivalente o meno grave.
        // Warning → Danger passa subito, perché è escalation reale.
        if shouldCoalesce(identifier: identifier, level: level) {
            dprint("🔕 AlertNotification coalesced \(identifier) (\(level))")
            return
        }
        recordCooldown(identifier: identifier, level: level)

        let content = UNMutableNotificationContent()
        content.title = alertTitle(for: sensorType, level: level)
        content.body = alertBody(for: sensorType, roomName: roomName, value: value, level: level)
        content.categoryIdentifier = "ENVIRONMENT_ALERT"
        content.threadIdentifier = roomThread
        content.targetContentIdentifier = identifier

        // Suono in base alla categoria di urgenza del sensore
        switch sensorType.notificationCategory {
        case .safety:
            // Suono ringtone — più prominente di .default per alert di sicurezza
            content.sound = .defaultRingtone
            content.interruptionLevel = .timeSensitive
        case .health:
            content.sound = .default
            content.interruptionLevel = level == .danger ? .timeSensitive : .active
        case .comfort:
            content.sound = nil  // silenzioso — solo banner visivo
            content.interruptionLevel = .passive
        }

        let addRequest = {
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

        guard UIApplication.shared.applicationState != .active else {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
            addRequest()
            return
        }

        // Badge incrementale tramite setBadgeCount (iOS 16+, non deprecated).
        // Legge il badge corrente dalla delivered notifications count e aggiunge 1.
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let newBadge = delivered.count + 1
            UNUserNotificationCenter.current().setBadgeCount(newBadge) { _ in }
            addRequest()
        }
    }

    func sendGroupedAlerts(_ alerts: [EnvironmentalAlertCandidate]) {
        guard UserDefaults.standard.bool(forKey: "alertNotificationsEnabled") else { return }
        guard !alerts.isEmpty else { return }

        let grouped = Dictionary(grouping: alerts) { candidate in
            candidate.sensorType.rawValue
        }

        for group in grouped.values {
            guard let first = group.first else { continue }
            if group.count == 1 {
                sendAlert(
                    sensorType: first.sensorType,
                    roomName: first.roomName,
                    value: first.value,
                    level: first.level
                )
            } else {
                sendTypeSummaryAlert(group)
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

    private func notificationIdentifier(sensorType: SensorServiceType, roomName: String) -> String {
        "environment.\(normalizedIdentifierPart(roomName)).\(sensorType.rawValue)"
    }

    private func roomThreadIdentifier(_ roomName: String) -> String {
        "environment.room.\(normalizedIdentifierPart(roomName))"
    }

    private func typeThreadIdentifier(_ sensorType: SensorServiceType) -> String {
        "environment.type.\(sensorType.rawValue)"
    }

    private func typeSummaryIdentifier(sensorType: SensorServiceType, level: AlertLevel) -> String {
        "environment.summary.\(sensorType.rawValue).\(level == .danger ? "danger" : "warning")"
    }

    private func normalizedIdentifierPart(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    private func sendTypeSummaryAlert(_ alerts: [EnvironmentalAlertCandidate]) {
        guard let first = alerts.first else { return }
        let summaryLevel = alerts.map(\.level).max { $0.priority < $1.priority } ?? first.level
        let identifier = typeSummaryIdentifier(sensorType: first.sensorType, level: summaryLevel)

        if shouldCoalesce(identifier: identifier, level: summaryLevel) {
            dprint("🔕 AlertNotification grouped coalesced \(identifier)")
            return
        }
        recordCooldown(identifier: identifier, level: summaryLevel)

        let sorted = alerts.sorted { $0.value > $1.value }
        let highest = sorted[0]
        let roomNames = sorted.map(\.roomName)
        let roomsText = listText(roomNames)
        let formattedHighest = formatValue(highest.value, for: first.sensorType)
        let levelText = summaryLevel == .danger
            ? String(localized: "alert.level.danger", defaultValue: "critical level")
            : String(localized: "alert.level.warning", defaultValue: "warning level")

        let content = UNMutableNotificationContent()
        content.title = groupedAlertTitle(for: first.sensorType, level: summaryLevel, roomCount: alerts.count)
        content.body = String(
            localized: "alert.grouped.body",
            defaultValue: "\(roomsText) are above \(levelText). Highest: \(formattedHighest) in \(highest.roomName)."
        )
        content.categoryIdentifier = "ENVIRONMENT_ALERT"
        content.threadIdentifier = typeThreadIdentifier(first.sensorType)
        content.targetContentIdentifier = identifier
        applyPresentationPolicy(to: content, sensorType: first.sensorType, level: summaryLevel)

        addNotification(identifier: identifier, content: content)
    }

    private func groupedAlertTitle(for type: SensorServiceType, level: AlertLevel, roomCount: Int) -> String {
        let prefix = level == .danger
            ? String(localized: "alert.prefix.alarm", defaultValue: "⚠️ ALARM")
            : String(localized: "alert.prefix.warning", defaultValue: "⚠️ Warning")
        return "\(prefix): \(type.displayName) in \(roomCount) rooms"
    }

    private func listText(_ values: [String]) -> String {
        guard !values.isEmpty else { return String(localized: "room.none", defaultValue: "No room") }
        if values.count == 1 { return values[0] }
        if values.count == 2 { return "\(values[0]) and \(values[1])" }
        return values.dropLast().joined(separator: ", ") + ", and " + (values.last ?? "")
    }

    private func applyPresentationPolicy(to content: UNMutableNotificationContent,
                                         sensorType: SensorServiceType,
                                         level: AlertLevel) {
        switch sensorType.notificationCategory {
        case .safety:
            content.sound = .defaultRingtone
            content.interruptionLevel = .timeSensitive
        case .health:
            content.sound = .default
            content.interruptionLevel = level == .danger ? .timeSensitive : .active
        case .comfort:
            content.sound = nil
            content.interruptionLevel = .passive
        }
    }

    private func addNotification(identifier: String, content: UNMutableNotificationContent) {
        let addRequest = {
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

        guard UIApplication.shared.applicationState != .active else {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
            addRequest()
            return
        }

        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let newBadge = delivered.count + 1
            UNUserNotificationCenter.current().setBadgeCount(newBadge) { _ in }
            addRequest()
        }
    }

    private func shouldCoalesce(identifier: String, level: AlertLevel) -> Bool {
        guard let lastSent = lastSentDates[identifier],
              Date().timeIntervalSince(lastSent) < cooldownInterval,
              let lastLevel = lastSentLevels[identifier] else {
            return false
        }
        return level.priority <= lastLevel.priority
    }

    private func recordCooldown(identifier: String, level: AlertLevel) {
        lastSentDates[identifier] = Date()
        lastSentLevels[identifier] = level
        pruneExpiredCooldowns()
        saveCooldowns()
    }

    private func loadCooldowns() {
        guard let data = UserDefaults.standard.data(forKey: Self.cooldownStoreKey),
              let decoded = try? JSONDecoder().decode([String: PersistedCooldown].self, from: data) else {
            return
        }
        lastSentDates = decoded.mapValues(\.sentAt)
        lastSentLevels = decoded.mapValues(\.level)
    }

    private func saveCooldowns() {
        var payload: [String: PersistedCooldown] = [:]
        for (identifier, sentAt) in lastSentDates {
            guard let level = lastSentLevels[identifier] else { continue }
            payload[identifier] = PersistedCooldown(sentAt: sentAt, level: level)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cooldownStoreKey)
    }

    private func pruneExpiredCooldowns() {
        let cutoff = Date().addingTimeInterval(-cooldownRetentionInterval)
        let expired = lastSentDates
            .filter { $0.value < cutoff }
            .map(\.key)
        guard !expired.isEmpty else { return }
        for identifier in expired {
            lastSentDates.removeValue(forKey: identifier)
            lastSentLevels.removeValue(forKey: identifier)
        }
    }

    // MARK: - Testi notifica

    private func alertTitle(for type: SensorServiceType, level: AlertLevel) -> String {
        let prefix = level == .danger
            ? String(localized: "alert.prefix.alarm",   defaultValue: "⚠️ ALARM")
            : String(localized: "alert.prefix.warning", defaultValue: "⚠️ Warning")
        switch type {
        case .temperature:
            return "\(prefix): \(String(localized: "alert.title.temperature",    defaultValue: "High temperature"))"
        case .humidity:
            return "\(prefix): \(String(localized: "alert.title.humidity",       defaultValue: "Humidity out of range"))"
        case .airQuality:
            return "\(prefix): \(String(localized: "alert.title.airQuality",     defaultValue: "Low air quality"))"
        case .carbonMonoxide:
            return "\(prefix): \(String(localized: "alert.title.carbonMonoxide", defaultValue: "Carbon monoxide"))"
        case .carbonDioxide:
            return "\(prefix): \(String(localized: "alert.title.carbonDioxide",  defaultValue: "High CO₂"))"
        case .smoke:
            return "\(prefix): \(String(localized: "alert.title.smoke",          defaultValue: "Smoke detected"))"
        case .vocDensity:
            return "\(prefix): \(String(localized: "alert.title.vocDensity",     defaultValue: "High VOC"))"
        case .pm25:
            return "\(prefix): \(String(localized: "alert.title.pm25",           defaultValue: "High PM2.5"))"
        case .pm10:
            return "\(prefix): \(String(localized: "alert.title.pm10",           defaultValue: "High PM10"))"
        case .lightSensor:
            return "\(prefix): \(String(localized: "alert.title.lightSensor",    defaultValue: "High brightness"))"
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
                              defaultValue: "In %1$@ humidity is at %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .airQuality:
            let tmpl = String(localized: "alert.body.airQuality",
                              defaultValue: "In %1$@ air quality is at %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .carbonMonoxide:
            let tmpl = String(localized: "alert.body.carbonMonoxide",
                              defaultValue: "In %1$@ CO level is %2$@ (%3$@). Ventilate immediately.")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .carbonDioxide:
            let tmpl = String(localized: "alert.body.carbonDioxide",
                              defaultValue: "In %1$@ CO₂ reached %2$@ (%3$@). Air out the room.")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .smoke:
            let tmpl = String(localized: "alert.body.smoke",
                              defaultValue: "Smoke detected in %1$@. Check the area.")
            return String(format: tmpl, roomName)
        case .vocDensity:
            let tmpl = String(localized: "alert.body.vocDensity",
                              defaultValue: "In %1$@ VOC concentration is %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .pm25:
            let tmpl = String(localized: "alert.body.pm25",
                              defaultValue: "In %1$@ PM2.5 concentration is %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .pm10:
            let tmpl = String(localized: "alert.body.pm10",
                              defaultValue: "In %1$@ PM10 concentration is %2$@ (%3$@).")
            return String(format: tmpl, roomName, formattedValue, levelText)
        case .lightSensor:
            let tmpl = String(localized: "alert.body.lightSensor",
                              defaultValue: "In %1$@ brightness reached %2$@ (%3$@).")
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
                ? String(localized: "smoke.detected",    defaultValue: "rilevato")
                : String(localized: "smoke.notDetected", defaultValue: "non rilevato")
        case .vocDensity:     return String(format: "%.0f µg/m³", value)
        case .pm25:           return String(format: "%.0f µg/m³", value)
        case .pm10:           return String(format: "%.0f µg/m³", value)
        case .lightSensor:    return String(format: "%.0f lux", value)
        case .outdoorTemperature: return unit.format(value)
        case .outdoorHumidity:    return String(format: "%.0f%%", value)
        }
    }
}
