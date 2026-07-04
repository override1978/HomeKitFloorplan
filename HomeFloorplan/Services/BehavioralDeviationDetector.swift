import Foundation

// MARK: - DeviationSignal

struct DeviationSignal {
    let pattern:           BehavioralPattern
    let expectedAt:        Date
    let consecutiveMisses: Int
}

// MARK: - BehavioralDeviationDetector

/// Compares known stable behavioral patterns against recent home events.
/// Returns signals for patterns whose expected action was NOT observed within
/// the expected time window.
enum BehavioralDeviationDetector {

    static func detect(
        patterns:              [BehavioralPattern],
        recentEventSignatures: Set<String>,
        context:               ContextSnapshot
    ) -> [DeviationSignal] {
        guard !context.suppressNonCritical else { return [] }

        let now         = Date()
        let cal         = Calendar.current
        let currentMin  = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let currentWD   = cal.component(.weekday, from: now)

        var signals: [DeviationSignal] = []

        for pattern in patterns {
            guard pattern.status == .active,
                  pattern.tier.isVisible,
                  pattern.confidence >= 0.80,
                  pattern.patternType == .temporal || pattern.patternType == .scene
            else { continue }

            // Only check patterns relevant to today's weekday
            if !pattern.weekdays.isEmpty && !pattern.weekdays.contains(currentWD) { continue }

            // Check if current time is inside the expected window (±tolerance)
            let tolerance   = max(10, pattern.timeDeviationMinutes + 5)
            let windowStart = pattern.avgMinuteOfDay - tolerance
            let windowEnd   = pattern.avgMinuteOfDay + tolerance
            guard currentMin >= windowStart && currentMin <= windowEnd else { continue }

            // Skip if the expected event already happened in recent history
            let eventKey = "\(pattern.eventTypeRaw):\(pattern.accessoryName):\(pattern.action.rawValue)"
            if recentEventSignatures.contains(eventKey) {
                resetMisses(for: pattern.id)
                continue
            }

            let hour   = pattern.avgMinuteOfDay / 60
            let minute = pattern.avgMinuteOfDay % 60
            var comps  = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour   = hour
            comps.minute = minute
            let expectedAt = cal.date(from: comps) ?? now

            let misses = consecutiveMisses(for: pattern.id)
            signals.append(DeviationSignal(
                pattern:           pattern,
                expectedAt:        expectedAt,
                consecutiveMisses: misses
            ))
        }
        return signals
    }

    // MARK: - Miss tracking (UserDefaults — single dict, keyed by pattern UUID string)

    nonisolated private static let missesKey = "deviation.missesDict"

    static func recordMiss(for patternID: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: missesKey) as? [String: Int] ?? [:]
        dict[patternID.uuidString, default: 0] += 1
        UserDefaults.standard.set(dict, forKey: missesKey)
    }

    static func resetMisses(for patternID: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: missesKey) as? [String: Int] ?? [:]
        dict.removeValue(forKey: patternID.uuidString)
        UserDefaults.standard.set(dict, forKey: missesKey)
    }

    /// Removes miss counters for patterns that no longer exist.
    /// Called by DataLifecycleService to prevent unbounded UserDefaults growth.
    nonisolated static func cleanup(keepPatternIDs: Set<UUID>) {
        var dict = UserDefaults.standard.dictionary(forKey: missesKey) as? [String: Int] ?? [:]
        let keepStrings = Set(keepPatternIDs.map(\.uuidString))
        dict = dict.filter { keepStrings.contains($0.key) }
        UserDefaults.standard.set(dict, forKey: missesKey)
    }

    private static func consecutiveMisses(for patternID: UUID) -> Int {
        let dict = UserDefaults.standard.dictionary(forKey: missesKey) as? [String: Int] ?? [:]
        return dict[patternID.uuidString] ?? 0
    }

    // MARK: - Message generation

    static func headline(for signal: DeviationSignal) -> String {
        let name = signal.pattern.accessoryName
        switch signal.pattern.action {
        case .off:
            return String(format: String(localized: "notif.deviation.off.headline",
                                         defaultValue: "%@ is still on"),
                          name)
        case .on:
            return String(format: String(localized: "notif.deviation.on.headline",
                                         defaultValue: "%@ is not on yet"),
                          name)
        case .activate:
            return String(format: String(localized: "notif.deviation.activate.headline",
                                         defaultValue: "%@ is not active yet"),
                          name)
        default:
            return String(format: String(localized: "notif.deviation.generic.headline",
                                         defaultValue: "Habit not yet performed: %@"),
                          name)
        }
    }

    static func body(for signal: DeviationSignal) -> String {
        let pattern = signal.pattern
        let timeStr = pattern.avgTimeString
        switch pattern.action {
        case .off:
            return String(format: String(localized: "notif.deviation.off.body",
                                         defaultValue: "You usually turn it off around %@. Do it now?"),
                          timeStr)
        case .on:
            return String(format: String(localized: "notif.deviation.on.body",
                                         defaultValue: "You usually turn it on around %@. Do it now?"),
                          timeStr)
        case .activate:
            return String(format: String(localized: "notif.deviation.activate.body",
                                         defaultValue: "It's usually active around %@. Activate it now?"),
                          timeStr)
        default:
            return String(format: String(localized: "notif.deviation.generic.body",
                                         defaultValue: "This usually happens around %@."),
                          timeStr)
        }
    }

    static func whyExplanation(for signal: DeviationSignal) -> String {
        let pattern = signal.pattern
        return String(format:
            String(localized: "notif.deviation.why",
                   defaultValue: "Detected in %d observations with a deviation of ±%d minutes. Confidence: %@."),
            pattern.observations,
            pattern.timeDeviationMinutes,
            pattern.confidenceLabel
        )
    }

    static func score(for signal: DeviationSignal) -> IntelligenceScore {
        let pattern = signal.pattern
        let missEscalation = min(1.0, Double(signal.consecutiveMisses + 1) * 0.25)
        return IntelligenceScore(
            relevance:     min(1.0, pattern.confidence * 1.05),
            confidence:    pattern.confidence,
            urgency:       missEscalation * 0.7,
            actionability: 0.90,
            novelty:       signal.consecutiveMisses == 0 ? 0.80 : 0.30
        )
    }
}
