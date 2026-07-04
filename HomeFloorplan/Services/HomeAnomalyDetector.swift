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
        var durationBaselineMultiplier: Double = 1.5
        var minimumPowerDurationWithBaseline: TimeInterval = 30 * 60
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
            baselines: baselines,
            configuration: configuration
        )

        return Array(insights.sorted {
            if $0.severity == $1.severity { return $0.updatedAt > $1.updatedAt }
            return $0.severity > $1.severity
        }.prefix(configuration.outputLimit))
    }

    static func detect(
        intervals: [HomeStateInterval],
        baselines: [HomeBaseline] = [],
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        let configuration = configuration ?? Configuration()
        let activeIntervals = intervals.filter(\.isActive)
        let insights = activeIntervals.compactMap { interval in
            intervalInsight(
                for: interval,
                durationBaseline: bestDurationBaseline(for: interval, in: baselines),
                configuration: configuration
            )
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
        let passesMinimumDelta = (thresholdBreach != nil && policy.thresholdBypassesMinimumDelta)
            || absoluteDelta >= policy.minimumAbsoluteDelta
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
        let measured = format(value, for: signal.signalType)
        let expected = baseline?.mean.map { format($0, for: signal.signalType) }
            ?? thresholdBreach.map { format($0.limit, for: signal.signalType) }
            ?? "baseline"
        let title = anomalyTitle(
            for: signal,
            severity: severity,
            thresholdBreach: thresholdBreach,
            direction: direction
        )
        let message = anomalyMessage(
            for: signal,
            entityName: entityName,
            measured: measured,
            expected: expected,
            thresholdBreach: thresholdBreach,
            direction: direction
        )
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
        if parts.isEmpty {
            return isItalian ? "Il valore più recente non rientra nella baseline selezionata." : "The latest value does not fit the selected baseline."
        }
        return parts.joined(separator: " · ")
    }

    private static func recommendation(for signal: HomeSignalEvent, direction: String) -> String {
        if isItalian {
            switch signal.signalType {
            case .temperature:
                return direction == "above" ? "Controlla raffrescamento, ventilazione o esposizione al sole." : "Controlla riscaldamento o finestre aperte."
            case .humidity:
                return direction == "above" ? "Controlla ventilazione o deumidificazione." : "Verifica se la stanza è troppo secca."
            case .carbonDioxide, .vocDensity, .pm25, .pm10, .airQuality:
                return "Controlla ventilazione e dispositivi per la qualità dell'aria."
            case .lightLevel:
                return "Controlla illuminazione o luce naturale nella stanza."
            default:
                return "Verifica il dispositivo sorgente e il contesto recente della stanza."
            }
        }

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

    private static func anomalyTitle(
        for signal: HomeSignalEvent,
        severity: HomeInsightSeverity,
        thresholdBreach: ThresholdBreach?,
        direction: String
    ) -> String {
        let prefix: String
        if isItalian {
            prefix = severity >= .high ? "ALLARME: " : "Attenzione: "
        } else {
            prefix = severity >= .high ? "ALERT: " : "Warning: "
        }

        if thresholdBreach != nil {
            return prefix + thresholdTitle(for: signal.signalType, direction: direction)
        }

        let room = signal.roomName ?? signal.entityName
        if isItalian {
            return "\(signalLabel(for: signal.signalType, lowercase: false)) fuori norma in \(room)"
        }
        return "Unusual \(signalLabel(for: signal.signalType, lowercase: true)) in \(room)"
    }

    private static func anomalyMessage(
        for signal: HomeSignalEvent,
        entityName: String,
        measured: String,
        expected: String,
        thresholdBreach: ThresholdBreach?,
        direction: String
    ) -> String {
        let location = signal.roomName ?? signal.entityName
        let signalName = signalLabel(for: signal.signalType, lowercase: true)

        if let thresholdBreach {
            let level = thresholdBreach.level == .danger
                ? (isItalian ? "critico" : "critical")
                : (isItalian ? "attenzione" : "warning")
            if isItalian {
                return "In \(location) \(signalName) ha raggiunto \(measured) (livello \(level))."
            }
            return "In \(location), \(signalName) reached \(measured) (\(level) level)."
        }

        if isItalian {
            let relation = direction == "above" ? "sopra" : "sotto"
            return "\(entityName): valore attuale \(measured), \(relation) il valore atteso \(expected)."
        }

        return "\(entityName) reports \(measured), \(direction) its expected \(expected) baseline."
    }

    private static func thresholdTitle(for signalType: HomeSignalType, direction: String) -> String {
        if isItalian {
            switch signalType {
            case .temperature:
                return direction == "above" ? "Temperatura alta" : "Temperatura bassa"
            case .humidity:
                return direction == "above" ? "Umidità alta" : "Umidità bassa"
            case .airQuality:
                return "Qualità aria bassa"
            case .carbonDioxide:
                return "CO2 alta"
            case .carbonMonoxide:
                return "Monossido di carbonio rilevato"
            case .smoke:
                return "Fumo rilevato"
            case .vocDensity:
                return "VOC elevati"
            case .pm25:
                return "PM2.5 elevato"
            case .pm10:
                return "PM10 elevato"
            default:
                return "\(signalLabel(for: signalType, lowercase: false)) anomalo"
            }
        }

        switch signalType {
        case .temperature:
            return direction == "above" ? "High temperature" : "Low temperature"
        case .humidity:
            return direction == "above" ? "High humidity" : "Low humidity"
        case .airQuality:
            return "Low air quality"
        case .carbonDioxide:
            return "High CO2"
        case .carbonMonoxide:
            return "Carbon monoxide detected"
        case .smoke:
            return "Smoke detected"
        case .vocDensity:
            return "Elevated VOC"
        case .pm25:
            return "Elevated PM2.5"
        case .pm10:
            return "Elevated PM10"
        default:
            return "Anomalous \(signalLabel(for: signalType, lowercase: true))"
        }
    }

    private static func signalLabel(for signalType: HomeSignalType, lowercase: Bool) -> String {
        let label: String
        if isItalian {
            switch signalType {
            case .temperature: label = "Temperatura"
            case .humidity: label = "Umidità"
            case .airQuality: label = "Qualità aria"
            case .carbonMonoxide: label = "Monossido di carbonio"
            case .carbonDioxide: label = "CO2"
            case .smoke: label = "Fumo"
            case .vocDensity: label = "VOC"
            case .pm25: label = "PM2.5"
            case .pm10: label = "PM10"
            case .lightLevel: label = "Luce"
            default: label = "Valore"
            }
        } else {
            switch signalType {
            case .temperature: label = "Temperature"
            case .humidity: label = "Humidity"
            case .airQuality: label = "Air quality"
            case .carbonMonoxide: label = "Carbon monoxide"
            case .carbonDioxide: label = "CO2"
            case .smoke: label = "Smoke"
            case .vocDensity: label = "VOC"
            case .pm25: label = "PM2.5"
            case .pm10: label = "PM10"
            case .lightLevel: label = "Light"
            default: label = "Value"
            }
        }
        return lowercase ? label.lowercased() : label
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

    private static func format(_ value: Double, for signalType: HomeSignalType) -> String {
        if signalType == .airQuality {
            return airQualityLabel(for: value)
        }
        return String(format: "%.1f%@", value, unit(for: signalType))
    }

    private static func unit(for signalType: HomeSignalType) -> String {
        switch signalType {
        case .temperature:
            return "°C"
        case .humidity:
            return "%"
        case .carbonMonoxide, .carbonDioxide:
            return "ppm"
        case .vocDensity, .pm25, .pm10:
            return "µg/m³"
        case .lightLevel:
            return "lux"
        default:
            return ""
        }
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

    private static func policy(for signal: HomeSignalEvent) -> DetectionPolicy {
        switch signal.signalType {
        case .humidity:
            return DetectionPolicy(
                minimumAbsoluteDelta: 10,
                allowsRelativeBaseline: signal.sourceKind != .weather
            )
        case .temperature:
            return DetectionPolicy(
                minimumAbsoluteDelta: signal.sourceKind == .weather ? 4 : 2,
                thresholdBypassesMinimumDelta: false
            )
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
        durationBaseline: HomeBaseline?,
        configuration: Configuration
    ) -> HomeInsight? {
        let duration = interval.durationSeconds
        let rule = intervalRule(
            for: interval,
            durationBaseline: durationBaseline,
            configuration: configuration
        )
        guard let rule, duration >= rule.minimumDuration else { return nil }

        let entityName = displayEntityName(for: interval)
        let durationText = durationDescription(duration)
        let stateDescription = rule.stateDescription ?? interval.stateRaw
        let message: String
        let why: String
        if interval.isActive {
            message = isItalian ? "\(entityName) è attualmente \(stateDescription)." : "\(entityName) is currently \(stateDescription)."
            why = isItalian
                ? "Lo stato \(stateDescription) supera la policy \(rule.basis) di \(durationDescription(rule.minimumDuration)). La durata esatta non viene mostrata perché l'intervallo aperto dipende dallo storico eventi."
                : "The current \(stateDescription) state exceeds the \(durationDescription(rule.minimumDuration)) \(rule.basis). Exact duration is not shown because the open interval depends on event history."
        } else {
            message = isItalian ? "\(entityName) è rimasto \(stateDescription) per \(durationText)." : "\(entityName) has been \(stateDescription) for \(durationText)."
            why = isItalian
                ? "La durata \(durationText) supera la policy \(rule.basis) di \(durationDescription(rule.minimumDuration))."
                : "\(stateDescription) duration \(durationText) exceeds \(durationDescription(rule.minimumDuration)) \(rule.basis)."
        }

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
        durationBaseline: HomeBaseline?,
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
                title: contactOpenTitle(isWindowLike: isWindowLike),
                category: isWindowLike ? .security : .presence,
                severity: isElevated ? .medium : .low,
                recommendation: contactOpenRecommendation(isWindowLike: isWindowLike),
                confidence: isElevated ? 0.75 : 0.55,
                basis: contactOpenBasis(isWindowLike: isWindowLike),
                stateDescription: contactOpenStateDescription(isWindowLike: isWindowLike)
            )
        case .active where interval.stateRaw == "heating":
            let isSummer = Calendar.current.component(.month, from: Date()).isSummerMonth
            let role = climateRole(for: interval)
            return IntervalRule(
                minimumDuration: isSummer ? configuration.minimumSummerHeatingDuration : configuration.minimumHeatingDuration,
                title: heatingTitle(for: role),
                category: .environment,
                severity: isSummer ? .high : .medium,
                recommendation: heatingRecommendation(for: role),
                confidence: isSummer ? 0.85 : 0.65,
                basis: heatingBasis(for: role, isSummer: isSummer),
                stateDescription: heatingStateDescription(for: role)
            )
        case .power:
            let baselineDuration = durationBaseline.flatMap { $0.p95 ?? $0.mean }
            let minimumDuration = baselineDuration.map {
                max(
                    $0 * configuration.durationBaselineMultiplier,
                    configuration.minimumPowerDurationWithBaseline
                )
            } ?? configuration.minimumLongRunningPowerDuration
            let usesBaseline = baselineDuration != nil
            let role = powerRole(for: interval)
            let isElevated = interval.durationSeconds >= minimumDuration * 2
            return IntervalRule(
                minimumDuration: minimumDuration,
                title: powerTitle(for: role),
                category: powerCategory(for: role),
                severity: isElevated ? .medium : .low,
                recommendation: powerRecommendation(for: role),
                confidence: usesBaseline ? min(0.8, max(0.55, durationBaseline?.confidence ?? 0.55)) : 0.55,
                basis: usesBaseline ? powerBaselineBasis(for: role) : powerFallbackBasis(for: role),
                stateDescription: powerStateDescription(for: role)
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

    private static func climateRole(for interval: HomeStateInterval) -> ClimateRole {
        let name = "\(interval.entityName) \(interval.roomName ?? "")"
        if containsAny(
            name,
            tokens: ["valvola", "valve", "trv", "termostatica", "thermostatic valve"]
        ) {
            return .thermostaticValve
        }

        if containsAny(
            name,
            tokens: ["clima", "condizionatore", "climatizzatore", "air conditioner", "heat pump", "pompa di calore", "split"]
        ) {
            return .airConditioner
        }

        return .thermostat
    }

    private static func heatingTitle(for role: ClimateRole) -> String {
        if isItalian {
            switch role {
            case .thermostaticValve:
                return "Valvola termostatica in richiesta calore"
            case .airConditioner:
                return "Clima in modalità caldo"
            case .thermostat:
                return "Riscaldamento inatteso"
            }
        }

        switch role {
        case .thermostaticValve:
            return "Thermostatic valve requesting heat"
        case .airConditioner:
            return "Unexpected heat mode"
        case .thermostat:
            return "Unexpected thermostat heating"
        }
    }

    private static func heatingRecommendation(for role: ClimateRole) -> String {
        if isItalian {
            switch role {
            case .thermostaticValve:
                return "Controlla richiesta della valvola, setpoint stanza e programma riscaldamento."
            case .airConditioner:
                return "Controlla modalità del clima, programma e richiesta della pompa di calore."
            case .thermostat:
                return "Controlla programma, setpoint e richiesta di riscaldamento."
            }
        }

        switch role {
        case .thermostaticValve:
            return "Check valve demand, room setpoint, and heating schedule."
        case .airConditioner:
            return "Check climate mode, schedule, and heat-pump demand."
        case .thermostat:
            return "Check thermostat schedule, setpoint, and heating demand."
        }
    }

    private static func heatingBasis(for role: ClimateRole, isSummer: Bool) -> String {
        let prefix = isSummer ? (isItalian ? "estiva " : "summer ") : ""
        if isItalian {
            switch role {
            case .thermostaticValve:
                return "\(prefix)riscaldamento valvola termostatica"
            case .airConditioner:
                return "\(prefix)modalità caldo clima"
            case .thermostat:
                return "\(prefix)riscaldamento termostato"
            }
        }

        switch role {
        case .thermostaticValve:
            return "\(prefix)thermostatic valve heating policy"
        case .airConditioner:
            return "\(prefix)climate heat-mode policy"
        case .thermostat:
            return "\(prefix)thermostat heating policy"
        }
    }

    private static func heatingStateDescription(for role: ClimateRole) -> String {
        if isItalian {
            switch role {
            case .thermostaticValve:
                return "in richiesta calore"
            case .airConditioner:
                return "in modalità caldo"
            case .thermostat:
                return "in riscaldamento"
            }
        }

        switch role {
        case .thermostaticValve:
            return "requesting heat"
        case .airConditioner:
            return "in heat mode"
        case .thermostat:
            return "heating"
        }
    }

    private static func contactOpenTitle(isWindowLike: Bool) -> String {
        if isItalian {
            return isWindowLike ? "Finestra o porta aperta" : "Contatto aperto da verificare"
        }
        return isWindowLike ? "Window or door left open" : "Contact left open"
    }

    private static func contactOpenRecommendation(isWindowLike: Bool) -> String {
        if isItalian {
            return isWindowLike ? "Controlla se va chiusa o se deve restare aperta." : "Verifica se il contatto aperto è previsto."
        }
        return isWindowLike ? "Check whether it should be closed or intentionally open." : "Check whether this open contact is expected."
    }

    private static func contactOpenBasis(isWindowLike: Bool) -> String {
        if isItalian {
            return isWindowLike ? "contatto esterno aperto" : "contatto aperto"
        }
        return isWindowLike ? "open exterior contact policy" : "open contact policy"
    }

    private static func contactOpenStateDescription(isWindowLike: Bool) -> String {
        if isItalian {
            return isWindowLike ? "aperta" : "aperto"
        }
        return "open"
    }

    private static func powerTitle(for role: PowerRole) -> String {
        if isItalian {
            switch role {
            case .light:
                return "Luce accesa da molto"
            case .outlet:
                return "Presa attiva da molto"
            case .generic:
                return "Dispositivo acceso da molto"
            }
        }

        switch role {
        case .light:
            return "Light on for a long time"
        case .outlet:
            return "Outlet active for a long time"
        case .generic:
            return "Device on for a long time"
        }
    }

    private static func powerRecommendation(for role: PowerRole) -> String {
        if isItalian {
            switch role {
            case .light:
                return "Controlla se la luce deve restare accesa."
            case .outlet:
                return "Controlla il carico collegato e spegnilo se non serve."
            case .generic:
                return "Controlla se il dispositivo deve restare acceso."
            }
        }

        switch role {
        case .light:
            return "Check whether the light should still be on."
        case .outlet:
            return "Check the connected load and turn it off if not needed."
        case .generic:
            return "Check whether the device should still be on."
        }
    }

    private static func powerBaselineBasis(for role: PowerRole) -> String {
        if isItalian {
            switch role {
            case .light:
                return "durata abituale della luce"
            case .outlet:
                return "durata abituale della presa"
            case .generic:
                return "durata abituale del dispositivo"
            }
        }

        switch role {
        case .light:
            return "usual light duration"
        case .outlet:
            return "usual outlet duration"
        case .generic:
            return "usual device duration"
        }
    }

    private static func powerFallbackBasis(for role: PowerRole) -> String {
        if isItalian {
            switch role {
            case .light:
                return "policy luce accesa"
            case .outlet:
                return "policy presa attiva"
            case .generic:
                return "policy dispositivo acceso"
            }
        }

        switch role {
        case .light:
            return "light-on policy"
        case .outlet:
            return "outlet-active policy"
        case .generic:
            return "device-on policy"
        }
    }

    private static func powerStateDescription(for role: PowerRole) -> String {
        if isItalian {
            switch role {
            case .light:
                return "accesa"
            case .outlet:
                return "attiva"
            case .generic:
                return "acceso"
            }
        }

        switch role {
        case .light:
            return "on"
        case .outlet:
            return "active"
        case .generic:
            return "on"
        }
    }

    private static func powerCategory(for role: PowerRole) -> HomeInsightCategory {
        switch role {
        case .light:
            return .lighting
        case .outlet, .generic:
            return .deviceHealth
        }
    }

    private static func powerRole(for interval: HomeStateInterval) -> PowerRole {
        let name = "\(interval.entityName) \(interval.roomName ?? "")"
        if containsAny(
            name,
            tokens: ["luce", "lamp", "light", "bulb", "lampada", "faretti", "strip"]
        ) {
            return .light
        }
        if containsAny(
            name,
            tokens: ["presa", "plug", "outlet", "socket", "carico", "load", "power"]
        ) {
            return .outlet
        }
        return .generic
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

    private static func bestDurationBaseline(
        for interval: HomeStateInterval,
        in baselines: [HomeBaseline]
    ) -> HomeBaseline? {
        baselines
            .filter { baseline in
                baseline.baselineKind == .duration
                    && baseline.signalType == interval.signalType
                    && baseline.sampleCount > 0
                    && (baseline.mean != nil || baseline.p95 != nil)
                    && matchesScope(interval: interval, baseline: baseline)
                    && (baseline.contextKey?.contains(interval.stateRaw) ?? true)
            }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return (lhs.sampleCount, lhs.p95 ?? lhs.mean ?? 0) > (rhs.sampleCount, rhs.p95 ?? rhs.mean ?? 0)
                }
                return lhs.confidence > rhs.confidence
            }
            .first
    }

    private static func matchesScope(interval: HomeStateInterval, baseline: HomeBaseline) -> Bool {
        if let baselineEntityID = baseline.entityID, let intervalEntityID = interval.entityID {
            return baselineEntityID == intervalEntityID
        }
        if let baselineRoom = baseline.roomName, let intervalRoom = interval.roomName {
            return baselineRoom == intervalRoom
        }
        return false
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
        var thresholdBypassesMinimumDelta: Bool = true
    }

    private struct IntervalRule {
        var minimumDuration: TimeInterval
        var title: String
        var category: HomeInsightCategory
        var severity: HomeInsightSeverity
        var recommendation: String
        var confidence: Double
        var basis: String
        var stateDescription: String? = nil
    }

    private enum ClimateRole {
        case thermostat
        case thermostaticValve
        case airConditioner
    }

    private enum PowerRole {
        case light
        case outlet
        case generic
    }

    private static var isItalian: Bool {
        Locale.current.identifier.lowercased().hasPrefix("it")
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
