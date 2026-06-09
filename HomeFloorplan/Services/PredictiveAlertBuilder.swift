import Foundation

// MARK: - PredictiveSignal

struct PredictiveSignal {
    let pattern:           EnvironmentalRecurrencePattern
    let expectedInMinutes: Int
    let semanticKey:       String
    let score:             IntelligenceScore
}

// MARK: - PredictiveAlertBuilder

/// Reads EnvironmentalRecurrencePatterns and returns signals for patterns
/// whose expected peak falls within the predictive window (minLead … maxLead minutes from now).
///
/// Pure builder — no I/O, no state. Runs synchronously inside ProactiveIntelligenceService.runCycle.
enum PredictiveAlertBuilder {

    /// Earliest lead time to surface a predictive alert (minutes).
    private static let minLeadMinutes: Int = 30
    /// Latest lead time — further away = too speculative (minutes).
    private static let maxLeadMinutes: Int = 90

    static func build(patterns: [EnvironmentalRecurrencePattern]) -> [PredictiveSignal] {
        guard !patterns.isEmpty else { return [] }

        let now        = Date()
        let cal        = Calendar.current
        let curWeekday = cal.component(.weekday, from: now)
        let curMinute  = cal.component(.hour,    from: now) * 60
                       + cal.component(.minute,  from: now)

        var signals: [PredictiveSignal] = []
        for pattern in patterns {
            guard pattern.weekday == curWeekday else { continue }
            guard pattern.sensorType != nil    else { continue }

            let patternMinute = pattern.hourOfDay * 60
            let lead          = patternMinute - curMinute
            guard lead >= minLeadMinutes && lead <= maxLeadMinutes else { continue }

            let score = IntelligenceScore(
                relevance:     min(1.0, pattern.exceedanceRate),
                confidence:    pattern.confidence,
                urgency:       lead <= 45 ? 0.75 : 0.50,
                actionability: 0.80,
                novelty:       0.70
            )

            signals.append(PredictiveSignal(
                pattern:           pattern,
                expectedInMinutes: lead,
                semanticKey:       "predictive|\(pattern.roomName)|\(pattern.sensorTypeRaw)|\(pattern.weekday)",
                score:             score
            ))
        }
        return signals
    }
}
