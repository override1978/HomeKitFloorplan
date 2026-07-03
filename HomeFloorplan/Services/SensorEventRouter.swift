import Foundation
import HomeKit

// MARK: - SensorEventRouter

/// Routes real-time HMAccessoryDelegate value-change callbacks to immediate AI analysis.
/// Plugged into HomeKitService via the injectable `sensorEventRouter` property.
///
/// Priority tiers (Sprint 23.A):
/// - High (immediate): smoke detected, carbonMonoxide ≥ warning, carbonDioxide ≥ danger, temperature > 38 °C
/// - Medium (debounce 2 min): temperature/humidity at warning, airQuality ≥ fair (≥ 3), vocDensity ≥ warning
///
/// The `ambientalAI` weak ref is wired up in HomeFloorplanApp.init so priority events
/// bypass the normal 15-min analysis gate for the affected room. Notification delivery
/// is handled later by the unified PersistedHomeInsight pipeline.
final class SensorEventRouter {

    static let shared = SensorEventRouter()

    /// Minimum interval between medium-priority analysis requests for the same sensor+room key.
    private let mediumDebounceInterval: TimeInterval = 2 * 60

    /// Last medium-priority analysis timestamps, keyed by "sensorType-roomName".
    private var lastMediumAnalysisRequest: [String: Date] = [:]

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
        guard let priority = classify(sensorType: sensorType, value: numericValue) else { return }

        let key = "\(sensorType.rawValue)-\(roomName)"

        switch priority {
        case .high:
            if let ai = ambientalAI {
                Task { @MainActor in ai.requestImmediateAnalysis(for: roomName) }
            }

        case .medium:
            let now = Date()
            if let last = lastMediumAnalysisRequest[key],
               now.timeIntervalSince(last) < mediumDebounceInterval { return }
            lastMediumAnalysisRequest[key] = now
            if let ai = ambientalAI {
                Task { @MainActor in ai.requestImmediateAnalysis(for: roomName) }
            }
        }
    }

    // MARK: - Priority Classification

    private enum Priority { case high, medium }

    private func classify(
        sensorType: SensorServiceType,
        value: Double
    ) -> Priority? {
        switch sensorType {
        case .smoke:
            guard value >= sensorType.defaultWarning else { return nil }
            return .high

        case .carbonMonoxide:
            guard value >= sensorType.defaultWarning else { return nil }
            return .high

        case .carbonDioxide:
            if value >= sensorType.defaultDanger  { return .high }
            if value >= sensorType.defaultWarning { return .medium }
            return nil

        case .temperature:
            if value > 38.0 || value >= sensorType.defaultDanger { return .high }
            if value >= sensorType.defaultWarning { return .medium }
            if let ld = sensorType.defaultLowDanger,  value < ld { return .medium }
            if let lw = sensorType.defaultLowWarning, value < lw { return .medium }
            return nil

        case .humidity:
            if value >= sensorType.defaultDanger  { return .medium }
            if value >= sensorType.defaultWarning { return .medium }
            if let ld = sensorType.defaultLowDanger,  value < ld { return .medium }
            if let lw = sensorType.defaultLowWarning, value < lw { return .medium }
            return nil

        case .airQuality:
            if value >= sensorType.defaultDanger  { return .medium }
            if value >= sensorType.defaultWarning { return .medium }
            return nil

        case .vocDensity, .pm25, .pm10:
            if value >= sensorType.defaultDanger  { return .medium }
            if value >= sensorType.defaultWarning { return .medium }
            return nil

        case .lightSensor:
            if value >= sensorType.defaultDanger  { return .medium }
            if value >= sensorType.defaultWarning { return .medium }
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
