import Foundation

@MainActor
enum HomeAnomalyDetector {
    struct Configuration {
        var minimumBaselineSamples: Int = 6
        var minimumBaselineConfidence: Double = 0.20
        var mediumStandardDeviationMultiplier: Double = 2.0
        var highStandardDeviationMultiplier: Double = 3.0
        var p95Multiplier: Double = 1.05
        var outputLimit: Int = 40
        var minimumOpenContactDuration: TimeInterval = 15 * 60
        var elevatedOpenContactDuration: TimeInterval = 45 * 60
        var minimumHeatingDuration: TimeInterval = 90 * 60
        var minimumSummerHeatingDuration: TimeInterval = 10 * 60
        var minimumLongRunningPowerDuration: TimeInterval = 6 * 60 * 60
    }

    struct Evaluation: Identifiable {
        enum Outcome: String {
            case emitted
            case nonNumeric
            case belowThreshold
            case missingBaseline
            case relativeDisabled
            case smallDelta
        }

        var id: String { signal.id.uuidString }
        var signal: HomeSignalEvent
        var value: Double?
        var baseline: HomeBaseline?
        var threshold: SensorAlertThreshold?
        var thresholdBreachDescription: String?
        var absoluteDelta: Double?
        var zScore: Double?
        var p95Exceeded: Bool
        var minimumDelta: Double
        var allowsRelativeBaseline: Bool
        var outcome: Outcome
        var reason: String
        var insight: HomeInsight?
    }

    static func detect(
        signals: [HomeSignalEvent],
        baselines: [HomeBaseline],
        thresholds: [SensorAlertThreshold] = [],
        stateIntervals: [HomeStateInterval] = [],
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        let configuration = configuration ?? Configuration()
        let insights = evaluate(
            signals: signals,
            baselines: baselines,
            thresholds: thresholds,
            configuration: configuration
        ).compactMap(\.insight) + detect(
            intervals: stateIntervals,
            configuration: configuration
        )

        return Array(insights.sorted {
            if $0.severity == $1.severity { return $0.updatedAt > $1.updatedAt }
            return $0.severity > $1.severity
        }.prefix(configuration.outputLimit))
    }

    static func detect(
        intervals: [HomeStateInterval],
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        let configuration = configuration ?? Configuration()
        let activeIntervals = intervals.filter(\.isActive)
        let insights = activeIntervals.compactMap { interval in
            intervalInsight(for: interval, configuration: configuration)
        }

        return Array(insights.sorted {
            if $0.severity == $1.severity { return $0.updatedAt > $1.updatedAt }
            return $0.severity > $1.severity
        }.prefix(configuration.outputLimit))
    }

    static func evaluate(
        signals: [HomeSignalEvent],
        baselines: [HomeBaseline],
        thresholds: [SensorAlertThreshold] = [],
        configuration: Configuration? = nil
    ) -> [Evaluation] {
        let configuration = configuration ?? Configuration()
        return latestSignals(from: signals).map { signal in
            evaluate(
                signal: signal,
                baseline: bestBaseline(for: signal, in: baselines, configuration: configuration),
                threshold: bestThreshold(for: signal, in: thresholds),
                configuration: configuration
            )
        }
    }

