import Foundation
import SwiftData

// MARK: - EnergySignalType

enum EnergySignalType: String {
    /// Accessory has been continuously ON beyond the normal session length.
    case alwaysOn
    /// Today's total usage is significantly above the historical daily average.
    case anomalousRuntime
}

// MARK: - EnergySignal

struct EnergySignal {
    let id:            UUID
    let accessoryID:   UUID
    let accessoryName: String
    let roomName:      String
    let type:          EnergySignalType
    /// Observed hours (current session for alwaysOn; totalHoursToday for anomalousRuntime).
    let currentHours:  Double
    /// Expected normal hours derived from the 7-day baseline.
    let baselineHours: Double
    let score:         IntelligenceScore
    let semanticKey:   String
}

// MARK: - EnergyInsightBuilder

/// Detects energy anomalies from EnergyUsageRecord data and produces EnergySignal candidates.
/// Pure builder — no side effects, no stored state.
enum EnergyInsightBuilder {

    // MARK: - Thresholds

    /// Minimum continuous ON hours to qualify for an alwaysOn signal.
    private static let alwaysOnThreshold: Double = 3.0
    /// Multiplier above daily baseline to flag as anomalous runtime.
    private static let anomalyFactor: Double = 2.0
    /// Minimum baseline hours for anomaly detection (ignores rarely-used accessories).
    private static let minBaselineHours: Double = 0.5
    /// Minimum absolute hours today for anomaly detection (avoids noise).
    private static let minAbsoluteHours: Double = 1.5

    /// AccessoryEvent types that represent energy-consuming devices.
    private static let energyEventTypes: Set<String> = ["light", "switch"]

    // MARK: - Build

    /// Produces energy anomaly signals from pre-computed usage records.
    /// Results are sorted by composite score descending.
    static func build(records: [EnergyUsageRecord]) -> [EnergySignal] {
        var signals: [EnergySignal] = []

        for record in records where energyEventTypes.contains(record.eventType) {

            // — Always-on signal ——————————————————————————————————————————
            if let sessionHours = record.currentSessionHours,
               sessionHours >= alwaysOnThreshold {
                let baseline = max(record.avgDailyHours, record.longestSessionHours * 0.5)
                let excess   = max(0, sessionHours - baseline)
                let score = IntelligenceScore(
                    relevance:     min(1.0, 0.55 + excess / 8.0),
                    confidence:    record.avgDailyHours > 0 ? 0.75 : 0.45,
                    urgency:       min(1.0, sessionHours / 6.0),
                    actionability: 1.0,
                    novelty:       0.65
                )
                signals.append(EnergySignal(
                    id:            UUID(),
                    accessoryID:   record.accessoryID,
                    accessoryName: record.accessoryName,
                    roomName:      record.roomName,
                    type:          .alwaysOn,
                    currentHours:  sessionHours,
                    baselineHours: baseline,
                    score:         score,
                    semanticKey:   "energy|alwaysOn|\(record.accessoryID.uuidString)"
                ))
            }

            // — Anomalous runtime signal ———————————————————————————————————
            let baseline = record.avgDailyHours
            if baseline >= minBaselineHours,
               record.totalHoursToday >= minAbsoluteHours,
               record.totalHoursToday > baseline * anomalyFactor {
                let excess = record.totalHoursToday - baseline
                let score = IntelligenceScore(
                    relevance:     min(1.0, 0.50 + excess / 10.0),
                    confidence:    0.70,
                    urgency:       min(1.0, record.totalHoursToday / 8.0),
                    actionability: 1.0,
                    novelty:       0.70
                )
                signals.append(EnergySignal(
                    id:            UUID(),
                    accessoryID:   record.accessoryID,
                    accessoryName: record.accessoryName,
                    roomName:      record.roomName,
                    type:          .anomalousRuntime,
                    currentHours:  record.totalHoursToday,
                    baselineHours: baseline,
                    score:         score,
                    semanticKey:   "energy|runtime|\(record.accessoryID.uuidString)"
                ))
            }
        }

        return signals.sorted { $0.score.composite > $1.score.composite }
    }

    /// Convenience: fetches events from the model container and runs build() in one step.
    static func buildFromStore(modelContainer: ModelContainer) async -> [EnergySignal] {
        let records = await EnergyUsageTracker.analyze(modelContainer: modelContainer)
        return build(records: records)
    }

    // MARK: - Notification Content

    static func headline(for signal: EnergySignal) -> String {
        switch signal.type {
        case .alwaysOn:
            return String(localized: "energy.signal.alwaysOn.headline",
                          defaultValue: "Dispositivo rimasto acceso")
        case .anomalousRuntime:
            return String(localized: "energy.signal.runtime.headline",
                          defaultValue: "Consumo anomalo rilevato")
        }
    }

    static func body(for signal: EnergySignal) -> String {
        let current  = String(format: "%.1f", signal.currentHours)
        let baseline = String(format: "%.1f", signal.baselineHours)
        switch signal.type {
        case .alwaysOn:
            return String(format:
                String(localized: "energy.signal.alwaysOn.body",
                       defaultValue: "%1$@ (%2$@) è acceso da %3$@ ore. Di solito si spegne entro %4$@ ore."),
                signal.accessoryName, signal.roomName, current, baseline)
        case .anomalousRuntime:
            return String(format:
                String(localized: "energy.signal.runtime.body",
                       defaultValue: "%1$@ (%2$@) ha accumulato %3$@ ore oggi. Media giornaliera: %4$@ ore."),
                signal.accessoryName, signal.roomName, current, baseline)
        }
    }

    static func recommendation(for signal: EnergySignal) -> String {
        String(format:
            String(localized: "energy.signal.recommendation",
                   defaultValue: "Verifica se %@ è necessario e considera di spegnerlo per ridurre i consumi."),
            signal.accessoryName)
    }

    static func whyExplanation(for signal: EnergySignal) -> String {
        let baseline = String(format: "%.1f", signal.baselineHours)
        switch signal.type {
        case .alwaysOn:
            return String(format:
                String(localized: "energy.signal.alwaysOn.why",
                       defaultValue: "Basato sullo storico: media di %@ ore di sessione al giorno."),
                baseline)
        case .anomalousRuntime:
            return String(format:
                String(localized: "energy.signal.runtime.why",
                       defaultValue: "L'utilizzo odierno supera del doppio la media storica di %@ ore/giorno."),
                baseline)
        }
    }
}
