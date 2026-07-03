import Foundation
import HomeKit
import SwiftData

// MARK: - EnvironmentalSignal

struct EnvironmentalSignal {
    let sensorType:   SensorServiceType
    let roomName:     String
    let currentValue: Double
    let peakValue:    Double
    let durationMins: Int
    let trend:        NotificationTrend
    let priority:     NotificationPriority
    let semanticKey:  String
    let score:        IntelligenceScore
    /// Non-nil when a seasonal baseline adjustment was applied (e.g. summer humidity offset).
    let contextNote:  String?
}

// MARK: - EnvironmentalAlertBuilder

/// Reads recent SensorReading data from SwiftData and produces EnvironmentalSignal candidates.
/// Pure builder — no side effects, no state.
enum EnvironmentalAlertBuilder {

    /// Minimum duration above threshold before a signal is emitted (avoids momentary spikes).
    private static let minDurationMinutes = 15
    /// Lookback window for readings.
    private static let lookbackSeconds: Double = 90 * 60

    // MARK: - Build

    static func build(
        modelContainer: ModelContainer,
        homeKitService: HomeKitService? = nil
    ) async -> [EnvironmentalSignal] {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-lookbackSeconds)

        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let readings = ((try? context.fetch(descriptor)) ?? []) + liveSensorReadings(from: homeKitService)
        guard !readings.isEmpty else { return [] }

        // Group by room + sensorType
        var groups: [String: [SensorReading]] = [:]
        for r in readings {
            let key = "\(r.roomName)|\(r.serviceTypeRaw)"
            groups[key, default: []].append(r)
        }

