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
    /// Minimum distinct calendar days with activity needed before declaring anomalous runtime.
    /// Prevents false positives for newly-installed or rarely-used accessories.
    private static let minActiveDays: Int = 3

    /// AccessoryEvent types that represent energy-consuming devices.
    private static let energyEventTypes: Set<String> = [
        "light", "switch",
        "thermostat", "fan", "airPurifier", "outlet"
    ]

    // MARK: - Build

    /// Produces energy anomaly signals from pre-computed usage records.
    /// Accessories in `ignoredIDs` are silently skipped.
    /// Results are sorted by composite score descending.
    static func build(records: [EnergyUsageRecord], ignoredIDs: Set<UUID> = []) -> [EnergySignal] {
        var signals: [EnergySignal] = []

        for record in records where energyEventTypes.contains(record.eventType) {
            guard !ignoredIDs.contains(record.accessoryID) else { continue }

            // — Always-on signal ——————————————————————————————————————————
            if let sessionHours = record.currentSessionHours,
               sessionHours >= alwaysOnThreshold {
                let baseline = max(record.avgDailyHours, record.longestSessionHours * 0.5)
                // Skip if this session length is normal for this device (e.g. fridge always on).
                guard sessionHours > baseline else { continue }
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
               record.activeDaysInWindow >= minActiveDays,
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
    static func buildFromStore(modelContainer: ModelContainer, ignoredIDs: Set<UUID> = []) async -> [EnergySignal] {
        let records = await EnergyUsageTracker.analyze(modelContainer: modelContainer)
        return build(records: records, ignoredIDs: ignoredIDs)
    }

    // MARK: - Notification Content

    static func headline(for signal: EnergySignal) -> String {
        switch signal.type {
        case .alwaysOn:
            return String(localized: "energy.signal.alwaysOn.headline",
                          defaultValue: "Device left on")
        case .anomalousRuntime:
            return String(localized: "energy.signal.runtime.headline",
                          defaultValue: "Anomalous usage detected")
        }
    }

    static func body(for signal: EnergySignal) -> String {
        let current  = String(format: "%.1f", signal.currentHours)
        let baseline = String(format: "%.1f", signal.baselineHours)
        switch signal.type {
        case .alwaysOn:
            return String(format:
                String(localized: "energy.signal.alwaysOn.body",
                       defaultValue: "%1$@ (%2$@) has been on for %3$@ hours. It usually turns off within %4$@ hours."),
                signal.accessoryName, signal.roomName, current, baseline)
        case .anomalousRuntime:
            return String(format:
                String(localized: "energy.signal.runtime.body",
                       defaultValue: "%1$@ (%2$@) has accumulated %3$@ hours today. Daily average: %4$@ hours."),
                signal.accessoryName, signal.roomName, current, baseline)
        }
    }

    static func recommendation(for signal: EnergySignal) -> String {
        String(format:
            String(localized: "energy.signal.recommendation",
                   defaultValue: "Check if %@ is needed and consider turning it off to reduce usage."),
            signal.accessoryName)
    }

    static func whyExplanation(for signal: EnergySignal) -> String {
        let baseline = String(format: "%.1f", signal.baselineHours)
        switch signal.type {
        case .alwaysOn:
            return String(format:
                String(localized: "energy.signal.alwaysOn.why",
                       defaultValue: "Based on history: average session of %@ hours per day."),
                baseline)
        case .anomalousRuntime:
            return String(format:
                String(localized: "energy.signal.runtime.why",
                       defaultValue: "Today's usage is double the historical average of %@ hours/day."),
                baseline)
        }
    }
}
