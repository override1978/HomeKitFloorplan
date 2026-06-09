import Foundation

// MARK: - PatternDetectionEngine

/// On-device behavioral pattern detection engine.
/// Analyzes BehavioralEvent arrays and returns BehavioralPattern objects.
/// No AI API calls — fully local, private, and fast.
enum PatternDetectionEngine {

    // Detection thresholds
    private static let minObservations         = 3
    private static let maxTimeDeviationMinutes = 25    // ±25 min = "consistent time"
    private static let sequentialWindowSeconds = 600.0 // 10 minutes
    private static let minSequentialHitRate    = 0.65

    // MARK: - Main Entry Point

    static func detect(
        accessoryEvents: [BehavioralEvent],
        sceneEvents: [BehavioralEvent],
        existingPatterns: [BehavioralPattern]
    ) -> [BehavioralPattern] {
        var newPatterns: [BehavioralPattern] = []
        newPatterns += detectTemporalPatterns(from: accessoryEvents, patternType: .temporal)
        newPatterns += detectTemporalPatterns(from: sceneEvents,     patternType: .scene)
        newPatterns += detectSequentialPatterns(from: accessoryEvents + sceneEvents)
        return merge(newPatterns: newPatterns, into: existingPatterns)
    }

    // MARK: - Temporal Pattern Detection

    private static func detectTemporalPatterns(
        from events: [BehavioralEvent],
        patternType: BehavioralPatternType
    ) -> [BehavioralPattern] {
        // Group by (accessoryName, action, dayType)
        var grouped: [String: [BehavioralEvent]] = [:]
        for event in events {
            let key = "\(event.accessoryName)|\(event.action.rawValue)|\(event.context.dayType.rawValue)"
            grouped[key, default: []].append(event)
        }

        var patterns: [BehavioralPattern] = []
        for (_, group) in grouped {
            guard group.count >= minObservations else { continue }

            let minutes = group.map(\.minuteOfDay)
            let mean    = minutes.reduce(0, +) / minutes.count
            let stdDev  = standardDeviation(minutes, mean: mean)
            guard stdDev <= Double(maxTimeDeviationMinutes) else { continue }

            let sorted   = group.sorted { $0.timestamp < $1.timestamp }
            let first    = sorted.first!
            let last     = sorted.last!
            let weekdays = Array(Set(group.map(\.context.weekday))).sorted()
            let daySpan  = Calendar.current
                .dateComponents([.day], from: first.timestamp, to: last.timestamp).day ?? 0

            // Classify weekday/weekend
            let observedSet    = Set(weekdays)
            let isWeekdayOnly  = observedSet.isSubset(of: Set([2, 3, 4, 5, 6]))
            let isWeekendOnly  = observedSet.isSubset(of: Set([1, 7]))
            let resolvedDayType: DayType? = isWeekdayOnly ? .weekday : isWeekendOnly ? .weekend : nil

            let description = temporalDescription(
                accessoryName: first.accessoryName,
                action: first.action,
                minuteOfDay: mean,
                dayType: resolvedDayType
            )

            let pattern = BehavioralPattern(
                id:                       UUID(),
                patternType:              patternType,
                detectedAt:               Date(),
                accessoryName:            first.accessoryName,
                accessoryID:              first.accessoryID,
                roomName:                 first.roomName,
                eventTypeRaw:             first.eventTypeRaw,
                action:                   first.action,
                numericValue:             first.numericValue,
                avgMinuteOfDay:           mean,
                timeDeviationMinutes:     Int(stdDev),
                weekdays:                 weekdays,
                dayType:                  resolvedDayType,
                causeSignature:           nil,
                causeName:                nil,
                avgGapSeconds:            nil,
                observations:             group.count,
                validations:              group.count,
                firstObservedAt:          first.timestamp,
                lastObservedAt:           last.timestamp,
                stabilityDays:            max(1, daySpan),
                status:                   .active,
                dismissedAt:              nil,
                approvedAt:               nil,
                naturalLanguageDescription: description
            )
            patterns.append(pattern)
        }
        return patterns
    }

    // MARK: - Sequential Pattern Detection

    private static func detectSequentialPatterns(
        from events: [BehavioralEvent]
    ) -> [BehavioralPattern] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 6 else { return [] }

        var causeCounts:   [String: Int]            = [:]  // cause sig → how many times it occurred
        var followCounts:  [String: [String: Int]]  = [:]  // cause sig → [effect sig → hit count]
        var gapSums:       [String: Double]         = [:]  // pairKey → total gap seconds
        var firstExamples: [String: (BehavioralEvent, BehavioralEvent)] = [:]

