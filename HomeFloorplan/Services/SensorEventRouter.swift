import Foundation
import HomeKit

// MARK: - SensorEventRouter

/// Routes real-time HMAccessoryDelegate value-change callbacks to AlertNotificationService.
/// Plugged into HomeKitService via the injectable `sensorEventRouter` property.
///
/// Priority tiers (Sprint 23.A):
/// - High (immediate): smoke detected, carbonMonoxide ≥ warning, carbonDioxide ≥ danger, temperature > 38 °C
/// - Medium (debounce 2 min): temperature/humidity at warning, airQuality ≥ fair (≥ 3), vocDensity ≥ warning
///
/// The `ambientalAI` weak ref is wired up in HomeFloorplanApp.init so high-priority events
/// also bypass the normal 15-min analysis gate for the affected room.
final class SensorEventRouter {

    static let shared = SensorEventRouter()

    /// Minimum interval between medium-priority alerts for the same sensor+room key.
    private let mediumDebounceInterval: TimeInterval = 2 * 60

    /// Last medium-priority send timestamps, keyed by "sensorType-roomName".
    private var lastMediumAlert: [String: Date] = [:]

    /// Weak reference to AmbientalAIService; assigned from HomeFloorplanApp after both objects exist.
    weak var ambientalAI: AmbientalAIService?

    private init() {}

    // MARK: - Route

    /// Called from HMAccessoryDelegate on every sensor characteristic value change.
    func route(characteristic: HMCharacteristic, value: Any, accessory: HMAccessory) {
        guard let sensorType = SensorServiceType.allCases.first(where: {
            $0.hmCharacteristicType == characteristic.characteristicType
        }) else { return }

        let roomName = accessory.room?.name ?? ""
        guard let numericValue = numericDouble(from: value, sensorType: sensorType) else { return }
        guard let (priority, level) = classify(sensorType: sensorType, value: numericValue) else { return }

        let key = "\(sensorType.rawValue)-\(roomName)"

        switch priority {
        case .high:
            AlertNotificationService.shared.sendAlert(
                sensorType: sensorType, roomName: roomName, value: numericValue, level: level
            )
            if let ai = ambientalAI {
                Task { @MainActor in ai.requestImmediateAnalysis(for: roomName) }
            }

        case .medium:
            let now = Date()
            if let last = lastMediumAlert[key],
               now.timeIntervalSince(last) < mediumDebounceInterval { return }
            lastMediumAlert[key] = now
            AlertNotificationService.shared.sendAlert(
                sensorType: sensorType, roomName: roomName, value: numericValue, level: level
            )
        }
    }

    // MARK: - Priority Classification

    private enum Priority { case high, medium }

    private func classify(
        sensorType: SensorServiceType,
        value: Double
    ) -> (priority: Priority, level: AlertLevel)? {
        switch sensorType {
        case .smoke:
            guard value >= sensorType.defaultWarning else { return nil }
            return (.high, .danger)

        case .carbonMonoxide:
            guard value >= sensorType.defaultWarning else { return nil }
            return (.high, value >= sensorType.defaultDanger ? .danger : .warning)

        case .carbonDioxide:
            if value >= sensorType.defaultDanger  { return (.high, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            return nil

        case .temperature:
            if value > 38.0 || value >= sensorType.defaultDanger { return (.high, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            if let ld = sensorType.defaultLowDanger,  value < ld { return (.medium, .danger) }
            if let lw = sensorType.defaultLowWarning, value < lw { return (.medium, .warning) }
            return nil

        case .humidity:
            if value >= sensorType.defaultDanger  { return (.medium, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            if let ld = sensorType.defaultLowDanger,  value < ld { return (.medium, .danger) }
            if let lw = sensorType.defaultLowWarning, value < lw { return (.medium, .warning) }
            return nil

        case .airQuality:
            if value >= sensorType.defaultDanger  { return (.medium, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            return nil

        case .vocDensity, .pm25, .pm10:
            if value >= sensorType.defaultDanger  { return (.medium, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            return nil

        case .lightSensor:
            if value >= sensorType.defaultDanger  { return (.medium, .danger) }
            if value >= sensorType.defaultWarning { return (.medium, .warning) }
            return nil

        case .outdoorTemperature, .outdoorHumidity:
            return nil  // outdoor weather types do not generate in-app priority alerts
        }
    }

    // MARK: - Value Normalization

    private func numericDouble(from value: Any, sensorType: SensorServiceType) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float  { return Double(f) }
        if let i = value as? Int    { return Double(i) }
        if sensorType.isBooleanAlert, let b = value as? Bool { return b ? 1.0 : 0.0 }
        return nil
    }
}
