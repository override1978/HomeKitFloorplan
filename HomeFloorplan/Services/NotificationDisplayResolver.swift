import Foundation

// MARK: - NotificationDisplayResolver
//
// Pure static resolver that computes locale-correct display strings at render time
// from a notification's stable semanticKey, bypassing whatever locale was current
// when the notification was originally persisted to SwiftData.
//
// SemanticKey formats handled:
//   environment|{room}|{sensorTypeRaw}
//   anomaly|{room}|{sensorTypeRaw}|{kind}
//   maintenance|{kind}|{uuid}
//   predictive|{room}|{sensorTypeRaw}|{weekday}
//   occupancy|hvac|arrival
//   automationOpportunity|{id}
//   learning|{id}
//
// Returns nil for keys where the string requires dynamic parameters that are
// only available at creation time (e.g. occupancy.why needs confidenceLabel).
// In those cases the view falls back to the stored string via the `?? storedValue`
// pattern in ProactiveNotification's display computed properties.

enum NotificationDisplayResolver {

    // MARK: - Headline

    static func headline(for notification: ProactiveNotification) -> String? {
        let parts = notification.semanticKey.components(separatedBy: "|")
        guard let kind = parts.first else { return nil }

        switch kind {
        case "environment":
            guard parts.count >= 3,
                  let sensorType = SensorServiceType(rawValue: parts[2])
            else { return nil }
            return EnvironmentalAlertBuilder.headline(forSensorType: sensorType, room: parts[1])

        case "anomaly":
            guard parts.count >= 3,
                  let sensorType = SensorServiceType(rawValue: parts[2])
            else { return nil }
            return String(
                format: String(localized: "notif.anomaly.headline",
                               defaultValue: "%1$@ anomaly in %2$@"),
                sensorType.displayName, parts[1])

        case "predictive":
            guard parts.count >= 3,
                  let sensorType = SensorServiceType(rawValue: parts[2])
            else { return nil }
            return String(
                format: String(localized: "notif.predictive.headline",
                               defaultValue: "Expected %@ peak in %@"),
                sensorType.displayName, parts[1])

        case "occupancy":
            return String(localized: "notif.occupancy.headline",
                          defaultValue: "Arrival expected soon")

        case "automationOpportunity":
            return String(localized: "notif.opportunity.headline",
                          defaultValue: "Suggested automation")

        case "learning":
            return String(localized: "notif.learning.headline",
                          defaultValue: "New behaviour learned")

        default:
            return nil
        }
    }

    // MARK: - Recommendation

    static func recommendation(for notification: ProactiveNotification) -> String? {
        let parts = notification.semanticKey.components(separatedBy: "|")
        guard let kind = parts.first else { return nil }

        switch kind {
        case "environment":
            guard parts.count >= 3,
                  let sensorType = SensorServiceType(rawValue: parts[2])
            else { return nil }
            return EnvironmentalAlertBuilder.recommendation(forSensorType: sensorType)

        case "anomaly":
            return String(localized: "notif.anomaly.rec",
                          defaultValue: "Check the sensor and make sure it is positioned correctly.")

        case "maintenance":
            return String(localized: "notif.maintenance.rec",
                          defaultValue: "Verify that the device is working correctly.")

        case "predictive":
            return String(localized: "notif.predictive.rec",
                          defaultValue: "Open windows or activate ventilation in advance.")

        case "occupancy":
            return String(localized: "notif.occupancy.rec",
                          defaultValue: "Turn on heating/cooling now to arrive home at the right temperature.")

        default:
            return nil
        }
    }

    // MARK: - Body

    /// Reconstructs the anomaly body in the current locale.
    /// When `currentValue` carries the stored numeric detail (stddev / sensor value),
    /// the full precise body is produced; otherwise a simplified static fallback is used
    /// for old records that pre-date this field.
    /// Returns nil for non-anomaly categories (view uses stored `body` directly).
    static func body(for notification: ProactiveNotification) -> String? {
        let parts = notification.semanticKey.components(separatedBy: "|")
        guard parts.first == "anomaly", parts.count >= 4,
              let sensorType = SensorServiceType(rawValue: parts[2])
        else { return nil }

        let kind = parts[3]

        if let valueStr = notification.currentValue, let value = Double(valueStr) {
            switch kind {
            case "oscillating":
                return String(format:
                    String(localized: "anomaly.oscillating.detail",
                           defaultValue: "Letture instabili ±%.1f%@ nelle ultime 2h. Il sensore potrebbe essere in avaria."),
                    value, sensorType.unit)
            case "stuck":
                return String(format:
                    String(localized: "anomaly.stuck.detail",
                           defaultValue: "Valore invariato (%.1f%@) per oltre 30 minuti. Il sensore potrebbe essere bloccato."),
                    value, sensorType.unit)
            case "outofrange":
                return String(format:
                    String(localized: "anomaly.outofrange.detail",
                           defaultValue: "Valore anomalo rilevato (%.1f%@) — impossibile in condizioni normali."),
                    value, sensorType.unit)
            default:
                return nil
            }
        } else {
            // Old records without stored numericDetail: simplified static text in current locale.
            switch kind {
            case "oscillating":
                return String(localized: "notif.anomaly.body.oscillating",
                              defaultValue: "Unstable readings in the last 2h. The sensor may be malfunctioning.")
            case "stuck":
                return String(localized: "notif.anomaly.body.stuck",
                              defaultValue: "Value unchanged for over 30 minutes. The sensor may be stuck.")
            case "outofrange":
                return String(localized: "notif.anomaly.body.outofrange",
                              defaultValue: "Anomalous value detected — impossible under normal conditions.")
            default:
                return nil
            }
        }
    }

    // MARK: - Why Explanation

    static func whyExplanation(for notification: ProactiveNotification) -> String? {
        let parts = notification.semanticKey.components(separatedBy: "|")
        guard let kind = parts.first else { return nil }

        switch kind {
        case "environment":
            guard parts.count >= 3,
                  let sensorType = SensorServiceType(rawValue: parts[2])
            else { return nil }
            return EnvironmentalAlertBuilder.whyExplanation(forSensorType: sensorType)

        case "maintenance":
            return String(localized: "notif.maintenance.why",
                          defaultValue: "Anomaly detected by comparing usage history.")

        // occupancy.why and predictive.why include dynamic parameters (confidenceLabel,
        // exceedanceRate, sampleCount) — not recoverable from the key alone.
        // The stored string is used as fallback via ?? in the display property.
        default:
            return nil
        }
    }
}