        var signals: [EnvironmentalSignal] = []
        for (_, group) in groups {
            guard let sig = buildSignal(from: group) else { continue }
            signals.append(sig)
        }
        return signals
    }

    private static func liveSensorReadings(from homeKitService: HomeKitService?) -> [SensorReading] {
        guard let homeKitService else { return [] }

        return homeKitService.allAccessories.flatMap { accessory -> [SensorReading] in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKitService)
            guard let readable = adapter as? any EnvironmentReadable else { return [] }

            let roomName = accessory.room?.name ?? "Home"
            let now = Date()
            return [
                liveReading(
                    type: .temperature,
                    value: readable.environmentTemperature,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .humidity,
                    value: readable.environmentHumidity,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .carbonDioxide,
                    value: readable.environmentCO2,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .pm25,
                    value: readable.environmentPM25,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .pm10,
                    value: readable.environmentPM10,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .vocDensity,
                    value: readable.environmentVOC,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveReading(
                    type: .lightSensor,
                    value: readable.environmentLightLevel.map(Double.init),
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                )
            ].compactMap { $0 }
        }
    }

    private static func liveReading(
        type: SensorServiceType,
        value: Double?,
        accessory: HMAccessory,
        roomName: String,
        timestamp: Date
    ) -> SensorReading? {
        guard let value else { return nil }
        return SensorReading(
            accessoryUUID: accessory.uniqueIdentifier.uuidString,
            serviceType: type,
            roomName: roomName,
            value: value,
            timestamp: timestamp
        )
    }

    private static func buildSignal(from group: [SensorReading]) -> EnvironmentalSignal? {
        guard group.count >= 2, let first = group.first else { return nil }

        let type    = first.serviceType
        // Boolean sensors (smoke, CO in alert mode) and display-only types are handled separately
        guard !type.isBooleanAlert, type != .lightSensor else { return nil }

        let season  = CalendarSeason.current
        let sorted  = group.sorted { $0.timestamp < $1.timestamp }
        let current = sorted.last!.value
        let peak    = sorted.map(\.value).max() ?? current
        let warning = SeasonalBaselineProvider.warningThreshold(for: type, season: season)
        let danger  = SeasonalBaselineProvider.dangerThreshold(for: type, season: season)

        // Only proceed if currently above seasonal warning threshold
        guard current >= warning else { return nil }

        // Duration: how long has it been above warning?
        let firstAbove    = sorted.first { $0.value >= warning }
        let durationMins  = firstAbove.map { Int(Date().timeIntervalSince($0.timestamp) / 60) } ?? 5
        guard durationMins >= minDurationMinutes else { return nil }

        // Trend: compare first half average vs second half average
        let mid        = max(1, sorted.count / 2)
        let firstHalf  = sorted.prefix(mid).map(\.value)
        let secondHalf = sorted.suffix(from: mid).map(\.value)
        let avgFirst   = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let avgSecond  = secondHalf.isEmpty ? current : secondHalf.reduce(0, +) / Double(secondHalf.count)
        let delta      = avgSecond - avgFirst
        let refBase    = max(0.01, abs(avgFirst))
        let relDelta   = abs(delta) / refBase
        let trend: NotificationTrend
        if relDelta < 0.03       { trend = .stable }
        else if delta > 0        { trend = .rising }
        else                     { trend = .falling }

        // Priority: hard (seasonal) threshold + duration + trend
        let isHard  = current >= danger
        let priority: NotificationPriority
        if isHard && trend == .rising                     { priority = .high }
        else if isHard                                     { priority = .medium }
        else if durationMins >= 45 && trend != .falling   { priority = .medium }
        else                                               { priority = .low }

        // Score
        let score = IntelligenceScore(
            relevance:     min(1.0, Double(durationMins) / 60.0),
            confidence:    min(1.0, Double(group.count) / 6.0),
            urgency:       isHard ? 0.80 : 0.45,
            actionability: 0.75,
            novelty:       durationMins < 30 ? 0.80 : 0.40
        )

        return EnvironmentalSignal(
            sensorType:   type,
            roomName:     first.roomName,
            currentValue: current,
            peakValue:    peak,
            durationMins: durationMins,
            trend:        trend,
            priority:     priority,
            semanticKey:  "environment|\(first.roomName)|\(type.rawValue)",
            score:        score,
            contextNote:  SeasonalBaselineProvider.contextNote(for: type, season: season)
        )
    }

    // MARK: - Message generation

    static func headline(for signal: EnvironmentalSignal) -> String {
        let room = signal.roomName
        switch signal.sensorType {
        case .temperature:
            return String(format: String(localized: "notif.env.temp.headline",     defaultValue: "High temperature in %@"),   room)
        case .humidity:
            return String(format: String(localized: "notif.env.humidity.headline", defaultValue: "High humidity in %@"),       room)
        case .carbonDioxide:
            return String(format: String(localized: "notif.env.co2.headline",      defaultValue: "High CO₂ in %@"),           room)
        case .vocDensity:
            return String(format: String(localized: "notif.env.voc.headline",      defaultValue: "High VOC in %@"),           room)
        case .pm25:
            return String(format: String(localized: "notif.env.pm25.headline",     defaultValue: "High PM2.5 in %@"),         room)
        case .pm10:
            return String(format: String(localized: "notif.env.pm10.headline",     defaultValue: "High PM10 in %@"),          room)
        case .airQuality:
            return String(format: String(localized: "notif.env.air.headline",      defaultValue: "Air quality dropping in %@"), room)
        case .carbonMonoxide:
            return String(format: String(localized: "notif.env.co.headline",       defaultValue: "CO detected in %@"),           room)
        case .smoke:
            return String(format: String(localized: "notif.env.smoke.headline",    defaultValue: "Smoke detected in %@"),         room)
        case .lightSensor:
            return String(format: String(localized: "notif.env.light.headline",    defaultValue: "High light level in %@"),       room)
        case .outdoorTemperature, .outdoorHumidity:
            return "\(signal.sensorType.displayName): \(room)"
        }
    }

    static func body(for signal: EnvironmentalSignal) -> String {
        let valueStr   = formattedValue(signal.currentValue, for: signal.sensorType)
        let trendLabel = signal.trend.localizedLabel
        return String(format:
            String(localized: "notif.env.body", defaultValue: "%1$@ for %2$d min · %3$@"),
            valueStr, signal.durationMins, trendLabel)
    }

    static func whyExplanation(for signal: EnvironmentalSignal) -> String {
        switch signal.sensorType {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.why",
                          defaultValue: "Above 1,000 ppm, CO₂ reduces cognitive focus and sleep quality.")
        case .humidity:
            return String(localized: "notif.env.humidity.why",
                          defaultValue: "Sustained humidity above 65% promotes mould and mites.")
        case .temperature:
            return String(localized: "notif.env.temp.why",
                          defaultValue: "Temperatures above 26°C at night degrade sleep quality.")
        case .vocDensity:
            return String(localized: "notif.env.voc.why",
                          defaultValue: "Volatile organic compounds can irritate the airways.")
        case .pm25:
            return String(localized: "notif.env.pm25.why",
                          defaultValue: "Fine particulates can reach deep into the lungs and worsen indoor air quality.")
        case .pm10:
            return String(localized: "notif.env.pm10.why",
                          defaultValue: "Coarse particulates can irritate airways and indicate dusty indoor air.")
        case .airQuality:
            return String(localized: "notif.env.air.why",
                          defaultValue: "Air quality affects wellbeing and concentration.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.why",
                          defaultValue: "Carbon monoxide is odourless and potentially dangerous.")
        case .smoke:
            return String(localized: "notif.env.smoke.why",
                          defaultValue: "Smoke presence requires immediate attention.")
        case .lightSensor, .outdoorTemperature, .outdoorHumidity:
            return signal.sensorType.displayName
        }
    }

    static func recommendation(for signal: EnvironmentalSignal) -> String? {
        switch signal.sensorType {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.rec",     defaultValue: "Open a window to lower CO₂.")
        case .humidity:
            return String(localized: "notif.env.humidity.rec", defaultValue: "Run a dehumidifier or ventilate the room.")
        case .temperature:
            return String(localized: "notif.env.temp.rec",    defaultValue: "Consider lowering the AC temperature.")
        case .vocDensity:
            return String(localized: "notif.env.voc.rec",     defaultValue: "Ventilate the room and remove possible VOC sources.")
        case .pm25, .pm10:
            return String(localized: "notif.env.pm.rec",      defaultValue: "Run the air purifier and ventilate if outdoor air quality is safe.")
        case .airQuality:
            return String(localized: "notif.env.air.rec",     defaultValue: "Run the air purifier or open windows.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.rec",      defaultValue: "Ventilate immediately and check combustion sources.")
        case .smoke, .lightSensor, .outdoorTemperature, .outdoorHumidity:
            return nil
        }
    }

    static func formattedCurrentValue(for signal: EnvironmentalSignal) -> String {
        formattedValue(signal.currentValue, for: signal.sensorType)
    }

    static func formattedPeakValue(for signal: EnvironmentalSignal) -> String {
        let value = formattedValue(signal.peakValue, for: signal.sensorType)
        let peakLabel = String(localized: "sensor.peak.label", defaultValue: "peak")
        return "\(value) (\(peakLabel))"
    }

    private static func formattedValue(_ value: Double, for type: SensorServiceType) -> String {
        if type == .airQuality {
            return airQualityLabel(for: value)
        }
        return String(format: "%.1f%@", value, type.unit)
    }

    private static func airQualityLabel(for value: Double) -> String {
        switch Int(value.rounded()) {
        case 1:
            return String(localized: "sensor.airQuality.excellent", defaultValue: "Excellent")
        case 2:
            return String(localized: "sensor.airQuality.good", defaultValue: "Good")
        case 3:
            return String(localized: "sensor.airQuality.fair", defaultValue: "Fair")
        case 4:
            return String(localized: "sensor.airQuality.inferior", defaultValue: "Inferior")
        case 5:
            return String(localized: "sensor.airQuality.poor", defaultValue: "Poor")
        default:
            return String(format: "%.0f", value)
        }
    }

    // MARK: - SensorServiceType-only overloads (used by NotificationDisplayResolver)

    static func headline(forSensorType type: SensorServiceType, room: String) -> String {
        switch type {
        case .temperature:
            return String(format: String(localized: "notif.env.temp.headline",     defaultValue: "High temperature in %@"),   room)
        case .humidity:
            return String(format: String(localized: "notif.env.humidity.headline", defaultValue: "High humidity in %@"),       room)
        case .carbonDioxide:
            return String(format: String(localized: "notif.env.co2.headline",      defaultValue: "Elevated CO₂ in %@"),           room)
        case .vocDensity:
            return String(format: String(localized: "notif.env.voc.headline",      defaultValue: "Elevated VOC in %@"),           room)
        case .pm25:
            return String(format: String(localized: "notif.env.pm25.headline",     defaultValue: "Elevated PM2.5 in %@"),         room)
        case .pm10:
            return String(format: String(localized: "notif.env.pm10.headline",     defaultValue: "Elevated PM10 in %@"),          room)
        case .airQuality:
            return String(format: String(localized: "notif.env.air.headline",      defaultValue: "Air quality declining in %@"), room)
        case .carbonMonoxide:
            return String(format: String(localized: "notif.env.co.headline",       defaultValue: "CO detected in %@"),           room)
        case .smoke:
            return String(format: String(localized: "notif.env.smoke.headline",    defaultValue: "Smoke detected in %@"),         room)
        case .lightSensor:
            return String(format: String(localized: "notif.env.light.headline",    defaultValue: "High light level in %@"),       room)
        case .outdoorTemperature, .outdoorHumidity:
            return "\(type.displayName): \(room)"
        }
    }

    static func recommendation(forSensorType type: SensorServiceType) -> String? {
        switch type {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.rec",      defaultValue: "Open a window to lower CO₂.")
        case .humidity:
            return String(localized: "notif.env.humidity.rec", defaultValue: "Run a dehumidifier or ventilate the room.")
        case .temperature:
            return String(localized: "notif.env.temp.rec",     defaultValue: "Consider lowering the AC temperature.")
        case .vocDensity:
            return String(localized: "notif.env.voc.rec",      defaultValue: "Ventilate the room and remove possible VOC sources.")
        case .pm25, .pm10:
            return String(localized: "notif.env.pm.rec",       defaultValue: "Run the air purifier and ventilate if outdoor air quality is safe.")
        case .airQuality:
            return String(localized: "notif.env.air.rec",      defaultValue: "Run the air purifier or open windows.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.rec",       defaultValue: "Ventilate immediately and check combustion sources.")
        case .smoke, .lightSensor, .outdoorTemperature, .outdoorHumidity:
            return nil
        }
    }

    static func whyExplanation(forSensorType type: SensorServiceType) -> String {
        switch type {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.why",
                          defaultValue: "Above 1,000 ppm, CO₂ reduces cognitive focus and sleep quality.")
        case .humidity:
            return String(localized: "notif.env.humidity.why",
                          defaultValue: "Sustained humidity above 65% promotes mould and mites.")
        case .temperature:
            return String(localized: "notif.env.temp.why",
                          defaultValue: "Temperatures above 26°C at night degrade sleep quality.")
        case .vocDensity:
            return String(localized: "notif.env.voc.why",
                          defaultValue: "Volatile organic compounds can irritate the airways.")
        case .pm25:
            return String(localized: "notif.env.pm25.why",
                          defaultValue: "Fine particulates can reach deep into the lungs and worsen indoor air quality.")
        case .pm10:
            return String(localized: "notif.env.pm10.why",
                          defaultValue: "Coarse particulates can irritate airways and indicate dusty indoor air.")
        case .airQuality:
            return String(localized: "notif.env.air.why",
                          defaultValue: "Air quality affects wellbeing and concentration.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.why",
                          defaultValue: "Carbon monoxide is odourless and potentially dangerous.")
        case .smoke:
            return String(localized: "notif.env.smoke.why",
                          defaultValue: "Smoke presence requires immediate attention.")
        case .lightSensor, .outdoorTemperature, .outdoorHumidity:
            return type.displayName
        }
    }
}