    private static func evaluate(
        signal: HomeSignalEvent,
        baseline: HomeBaseline?,
        threshold: SensorAlertThreshold?,
        configuration: Configuration
    ) -> Evaluation {
        let policy = policy(for: signal)
        guard let value = signal.value.doubleValue else {
            return Evaluation(
                signal: signal,
                value: nil,
                baseline: baseline,
                threshold: threshold,
                thresholdBreachDescription: nil,
                absoluteDelta: nil,
                zScore: nil,
                p95Exceeded: false,
                minimumDelta: policy.minimumAbsoluteDelta,
                allowsRelativeBaseline: policy.allowsRelativeBaseline,
                outcome: .nonNumeric,
                reason: "Signal is not numeric.",
                insight: nil
            )
        }

        let thresholdBreach = thresholdBreach(value: value, threshold: threshold)
        let deviation = baseline.flatMap { standardDeviationDeviation(value: value, baseline: $0) }
        let absoluteDelta = baseline?.mean.map { abs(value - $0) } ?? thresholdBreach.map { abs(value - $0.limit) } ?? 0
        let passesMinimumDelta = thresholdBreach != nil || absoluteDelta >= policy.minimumAbsoluteDelta
        let relativeBaselineEnabled = thresholdBreach != nil || policy.allowsRelativeBaseline
        let p95Exceeded = relativeBaselineEnabled
            && passesMinimumDelta
            && (baseline?.p95.map { value > $0 * configuration.p95Multiplier } ?? false)
        let lowDeviationExceeded = deviation.map { $0 <= -configuration.mediumStandardDeviationMultiplier } ?? false
        let mediumDeviationExceeded = deviation.map { abs($0) >= configuration.mediumStandardDeviationMultiplier } ?? false
        let highDeviationExceeded = deviation.map { abs($0) >= configuration.highStandardDeviationMultiplier } ?? false
        let relativeDeviationExceeded = relativeBaselineEnabled
            && passesMinimumDelta
            && (lowDeviationExceeded || mediumDeviationExceeded || highDeviationExceeded)

        let insight: HomeInsight?
        let outcome: Evaluation.Outcome
        let reason: String
        if thresholdBreach != nil || p95Exceeded || relativeDeviationExceeded {
            insight = makeInsight(
                signal: signal,
                value: value,
                baseline: baseline,
                thresholdBreach: thresholdBreach,
                deviation: deviation,
                p95Exceeded: p95Exceeded,
                absoluteDelta: absoluteDelta,
                policy: policy,
                highDeviationExceeded: highDeviationExceeded
            )
            outcome = .emitted
            reason = "Emitted anomaly insight."
        } else {
            insight = nil
            if threshold == nil && baseline == nil {
                outcome = .missingBaseline
                reason = "No threshold or compatible baseline."
            } else if !relativeBaselineEnabled {
                outcome = .relativeDisabled
                reason = "Relative baseline disabled for this signal policy."
            } else if !passesMinimumDelta {
                outcome = .smallDelta
                reason = "Delta below minimum policy."
            } else {
                outcome = .belowThreshold
                reason = "Below threshold and baseline trigger levels."
            }
        }

        return Evaluation(
            signal: signal,
            value: value,
            baseline: baseline,
            threshold: threshold,
            thresholdBreachDescription: thresholdBreach.map { "\($0.level.rawValue) \(format($0.limit))" },
            absoluteDelta: absoluteDelta,
            zScore: deviation,
            p95Exceeded: p95Exceeded,
            minimumDelta: policy.minimumAbsoluteDelta,
            allowsRelativeBaseline: policy.allowsRelativeBaseline,
            outcome: outcome,
            reason: reason,
            insight: insight
        )
    }