        for (i, cause) in sorted.enumerated() {
            causeCounts[cause.signature, default: 0] += 1
            for j in (i + 1)..<sorted.count {
                let effect = sorted[j]
                let gap = effect.timestamp.timeIntervalSince(cause.timestamp)
                guard gap <= sequentialWindowSeconds else { break }
                guard effect.signature != cause.signature else { continue }

                let pairKey = "\(cause.signature)→\(effect.signature)"
                followCounts[cause.signature, default: [:]][effect.signature, default: 0] += 1
                gapSums[pairKey, default: 0] += gap
                if firstExamples[pairKey] == nil {
                    firstExamples[pairKey] = (cause, effect)
                }
            }
        }

        var patterns: [BehavioralPattern] = []
        for (causeSig, effects) in followCounts {
            let totalCauses = causeCounts[causeSig] ?? 1
            for (effectSig, hitCount) in effects {
                guard hitCount >= minObservations else { continue }
                let hitRate = Double(hitCount) / Double(totalCauses)
                guard hitRate >= minSequentialHitRate else { continue }

                let pairKey = "\(causeSig)→\(effectSig)"
                let avgGap  = (gapSums[pairKey] ?? 0) / Double(hitCount)
                guard let (exCause, exEffect) = firstExamples[pairKey] else { continue }

                let description = sequentialDescription(
                    causeName: exCause.accessoryName,
                    effectName: exEffect.accessoryName,
                    effectAction: exEffect.action,
                    avgGapSeconds: avgGap
                )

                let pattern = BehavioralPattern(
                    id:                       UUID(),
                    patternType:              .sequential,
                    detectedAt:               Date(),
                    accessoryName:            exEffect.accessoryName,
                    accessoryID:              exEffect.accessoryID,
                    roomName:                 exEffect.roomName,
                    eventTypeRaw:             exEffect.eventTypeRaw,
                    action:                   exEffect.action,
                    numericValue:             exEffect.numericValue,
                    avgMinuteOfDay:           exEffect.minuteOfDay,
                    timeDeviationMinutes:     max(1, Int(avgGap / 60)),
                    weekdays:                 [],
                    dayType:                  nil,
                    causeSignature:           causeSig,
                    causeName:                exCause.accessoryName,
                    avgGapSeconds:            avgGap,
                    observations:             hitCount,
                    validations:              hitCount,
                    firstObservedAt:          exEffect.timestamp,
                    lastObservedAt:           exEffect.timestamp,
                    stabilityDays:            1,
                    status:                   .active,
                    dismissedAt:              nil,
                    approvedAt:               nil,
                    naturalLanguageDescription: description
                )
                patterns.append(pattern)
            }
        }
        return patterns
    }

    // MARK: - Merge

    private static func merge(
        newPatterns: [BehavioralPattern],
        into existing: [BehavioralPattern]
    ) -> [BehavioralPattern] {
        // Keep all dismissed/approved/dormant patterns as-is
        var result: [BehavioralPattern] = existing.filter {
            $0.status == .dismissed || $0.status == .approved || $0.status == .dormant
        }

        // For active/decaying existing patterns, update or replace
        var updatedExistingIDs = Set<UUID>()

        for new in newPatterns {
            if let existingIdx = existing.firstIndex(where: {
                $0.deduplicationKey == new.deduplicationKey &&
                $0.status != .dismissed &&
                $0.status != .approved &&
                abs($0.avgMinuteOfDay - new.avgMinuteOfDay) < 30
            }) {
                var updated = existing[existingIdx]
                updatedExistingIDs.insert(updated.id)

                // Increment confidence data
                updated.observations     = max(updated.observations, new.observations)
                updated.validations      = max(updated.validations,  new.validations)
                updated.lastObservedAt   = max(updated.lastObservedAt, new.lastObservedAt)
                updated.firstObservedAt  = min(updated.firstObservedAt, new.firstObservedAt)
                updated.stabilityDays    = max(updated.stabilityDays, new.stabilityDays)
                updated.weekdays         = Array(Set(updated.weekdays + new.weekdays)).sorted()
                // Smooth the avg time
                updated.avgMinuteOfDay   = (updated.avgMinuteOfDay + new.avgMinuteOfDay) / 2
                updated.timeDeviationMinutes = (updated.timeDeviationMinutes + new.timeDeviationMinutes) / 2

                // Re-evaluate dormancy
                let daysSinceLast = Calendar.current.dateComponents(
                    [.day], from: updated.lastObservedAt, to: Date()).day ?? 0
                if daysSinceLast >= 30 {
                    updated.status = .dormant
                } else if daysSinceLast >= 7 {
                    updated.status = .decaying
                } else {
                    updated.status = .active
                }

                result.append(updated)
            } else {
                result.append(new)
            }
        }

        // Keep active/decaying existing patterns that weren't updated
        for existing in existing where
            (existing.status == .active || existing.status == .decaying) &&
            !updatedExistingIDs.contains(existing.id)
        {
            var stale = existing
            let days = Calendar.current.dateComponents([.day], from: stale.lastObservedAt, to: Date()).day ?? 0
            if days >= 30 { stale.status = .dormant }
            else if days >= 7 { stale.status = .decaying }
            if !result.contains(where: { $0.id == stale.id }) {
                result.append(stale)
            }
        }

        return result
    }

    // MARK: - Statistics

    private static func standardDeviation(_ values: [Int], mean: Int) -> Double {
        guard values.count > 1 else { return 0 }
        let dMean    = Double(mean)
        let variance = values
            .map { pow(Double($0) - dMean, 2) }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    // MARK: - Natural Language Generation

    private static func temporalDescription(
        accessoryName: String,
        action: BehavioralAction,
        minuteOfDay: Int,
        dayType: DayType?
    ) -> String {
        let h = minuteOfDay / 60
        let m = minuteOfDay % 60
        let timeStr  = String(format: "%02d:%02d", h, m)
        let dayLabel = dayType?.localizedLabel
            ?? String(localized: "behavioral.dayType.daily", defaultValue: "ogni giorno")

        switch action {
        case .on:
            return String(format: String(localized: "behavioral.pattern.temporal.on",
                                          defaultValue: "%1$@ viene acceso %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .off:
            return String(format: String(localized: "behavioral.pattern.temporal.off",
                                          defaultValue: "%1$@ viene spento %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .dim:
            return String(format: String(localized: "behavioral.pattern.temporal.dim",
                                          defaultValue: "%1$@ viene abbassato %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .activate:
            return String(format: String(localized: "behavioral.pattern.temporal.activate",
                                          defaultValue: "%1$@ viene attivato %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .lock:
            return String(format: String(localized: "behavioral.pattern.temporal.lock",
                                          defaultValue: "%1$@ viene bloccato %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .unlock:
            return String(format: String(localized: "behavioral.pattern.temporal.unlock",
                                          defaultValue: "%1$@ viene sbloccato %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .open:
            return String(format: String(localized: "behavioral.pattern.temporal.open",
                                          defaultValue: "%1$@ viene aperto %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .close:
            return String(format: String(localized: "behavioral.pattern.temporal.close",
                                          defaultValue: "%1$@ viene chiuso %2$@ alle %3$@"),
                          accessoryName, dayLabel, timeStr)
        }
    }

    private static func sequentialDescription(
        causeName: String,
        effectName: String,
        effectAction: BehavioralAction,
        avgGapSeconds: Double
    ) -> String {
        let gapMinutes = max(1, Int(avgGapSeconds / 60))
        switch effectAction {
        case .on:
            return String(format: String(localized: "behavioral.pattern.sequential.on",
                                          defaultValue: "Dopo %1$@, %2$@ viene acceso entro %3$d min"),
                          causeName, effectName, gapMinutes)
        case .off:
            return String(format: String(localized: "behavioral.pattern.sequential.off",
                                          defaultValue: "Dopo %1$@, %2$@ viene spento entro %3$d min"),
                          causeName, effectName, gapMinutes)
        case .dim:
            return String(format: String(localized: "behavioral.pattern.sequential.dim",
                                          defaultValue: "Dopo %1$@, %2$@ viene abbassato entro %3$d min"),
                          causeName, effectName, gapMinutes)
        case .activate:
            return String(format: String(localized: "behavioral.pattern.sequential.activate",
                                          defaultValue: "Dopo %1$@, %2$@ viene attivato entro %3$d min"),
                          causeName, effectName, gapMinutes)
        default:
            return String(format: String(localized: "behavioral.pattern.sequential.default",
                                          defaultValue: "Quando %1$@ viene usato, %2$@ cambia entro %3$d min"),
                          causeName, effectName, gapMinutes)
        }
    }
}
