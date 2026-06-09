import Foundation
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

    static func build(modelContainer: ModelContainer) async -> [EnvironmentalSignal] {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-lookbackSeconds)

        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let readings = (try? context.fetch(descriptor)) ?? []
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

    private static func buildSignal(from group: [SensorReading]) -> EnvironmentalSignal? {
        guard group.count >= 2, let first = group.first else { return nil }

        let type    = first.serviceType
        // Boolean sensors (smoke, CO in alert mode) are handled separately
        guard !type.isBooleanAlert else { return nil }

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
            return String(format: String(localized: "notif.env.temp.headline",     defaultValue: "Temperatura elevata in %@"),   room)
        case .humidity:
            return String(format: String(localized: "notif.env.humidity.headline", defaultValue: "Umidità elevata in %@"),       room)
        case .carbonDioxide:
            return String(format: String(localized: "notif.env.co2.headline",      defaultValue: "CO₂ elevato in %@"),           room)
        case .vocDensity:
            return String(format: String(localized: "notif.env.voc.headline",      defaultValue: "VOC elevato in %@"),           room)
        case .airQuality:
            return String(format: String(localized: "notif.env.air.headline",      defaultValue: "Qualità aria in calo in %@"), room)
        case .carbonMonoxide:
            return String(format: String(localized: "notif.env.co.headline",       defaultValue: "CO rilevato in %@"),           room)
        case .smoke:
            return String(format: String(localized: "notif.env.smoke.headline",    defaultValue: "Fumo rilevato in %@"),         room)
        }
    }

    static func body(for signal: EnvironmentalSignal) -> String {
        let valueStr   = String(format: "%.1f%@", signal.currentValue, signal.sensorType.unit)
        let trendLabel = signal.trend.localizedLabel
        return String(format:
            String(localized: "notif.env.body", defaultValue: "%1$@ for %2$d min · %3$@"),
            valueStr, signal.durationMins, trendLabel)
    }

    static func whyExplanation(for signal: EnvironmentalSignal) -> String {
        switch signal.sensorType {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.why",
                          defaultValue: "Sopra i 1.000 ppm il CO₂ riduce la concentrazione cognitiva e la qualità del sonno.")
        case .humidity:
            return String(localized: "notif.env.humidity.why",
                          defaultValue: "L'umidità prolungata sopra il 65% favorisce la formazione di muffa e acari.")
        case .temperature:
            return String(localized: "notif.env.temp.why",
                          defaultValue: "Temperature sopra i 26°C di notte peggiorano la qualità del sonno.")
        case .vocDensity:
            return String(localized: "notif.env.voc.why",
                          defaultValue: "I composti organici volatili possono irritare le vie respiratorie.")
        case .airQuality:
            return String(localized: "notif.env.air.why",
                          defaultValue: "La qualità dell'aria influisce su benessere e concentrazione.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.why",
                          defaultValue: "Il monossido di carbonio è inodore e potenzialmente pericoloso per la salute.")
        case .smoke:
            return String(localized: "notif.env.smoke.why",
                          defaultValue: "La presenza di fumo richiede attenzione immediata.")
        }
    }

    static func recommendation(for signal: EnvironmentalSignal) -> String? {
        switch signal.sensorType {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.rec",     defaultValue: "Apri una finestra per abbassare il CO₂.")
        case .humidity:
            return String(localized: "notif.env.humidity.rec", defaultValue: "Attiva un deumidificatore o ventila la stanza.")
        case .temperature:
            return String(localized: "notif.env.temp.rec",    defaultValue: "Considera di abbassare la temperatura del climatizzatore.")
        case .vocDensity:
            return String(localized: "notif.env.voc.rec",     defaultValue: "Ventila la stanza e rimuovi possibili fonti di VOC.")
        case .airQuality:
            return String(localized: "notif.env.air.rec",     defaultValue: "Attiva il purificatore d'aria o apri le finestre.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.rec",      defaultValue: "Aerare immediatamente l'ambiente e controllare le fonti di combustione.")
        case .smoke:
            return nil
        }
    }

    static func formattedCurrentValue(for signal: EnvironmentalSignal) -> String {
        String(format: "%.1f%@", signal.currentValue, signal.sensorType.unit)
    }

    static func formattedPeakValue(for signal: EnvironmentalSignal) -> String {
        let value = String(format: "%.1f%@", signal.peakValue, signal.sensorType.unit)
        let peakLabel = String(localized: "sensor.peak.label", defaultValue: "picco")
        return "\(value) (\(peakLabel))"
    }

    // MARK: - SensorServiceType-only overloads (used by NotificationDisplayResolver)

    static func headline(forSensorType type: SensorServiceType, room: String) -> String {
        switch type {
        case .temperature:
            return String(format: String(localized: "notif.env.temp.headline",     defaultValue: "Temperatura elevata in %@"),   room)
        case .humidity:
            return String(format: String(localized: "notif.env.humidity.headline", defaultValue: "Umidità elevata in %@"),       room)
        case .carbonDioxide:
            return String(format: String(localized: "notif.env.co2.headline",      defaultValue: "CO₂ elevato in %@"),           room)
        case .vocDensity:
            return String(format: String(localized: "notif.env.voc.headline",      defaultValue: "VOC elevato in %@"),           room)
        case .airQuality:
            return String(format: String(localized: "notif.env.air.headline",      defaultValue: "Qualità aria in calo in %@"), room)
        case .carbonMonoxide:
            return String(format: String(localized: "notif.env.co.headline",       defaultValue: "CO rilevato in %@"),           room)
        case .smoke:
            return String(format: String(localized: "notif.env.smoke.headline",    defaultValue: "Fumo rilevato in %@"),         room)
        }
    }

    static func recommendation(forSensorType type: SensorServiceType) -> String? {
        switch type {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.rec",      defaultValue: "Apri una finestra per abbassare il CO₂.")
        case .humidity:
            return String(localized: "notif.env.humidity.rec", defaultValue: "Attiva un deumidificatore o ventila la stanza.")
        case .temperature:
            return String(localized: "notif.env.temp.rec",     defaultValue: "Considera di abbassare la temperatura del climatizzatore.")
        case .vocDensity:
            return String(localized: "notif.env.voc.rec",      defaultValue: "Ventila la stanza e rimuovi possibili fonti di VOC.")
        case .airQuality:
            return String(localized: "notif.env.air.rec",      defaultValue: "Attiva il purificatore d'aria o apri le finestre.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.rec",       defaultValue: "Aerare immediatamente l'ambiente e controllare le fonti di combustione.")
        case .smoke:
            return nil
        }
    }

    static func whyExplanation(forSensorType type: SensorServiceType) -> String {
        switch type {
        case .carbonDioxide:
            return String(localized: "notif.env.co2.why",
                          defaultValue: "Sopra i 1.000 ppm il CO₂ riduce la concentrazione cognitiva e la qualità del sonno.")
        case .humidity:
            return String(localized: "notif.env.humidity.why",
                          defaultValue: "L'umidità prolungata sopra il 65% favorisce la formazione di muffa e acari.")
        case .temperature:
            return String(localized: "notif.env.temp.why",
                          defaultValue: "Temperature sopra i 26°C di notte peggiorano la qualità del sonno.")
        case .vocDensity:
            return String(localized: "notif.env.voc.why",
                          defaultValue: "I composti organici volatili possono irritare le vie respiratorie.")
        case .airQuality:
            return String(localized: "notif.env.air.why",
                          defaultValue: "La qualità dell'aria influisce su benessere e concentrazione.")
        case .carbonMonoxide:
            return String(localized: "notif.env.co.why",
                          defaultValue: "Il monossido di carbonio è inodore e potenzialmente pericoloso per la salute.")
        case .smoke:
            return String(localized: "notif.env.smoke.why",
                          defaultValue: "La presenza di fumo richiede attenzione immediata.")
        }
    }
}