    private static func makeInsight(
        signal: HomeSignalEvent,
        value: Double,
        baseline: HomeBaseline?,
        thresholdBreach: ThresholdBreach?,
        deviation: Double?,
        p95Exceeded: Bool,
        absoluteDelta: Double,
        policy: DetectionPolicy,
        highDeviationExceeded: Bool
    ) -> HomeInsight {
        let severity: HomeInsightSeverity = severity(
            thresholdBreach: thresholdBreach,
            highDeviationExceeded: highDeviationExceeded
        )
        let direction = anomalyDirection(value: value, baseline: baseline)
        let entityName = displayEntityName(for: signal)
        let measured = format(value)
        let expected = baseline?.mean.map(format) ?? thresholdBreach.map { format($0.limit) } ?? "baseline"
        let expectedSource = baseline?.mean == nil && thresholdBreach != nil ? "threshold" : "baseline"
        let title = "Anomalous \(signal.signalType.rawValue)"
        let message = "\(entityName) reports \(measured), \(direction) its expected \(expected) \(expectedSource)."
        let why = explanation(
            value: value,
            baseline: baseline,
            thresholdBreach: thresholdBreach,
            deviation: deviation,
            p95Exceeded: p95Exceeded,
            absoluteDelta: absoluteDelta,
            policy: policy
        )

        return HomeInsight(
            id: UUID(),
            kind: .anomaly,
            category: .environment,
            severity: severity,
            status: .active,
            title: title,
            message: message,
            whyExplanation: why,
            recommendation: recommendation(for: signal, direction: direction),
            sourceEntityID: signal.entityID,
            sourceEntityName: signal.entityName,
            roomName: signal.roomName,
            createdAt: signal.timestamp,
            updatedAt: signal.timestamp,
            startedAt: signal.timestamp,
            confidence: confidence(for: baseline, thresholdBreach: thresholdBreach, deviation: deviation, p95Exceeded: p95Exceeded),
            score: score(for: baseline, severity: severity),
            dedupeKey: dedupeKey(for: signal, baseline: baseline, direction: direction),
            sourceRecordType: String(describing: HomeSignalEvent.self),
            sourceRecordID: signal.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    private static func latestSignals(from signals: [HomeSignalEvent]) -> [HomeSignalEvent] {
        let sortedSignals = signals
            .sorted { $0.timestamp > $1.timestamp }

        var seenKeys = Set<String>()
        var latest: [HomeSignalEvent] = []
        for signal in sortedSignals {
            let key = signalKey(signal)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            latest.append(signal)
        }
        return latest
    }

    private static func bestBaseline(
        for signal: HomeSignalEvent,
        in baselines: [HomeBaseline],
        configuration: Configuration
    ) -> HomeBaseline? {
        baselines
            .filter { baseline in
                baseline.signalType == signal.signalType
                    && baseline.sampleCount >= configuration.minimumBaselineSamples
                    && baseline.confidence >= configuration.minimumBaselineConfidence
                    && matchesScope(signal: signal, baseline: baseline)
                    && (baseline.mean != nil || baseline.p95 != nil)
            }
            .sorted { lhs, rhs in
                if lhs.contextKey?.hasPrefix("preview.raw") == rhs.contextKey?.hasPrefix("preview.raw") {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.contextKey?.hasPrefix("preview.raw") == true
            }
            .first
    }

    private static func bestThreshold(for signal: HomeSignalEvent, in thresholds: [SensorAlertThreshold]) -> SensorAlertThreshold? {
        let candidates = thresholds.filter { threshold in
            threshold.isEnabled
                && signalType(for: threshold.serviceType) == signal.signalType
                && (threshold.roomName == nil || threshold.roomName == signal.roomName)
        }

        return candidates.sorted { lhs, rhs in
            switch (lhs.roomName, rhs.roomName) {
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.serviceTypeRaw < rhs.serviceTypeRaw
            }
        }.first
    }

    private static func matchesScope(signal: HomeSignalEvent, baseline: HomeBaseline) -> Bool {
        if let baselineEntityID = baseline.entityID, let signalEntityID = signal.entityID {
            return baselineEntityID == signalEntityID
        }
        if let baselineRoom = baseline.roomName, let signalRoom = signal.roomName {
            return baselineRoom == signalRoom
        }
        return false
    }

    private static func standardDeviationDeviation(value: Double, baseline: HomeBaseline) -> Double? {
        guard let mean = baseline.mean,
              let standardDeviation = baseline.standardDeviation,
              standardDeviation > 0 else {
            return nil
        }
        return (value - mean) / standardDeviation
    }

    private static func anomalyDirection(value: Double, baseline: HomeBaseline?) -> String {
        guard let mean = baseline?.mean else { return "above" }
        return value >= mean ? "above" : "below"
    }

    private static func thresholdBreach(value: Double, threshold: SensorAlertThreshold?) -> ThresholdBreach? {
        guard let threshold else { return nil }
        if value >= threshold.dangerValue {
            return ThresholdBreach(level: .danger, limit: threshold.dangerValue)
        }
        if value >= threshold.warningValue {
            return ThresholdBreach(level: .warning, limit: threshold.warningValue)
        }
        return nil
    }

    private static func severity(thresholdBreach: ThresholdBreach?, highDeviationExceeded: Bool) -> HomeInsightSeverity {
        switch thresholdBreach?.level {
        case .danger:
            return .high
        case .warning:
            return .medium
        case nil:
            return highDeviationExceeded ? .high : .medium
        }
    }

    private static func explanation(
        value: Double,
        baseline: HomeBaseline?,
        thresholdBreach: ThresholdBreach?,
        deviation: Double?,
        p95Exceeded: Bool,
        absoluteDelta: Double,
        policy: DetectionPolicy
    ) -> String {
        var parts: [String] = []
        if let thresholdBreach {
            parts.append("\(thresholdBreach.level.rawValue) threshold \(format(thresholdBreach.limit))")
        }
        if let deviation {
            parts.append("z-score \(format(deviation))")
        }
        if baseline?.mean != nil {
            parts.append("delta \(format(absoluteDelta)) / min \(format(policy.minimumAbsoluteDelta))")
        }
        if p95Exceeded, let p95 = baseline?.p95 {
            parts.append("above p95 \(format(p95))")
        }
        if let contextKey = baseline?.contextKey {
            parts.append(contextKey)
        }
        return parts.isEmpty ? "The latest value does not fit the selected baseline." : parts.joined(separator: " · ")
    }

    private static func recommendation(for signal: HomeSignalEvent, direction: String) -> String {
        switch signal.signalType {
        case .temperature:
            return direction == "above" ? "Check cooling, ventilation or sun exposure." : "Check heating or open windows."
        case .humidity:
            return direction == "above" ? "Check ventilation or dehumidification." : "Check whether the room is unusually dry."
        case .carbonDioxide, .vocDensity, .pm25, .pm10, .airQuality:
            return "Check ventilation and air quality devices."
        case .lightLevel:
            return "Check room lighting or daylight exposure."
        default:
            return "Review the source device and recent room context."
        }
    }

    private static func confidence(
        for baseline: HomeBaseline?,
        thresholdBreach: ThresholdBreach?,
        deviation: Double?,
        p95Exceeded: Bool
    ) -> Double {
        let deviationConfidence = deviation.map { min(1.0, abs($0) / 4.0) } ?? 0
        let percentileConfidence = p95Exceeded ? 0.75 : 0
        let thresholdConfidence: Double
        switch thresholdBreach?.level {
        case .danger: thresholdConfidence = 0.95
        case .warning: thresholdConfidence = 0.80
        case nil: thresholdConfidence = 0
        }
        return min(1.0, max(deviationConfidence, percentileConfidence, thresholdConfidence) * 0.6 + (baseline?.confidence ?? 0.5) * 0.4)
    }

    private static func score(for baseline: HomeBaseline?, severity: HomeInsightSeverity) -> HomeInsightScore {
        let urgency: Double = severity >= .high ? 0.85 : 0.65
        let baselineConfidence = baseline?.confidence ?? 0.75
        return HomeInsightScore(
            relevance: baselineConfidence,
            confidence: baselineConfidence,
            urgency: urgency,
            actionability: 0.65,
            novelty: 0.75
        )
    }

    private static func dedupeKey(for signal: HomeSignalEvent, baseline: HomeBaseline?, direction: String) -> String {
        "anomaly|\(signalKey(signal))|\(baseline?.contextKey ?? "threshold")|\(direction)"
    }

    private static func signalKey(_ signal: HomeSignalEvent) -> String {
        let entity = signal.entityID ?? signal.entityName
        let room = signal.roomName ?? "home"
        return "\(room)|\(entity)|\(signal.signalType.rawValue)"
    }

    private static func displayEntityName(for signal: HomeSignalEvent) -> String {
        if let roomName = signal.roomName, !roomName.isEmpty {
            return "\(roomName) \(signal.entityName)"
        }
        return signal.entityName
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func policy(for signal: HomeSignalEvent) -> DetectionPolicy {
        switch signal.signalType {
        case .humidity:
            return DetectionPolicy(
                minimumAbsoluteDelta: 10,
                allowsRelativeBaseline: signal.sourceKind != .weather
            )
        case .temperature:
            return DetectionPolicy(minimumAbsoluteDelta: signal.sourceKind == .weather ? 4 : 2)
        case .carbonDioxide:
            return DetectionPolicy(minimumAbsoluteDelta: 150)
        case .vocDensity:
            return DetectionPolicy(minimumAbsoluteDelta: 50)
        case .pm25, .pm10:
            return DetectionPolicy(minimumAbsoluteDelta: 8)
        case .airQuality:
            return DetectionPolicy(minimumAbsoluteDelta: 1)
        case .lightLevel:
            return DetectionPolicy(minimumAbsoluteDelta: 150, allowsRelativeBaseline: false)
        default:
            return DetectionPolicy(minimumAbsoluteDelta: 0)
        }
    }

    private static func intervalInsight(
        for interval: HomeStateInterval,
        configuration: Configuration
    ) -> HomeInsight? {
        let duration = interval.durationSeconds
        let rule = intervalRule(for: interval, configuration: configuration)
        guard let rule, duration >= rule.minimumDuration else { return nil }

        let entityName = displayEntityName(for: interval)
        let durationText = durationDescription(duration)
        let message = "\(entityName) has been \(interval.stateRaw) for \(durationText)."
        let why = "\(interval.stateRaw) duration \(durationText) exceeds \(durationDescription(rule.minimumDuration)) policy."

        return HomeInsight(
            id: UUID(),
            kind: .anomaly,
            category: rule.category,
            severity: rule.severity,
            status: .active,
            title: rule.title,
            message: message,
            whyExplanation: why,
            recommendation: rule.recommendation,
            sourceEntityID: interval.entityID,
            sourceEntityName: interval.entityName,
            roomName: interval.roomName,
            createdAt: interval.startedAt,
            updatedAt: Date(),
            startedAt: interval.startedAt,
            confidence: rule.confidence,
            score: HomeInsightScore(
                relevance: rule.confidence,
                confidence: rule.confidence,
                urgency: rule.severity >= .high ? 0.85 : 0.55,
                actionability: 0.75,
                novelty: 0.7
            ),
            dedupeKey: "intervalAnomaly|\(interval.entityID ?? interval.entityName)|\(interval.stateRaw)",
            sourceRecordType: String(describing: HomeStateInterval.self),
            sourceRecordID: interval.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    private static func intervalRule(
        for interval: HomeStateInterval,
        configuration: Configuration
    ) -> IntervalRule? {
        switch interval.signalType {
        case .contact:
            let isElevated = interval.durationSeconds >= configuration.elevatedOpenContactDuration
            let isWindowLike = containsAny(
                interval.entityName + " " + (interval.roomName ?? ""),
                tokens: ["window", "finestra", "porta finestra", "balcone"]
            )
            return IntervalRule(
                minimumDuration: configuration.minimumOpenContactDuration,
                title: "Contact left open",
                category: isWindowLike ? .security : .presence,
                severity: isElevated ? .medium : .low,
                recommendation: isWindowLike ? "Check the window or exterior door state." : "Monitor whether this contact remains open.",
                confidence: isElevated ? 0.75 : 0.55
            )
        case .active where interval.stateRaw == "heating":
            let isSummer = Calendar.current.component(.month, from: Date()).isSummerMonth
            return IntervalRule(
                minimumDuration: isSummer ? configuration.minimumSummerHeatingDuration : configuration.minimumHeatingDuration,
                title: "Unexpected heating",
                category: .environment,
                severity: isSummer ? .high : .medium,
                recommendation: "Check thermostat schedule and valve demand.",
                confidence: isSummer ? 0.85 : 0.65
            )
        case .power:
            return IntervalRule(
                minimumDuration: configuration.minimumLongRunningPowerDuration,
                title: "Long running power state",
                category: .lighting,
                severity: .low,
                recommendation: "Review whether this device should still be on.",
                confidence: 0.55
            )
        default:
            return nil
        }
    }

    private static func displayEntityName(for interval: HomeStateInterval) -> String {
        if let roomName = interval.roomName, !roomName.isEmpty {
            return "\(roomName) \(interval.entityName)"
        }
        return interval.entityName
    }

    private static func durationDescription(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration.rounded()) / 60)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0, remainingMinutes > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func containsAny(_ value: String, tokens: [String]) -> Bool {
        let normalized = value.lowercased()
        return tokens.contains { normalized.contains($0) }
    }

    private static func signalType(for sensorType: SensorServiceType) -> HomeSignalType {
        switch sensorType {
        case .temperature, .outdoorTemperature: return .temperature
        case .humidity, .outdoorHumidity: return .humidity
        case .airQuality: return .airQuality
        case .carbonMonoxide: return .carbonMonoxide
        case .carbonDioxide: return .carbonDioxide
        case .smoke: return .smoke
        case .vocDensity: return .vocDensity
        case .pm25: return .pm25
        case .pm10: return .pm10
        case .lightSensor: return .lightLevel
        }
    }

    private struct ThresholdBreach {
        var level: ThresholdLevel
        var limit: Double
    }

    private struct DetectionPolicy {
        var minimumAbsoluteDelta: Double
        var allowsRelativeBaseline: Bool = true
    }

    private struct IntervalRule {
        var minimumDuration: TimeInterval
        var title: String
        var category: HomeInsightCategory
        var severity: HomeInsightSeverity
        var recommendation: String
        var confidence: Double
    }

    private enum ThresholdLevel: String {
        case warning
        case danger
    }
}

private extension Int {
    var isSummerMonth: Bool {
        (5...9).contains(self)
    }
}
