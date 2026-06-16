import Foundation

// MARK: - GateRejection

/// Diagnostic record for a filter gate that rejected candidate patterns during the last detection run.
struct GateRejection: Identifiable {
    enum Reason: String {
        case insufficientObservations   = "Too few observations (< 3)"
        case highTimeDeviation          = "Time deviation too high (> 60 min)"
        case lowSequentialHitRate       = "Sequential hit rate too low (< 65%)"
        case insufficientSequentialHits = "Sequential: too few hits (< 3)"
        case insufficientDistinctDays   = "Sequential: hits not on 3+ distinct days"
        case coupledPairExcluded        = "Coupled pair excluded from sequential"
    }
    var id: String { reason.rawValue }
    let reason: Reason
    let count:  Int
    let detail: String
}

// MARK: - CoupledPairReport

/// Diagnostic record for a device pair whose co-occurrence frequency exceeds the coupling threshold,
/// causing both directions to be excluded from sequential pattern detection.
struct CoupledPairReport: Identifiable {
    var id: String { [deviceA, deviceB].sorted().joined(separator: "↔") }
    let deviceA:         String
    let deviceB:         String
    let dailyFrequency:  Double   // combined A→B + B→A occurrences per day
    let isBidirectional: Bool     // minority direction ≥ 25% of total
    let distinctHours:   Int      // distinct hours-of-day where co-occurrences happen
    let daysCoverage:    Int      // days on which this pair co-occurred
    let totalEventDays:  Int      // total days with any events in the residual window
}

// MARK: - BurstReport

/// Diagnostic record for a distinct burst signature detected in the last analysis run.
/// A burst is a rapid cascade of ≥ 4 distinct accessories changing state (e.g., a HomeKit scene).
struct BurstReport: Identifiable {
    var id: String { signature }
    let label:            String    // human-readable name (scene name if matched, else member list)
    let signature:        String    // stable hash of sorted accessory:action pairs
    let occurrenceCount:  Int       // how many times this burst was seen
    let matchedSceneName: String?   // scene name from ActivityEvent if matched within ±120s
    let memberCount:      Int       // distinct accessories in the burst
}

// MARK: - ContextualCandidate

/// Diagnostic record for a pattern group rejected by the time-deviation gate.
/// These are prime candidates for the Contextual Phase: habits triggered by
/// environmental conditions (temp, lux, humidity) rather than a fixed clock time.
struct ContextualCandidate: Identifiable {
    var id: String { "\(accessoryName)|\(action)|\(roomName ?? "")|\(stdDevMinutes)" }
    let accessoryName:  String
    let action:         String
    let roomName:       String?
    let occurrences:    Int       // number of observations that caused the rejection
    let stdDevMinutes:  Int       // time spread that exceeded the gate threshold
    let distinctDays:   Int       // distinct calendar days on which the events occurred
    let minMinuteOfDay: Int       // earliest occurrence (minutes 0–1439)
    let maxMinuteOfDay: Int       // latest occurrence (minutes 0–1439)
}

// MARK: - PatternDetectionEngine

/// On-device behavioral pattern detection engine.
/// Analyzes BehavioralEvent arrays and returns BehavioralPattern objects.
/// No AI API calls — fully local, private, and fast.
enum PatternDetectionEngine {

    // Detection thresholds
    private static let minObservations         = 3
    private static let maxTimeDeviationMinutes = 60    // ±60 min = realistic human behavior
    private static let sequentialWindowSeconds = 600.0 // 10 minutes
    private static let minSequentialHitRate    = 0.65

    // Event type filter — motion and contact sensors produce spurious sequential hits
    // and are not habit-forming targets for automation suggestions.
    private static let habitEligibleTypes: Set<String> = [
        "light", "blind", "switch", "thermostat", "fan", "airPurifier", "outlet"
    ]

    // Burst detection — a rapid cascade of ≥ burstMinSize distinct accessories
    // within a chain-linked gap of ≤ burstGapSeconds indicates a HomeKit scene or group action.
    // Burst members are excluded from individual temporal and sequential detection.
    static let burstMinSize:    Int    = 4
    static let burstGapSeconds: Double = 90.0

    // Burst clustering — adaptive Jaccard threshold that scales with union size so small
    // clusters tolerate one missing device without splitting into twin clusters.
    //   union ≤ 5   → 0.50  (e.g. 4-device routine: 1 difference → Jaccard 0.60 ≥ 0.50 ✓)
    //   union 6–10  → 0.55
    //   union > 10  → 0.60
    private static func clusterThreshold(forUnionSize n: Int) -> Double {
        if n <= 5  { return 0.50 }
        if n <= 10 { return 0.55 }
        return 0.60
    }

    // Device coupling — accessory pairs that co-fire ≥ this frequency per day (or bidirectionally
    // ≥ 3/day with minority ≥ 25%) are excluded from sequential pattern suggestions.
    private static let couplingFrequencyThreshold: Double = 6.0

    // MARK: - Diagnostics (populated on every detect() call)

    /// Gate rejections from the most recent `detect()` call.
    private(set) static var lastGateLog: [GateRejection] = []
    private static var gateCounters: [GateRejection.Reason: (count: Int, detail: String)] = [:]

    /// Burst cluster reports from the most recent `detect()` call.
    private(set) static var lastBurstReport:        [BurstReport] = []
    private(set) static var lastAbsorbedEventCount: Int           = 0

    /// Coupled device-pair reports from the most recent `detect()` call.
    private(set) static var lastCoupledPairs: [CoupledPairReport] = []

    /// Deduplication keys of patterns that were freshly detected (pre-merge) in the last run.
    /// Used by BehavioralAnalysisService to identify and remove stale artefact patterns.
    private(set) static var lastDetectedKeys: Set<String> = []

    /// Contextual candidates: groups rejected by the time-deviation gate in the last run.
    /// Sorted by occurrences descending, capped at 20. Purely diagnostic — no effect on detection.
    private(set) static var lastContextualCandidates: [ContextualCandidate] = []
    private static var contextualCandidateBuffer: [ContextualCandidate] = []

    private static func gate(_ reason: GateRejection.Reason, detail: String = "") {
        let existing = gateCounters[reason, default: (0, "")]
        gateCounters[reason] = (existing.count + 1, detail.isEmpty ? existing.detail : detail)
    }

    // MARK: - Main Entry Point

    static func detect(
        accessoryEvents: [BehavioralEvent],
        sceneEvents: [BehavioralEvent],
        existingPatterns: [BehavioralPattern]
    ) -> [BehavioralPattern] {
        gateCounters = [:]
        contextualCandidateBuffer = []
        // Filter motion/contact/camera, then collapse duplicate events within 30s windows.
        let eligibleAccessoryEvents = deduplicateEvents(
            accessoryEvents.filter { habitEligibleTypes.contains($0.eventTypeRaw) }
        )
        let deduplicatedSceneEvents = deduplicateEvents(sceneEvents)

        // Detect bursts first; absorbing scene cascades before coupling detection ensures
        // co-occurrence counts on residual events reflect only true user-driven habits.
        let (burstEvents, absorbedIDs) = detectBursts(
            from: eligibleAccessoryEvents,
            sceneEvents: deduplicatedSceneEvents
        )
        let individualEvents = eligibleAccessoryEvents.filter { !absorbedIDs.contains($0.id) }
        let allSceneEvents   = deduplicatedSceneEvents + burstEvents

        // Coupled pair detection on RESIDUAL events only (burst members already removed).
        // With scene cascade events absorbed, only true user-driven events remain, so
        // co-occurrence counts reflect real automation habits rather than scene noise.
        let coupledPairs = detectCoupledPairs(from: individualEvents)

        var newPatterns: [BehavioralPattern] = []
        newPatterns += detectTemporalPatterns(from: individualEvents,  patternType: .temporal)
        newPatterns += detectTemporalPatterns(from: allSceneEvents,    patternType: .scene)
        newPatterns += detectSequentialPatterns(from: individualEvents + allSceneEvents,
                                                excludingCoupledPairs: coupledPairs)

        lastDetectedKeys = Set(newPatterns.map(\.deduplicationKey))
        lastGateLog = gateCounters
            .map { GateRejection(reason: $0.key, count: $0.value.count, detail: $0.value.detail) }
            .sorted { $0.count > $1.count }
        lastContextualCandidates = Array(
            contextualCandidateBuffer
                .sorted { $0.occurrences > $1.occurrences }
                .prefix(20)
        )
        return merge(newPatterns: newPatterns, into: existingPatterns)
    }

    // MARK: - Burst Detection

    /// Identifies rapid multi-device state changes (HomeKit scene cascades) and returns
    /// one synthetic BehavioralEvent per burst cluster instance plus the set of absorbed event IDs.
    ///
    /// Algorithm:
    ///   Phase 1  — Chain-link scan: collects burst chains of ≥ burstMinSize distinct accessories.
    ///   Phase 2  — Jaccard clustering with adaptive threshold (union ≤ 5 → 0.50, 6–10 → 0.55, >10 → 0.60).
    ///   Phase 2c — Core validation: member frequency at 50%/40%/35%; invalid if core < burstMinSize.
    ///   Phase 3  — Synthetic events; clusterID = top-4 most frequent members sorted alphabetically.
    private static func detectBursts(
        from events: [BehavioralEvent],
        sceneEvents: [BehavioralEvent]
    ) -> (bursts: [BehavioralEvent], absorbedIDs: Set<UUID>) {

        // ── Phase 1: Chain-link scan ──────────────────────────────────────────
        struct RawBurst {
            let members:          Set<String>
            let timestamp:        Date
            let matchedSceneName: String?
        }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var absorbedIDs = Set<UUID>()
        var rawBursts:  [RawBurst] = []

        var i = 0
        while i < sorted.count {
            let anchor = sorted[i]
            guard !absorbedIDs.contains(anchor.id) else { i += 1; continue }

            var chain:    [BehavioralEvent] = [anchor]
            var seen:     Set<String>       = [anchor.accessoryName]
            var chainEnd: Date              = anchor.timestamp
            var j = i + 1
            while j < sorted.count {
                let ev = sorted[j]
                guard ev.timestamp.timeIntervalSince(chainEnd) <= burstGapSeconds else { break }
                if !seen.contains(ev.accessoryName) && !absorbedIDs.contains(ev.id) {
                    chain.append(ev); seen.insert(ev.accessoryName); chainEnd = ev.timestamp
                }
                j += 1
            }

            guard chain.count >= burstMinSize else { i += 1; continue }
            chain.forEach { absorbedIDs.insert($0.id) }

            let burstTime    = chain[0].timestamp
            let matchedScene = sceneEvents.first {
                abs($0.timestamp.timeIntervalSince(burstTime)) <= 120
            }?.accessoryName

            rawBursts.append(RawBurst(members: seen, timestamp: burstTime,
                                      matchedSceneName: matchedScene))
            i += 1
        }

        guard !rawBursts.isEmpty else {
            lastBurstReport        = []
            lastAbsorbedEventCount = absorbedIDs.count
            return ([], absorbedIDs)
        }

        // ── Phase 2: Jaccard clustering (adaptive threshold) ─────────────────
        struct BurstCluster {
            var unionMembers: Set<String>
            var occurrences:  [RawBurst]
        }

        var clusters: [BurstCluster] = []
        for burst in rawBursts.sorted(by: { $0.timestamp < $1.timestamp }) {
            var bestIdx:       Int?   = nil
            var bestSim:       Double = 0.0
            var bestThreshold: Double = 1.0

            for (idx, cluster) in clusters.enumerated() {
                let sim = jaccardSimilarity(burst.members, cluster.unionMembers)
                if sim > bestSim {
                    bestSim       = sim
                    bestIdx       = idx
                    let unionSize = burst.members.union(cluster.unionMembers).count
                    bestThreshold = clusterThreshold(forUnionSize: unionSize)
                }
            }

            if bestSim >= bestThreshold, let idx = bestIdx {
                clusters[idx].occurrences.append(burst)
                clusters[idx].unionMembers.formUnion(burst.members)
            } else {
                clusters.append(BurstCluster(unionMembers: burst.members, occurrences: [burst]))
            }
        }

        // ── Phase 2c: Validate core ≥ burstMinSize and consolidate identical clusterIDs ─────────
        // Compute per-member frequency; try 50%/40%/35% thresholds; reject if core < burstMinSize.
        // The clusterID uses the top-4 most frequent members sorted alphabetically — stable across
        // consecutive analysis runs on the same 30-day event window.
        // Two Jaccard clusters with the same resulting top-4 are merged here so that a single
        // logical routine never produces duplicate BurstReport entries.
        struct ValidCluster {
            let clusterID:   String
            let coreMembers: [String]   // all core members (freq-sorted); top-4 in clusterID
            var occurrences: [RawBurst]
        }
        var validClusters: [String: ValidCluster] = [:]

        for cluster in clusters {
            let totalOcc = cluster.occurrences.count
            var memberFrequency: [String: Int] = [:]
            for occurrence in cluster.occurrences {
                for member in occurrence.members {
                    memberFrequency[member, default: 0] += 1
                }
            }

            var coreMembers: [String] = []
            for threshold in [0.50, 0.40, 0.35] as [Double] {
                let core = memberFrequency.filter { Double($0.value) / Double(totalOcc) >= threshold }
                if core.count >= burstMinSize {
                    coreMembers = core.keys.sorted { a, b in
                        let fa = memberFrequency[a] ?? 0
                        let fb = memberFrequency[b] ?? 0
                        return fa != fb ? fa > fb : a < b
                    }
                    break
                }
            }
            guard !coreMembers.isEmpty else { continue }

            let top4      = Array(coreMembers.prefix(burstMinSize)).sorted()
            let clusterID = "burst_cluster:" + top4.joined(separator: "|")

            if validClusters[clusterID] != nil {
                validClusters[clusterID]!.occurrences.append(contentsOf: cluster.occurrences)
            } else {
                validClusters[clusterID] = ValidCluster(
                    clusterID:   clusterID,
                    coreMembers: coreMembers,
                    occurrences: cluster.occurrences
                )
            }
        }

        var syntheticEvents: [BehavioralEvent] = []
        var burstReports:    [BurstReport]     = []

        for (clusterID, vc) in validClusters {
            let top4Parts    = String(clusterID.dropFirst("burst_cluster:".count))
                .split(separator: "|").map(String.init)
            let matchedScene = vc.occurrences.compactMap(\.matchedSceneName).first
            let label: String
            if let scene = matchedScene {
                label = scene
            } else if top4Parts.count <= 3 {
                label = top4Parts.joined(separator: ", ")
            } else {
                label = top4Parts.prefix(3).joined(separator: ", ") + " +\(vc.coreMembers.count - 3)"
            }

            for burst in vc.occurrences {
                let cal    = Calendar.current
                let hour   = cal.component(.hour,    from: burst.timestamp)
                let minute = cal.component(.minute,  from: burst.timestamp)
                let wday   = cal.component(.weekday, from: burst.timestamp)
                let ctx    = BehavioralEventContext(
                    timeOfDay:   TimeOfDay(hour: hour),
                    dayType:     DayType(weekday: wday),
                    hourOfDay:   hour,
                    minuteOfDay: hour * 60 + minute,
                    weekday:     wday
                )
                syntheticEvents.append(BehavioralEvent(
                    id:            UUID(),
                    timestamp:     burst.timestamp,
                    source:        .scene,
                    accessoryID:   nil,
                    accessoryName: label,
                    roomName:      "",
                    eventTypeRaw:  "burst",
                    action:        .activate,
                    numericValue:  nil,
                    context:       ctx,
                    groupingKey:   clusterID
                ))
            }

            burstReports.append(BurstReport(
                label:            label,
                signature:        clusterID,
                occurrenceCount:  vc.occurrences.count,
                matchedSceneName: matchedScene,
                memberCount:      vc.coreMembers.count
            ))
        }

        lastBurstReport        = burstReports.sorted { $0.occurrenceCount > $1.occurrenceCount }
        lastAbsorbedEventCount = absorbedIDs.count
        return (syntheticEvents, absorbedIDs)
    }

    // MARK: - Coupled Pair Detection

    /// Returns the set of coupled device-pair keys (format: `"nameA\0nameB"`) to exclude
    /// from sequential pattern detection. A pair is coupled when it co-fires too frequently
    /// to represent a meaningful user-driven habit.
    private static func detectCoupledPairs(from events: [BehavioralEvent]) -> Set<String> {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { lastCoupledPairs = []; return [] }

        let cal = Calendar.current
        let totalEventDays = Set(sorted.map { cal.startOfDay(for: $0.timestamp) }).count

        var pairHits:    [String: [String: Int]]  = [:]
        var pairCoTimes: [String: [Date]]          = [:]  // canonical key → co-occurrence timestamps
        for (i, cause) in sorted.enumerated() {
            for j in (i + 1)..<sorted.count {
                let effect = sorted[j]
                let gap = effect.timestamp.timeIntervalSince(cause.timestamp)
                guard gap <= sequentialWindowSeconds else { break }
                guard cause.accessoryName != effect.accessoryName else { continue }
                pairHits[cause.accessoryName, default: [:]][effect.accessoryName, default: 0] += 1
                let canonical = [cause.accessoryName, effect.accessoryName].sorted().joined(separator: "\u{01}")
                pairCoTimes[canonical, default: []].append(cause.timestamp)
            }
        }

        let daySpan = max(1.0, Double(
            cal.dateComponents([.day],
                from: sorted.first!.timestamp, to: sorted.last!.timestamp).day ?? 0) + 1.0)

        var coupledSet:    Set<String>         = []
        var seenCanonical: Set<String>         = []
        var reports:       [CoupledPairReport] = []

        for (causeN, effects) in pairHits {
            for (effectN, count) in effects {
                let canonical = [causeN, effectN].sorted().joined(separator: "\u{01}")
                guard !seenCanonical.contains(canonical) else { continue }
                seenCanonical.insert(canonical)

                let freqAB    = Double(count) / daySpan
                let freqBA    = Double(pairHits[effectN]?[causeN] ?? 0) / daySpan
                let totalFreq = freqAB + freqBA
                let minority  = min(freqAB, freqBA)
                let isBidir   = totalFreq > 0 && minority / totalFreq >= 0.25

                let passesFrequency = totalFreq >= couplingFrequencyThreshold ||
                                      (isBidir && freqAB >= 3.0 && freqBA >= 3.0)
                guard passesFrequency else { continue }

                // Anti-false-positive gates: a truly coupled automation pair fires at all hours
                // of the day (motion sensors, always-on schedules) and on most event days.
                // Scene routines concentrate in 1-2 time slots and are NOT coupled automations.
                let coTimes      = pairCoTimes[canonical] ?? []
                let distinctHrs  = Set(coTimes.map { cal.component(.hour, from: $0) }).count
                let pairDays     = Set(coTimes.map { cal.startOfDay(for: $0) }).count
                let daysFraction = Double(pairDays) / Double(max(1, totalEventDays))

                guard distinctHrs >= 5 && daysFraction >= 0.60 else { continue }

                coupledSet.insert("\(causeN)\u{00}\(effectN)")
                coupledSet.insert("\(effectN)\u{00}\(causeN)")
                reports.append(CoupledPairReport(
                    deviceA:        causeN,
                    deviceB:        effectN,
                    dailyFrequency: totalFreq,
                    isBidirectional: isBidir,
                    distinctHours:  distinctHrs,
                    daysCoverage:   pairDays,
                    totalEventDays: totalEventDays
                ))
            }
        }

        lastCoupledPairs = reports.sorted { $0.dailyFrequency > $1.dailyFrequency }
        return coupledSet
    }

    // MARK: - Jaccard Similarity

    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let unionCount = a.union(b).count
        return unionCount == 0 ? 0 : Double(a.intersection(b).count) / Double(unionCount)
    }

    // MARK: - Temporal Pattern Detection

    /// Splits a burst-cluster group into time-of-day bands. Cluster groups intentionally
    /// omit dayType from the grouping key, so one cluster can contain occurrences at several
    /// distinct times of day (same device set used both morning and evening). Evaluating
    /// them as a single population explodes stdDev and the whole routine dies in the
    /// 60-minute gate. Occurrences sorted by minuteOfDay are split wherever the gap
    /// between consecutive values exceeds 120 minutes; the first and last band are merged
    /// when they sit within 120 minutes across the midnight wrap.
    private static func splitIntoTimeBands(_ events: [BehavioralEvent]) -> [[BehavioralEvent]] {
        guard events.count > 1 else { return [events] }
        let sorted = events.sorted { $0.minuteOfDay < $1.minuteOfDay }
        var bands: [[BehavioralEvent]] = [[sorted[0]]]
        for ev in sorted.dropFirst() {
            if ev.minuteOfDay - bands[bands.count - 1].last!.minuteOfDay > 120 {
                bands.append([ev])
            } else {
                bands[bands.count - 1].append(ev)
            }
        }
        // Midnight wrap: 23:50 and 00:15 belong to the same routine.
        if bands.count > 1,
           (1440 - bands.last!.last!.minuteOfDay) + bands.first!.first!.minuteOfDay <= 120 {
            let lastBand = bands.removeLast()
            bands[0] = lastBand + bands[0]
        }
        return bands
    }

    private static func detectTemporalPatterns(
        from events: [BehavioralEvent],
        patternType: BehavioralPatternType
    ) -> [BehavioralPattern] {
        // Group by (stableIdentifier, action[, dayType]).
        // For burst-cluster events `groupingKey` is the stable cluster ID. dayType is intentionally
        // OMITTED from the key so all occurrences of the same cluster accumulate in one group
        // regardless of whether they fall on weekdays or weekends. Splitting by dayType would
        // fragment a daily routine into two underpowered subgroups (e.g. 8 weekday + 6 weekend
        // instead of 14), each matching the persisted pattern only partially via Jaccard and
        // producing frozen low-observation stats. The weekday/weekend/daily classification is then
        // derived after grouping from the full weekday distribution of the merged group.
        // For regular accessory events `groupingKey` is nil; dayType stays in the key so
        // weekday-only and weekend-only accessory habits are kept separate.
        var grouped: [String: [BehavioralEvent]] = [:]
        for event in events {
            let nameKey = event.groupingKey ?? event.accessoryName
            let key: String
            if event.groupingKey != nil {
                key = "\(nameKey)|\(event.action.rawValue)"
            } else {
                key = "\(nameKey)|\(event.action.rawValue)|\(event.context.dayType.rawValue)"
            }
            grouped[key, default: []].append(event)
        }

        var patterns: [BehavioralPattern] = []
        for (_, wholeGroup) in grouped {
            // Cluster groups (groupingKey != nil) are partitioned into time-of-day bands
            // before statistics; individual accessory groups are evaluated as-is.
            let bands = wholeGroup.first?.groupingKey != nil
                ? splitIntoTimeBands(wholeGroup)
                : [wholeGroup]

            for group in bands {
            guard group.count >= minObservations else {
                gate(.insufficientObservations)
                continue
            }

            // Handle the midnight wrap inside a band: if the band spans more than 12h on the
            // raw scale it crosses midnight — shift early-morning minutes by +1440 so the
            // arithmetic mean and stdDev are computed on a contiguous scale.
            let rawMinutes = group.map(\.minuteOfDay)
            let wrapsMidnight = (rawMinutes.max()! - rawMinutes.min()!) > 720
            let minutes = wrapsMidnight ? rawMinutes.map { $0 < 720 ? $0 + 1440 : $0 } : rawMinutes
            let meanAdjusted = minutes.reduce(0, +) / minutes.count
            let mean    = meanAdjusted % 1440
            let stdDev  = standardDeviation(minutes, mean: meanAdjusted)
            guard stdDev <= Double(maxTimeDeviationMinutes) else {
                gate(.highTimeDeviation, detail: "stdDev=\(Int(stdDev))min")
                // Capture for contextual-phase diagnostics: this group is time-scattered
                // but may correlate with environmental triggers (temp, lux, etc.).
                let rejectedFirst = group.min(by: { $0.timestamp < $1.timestamp })!
                let rejectedDistinctDays = Set(group.map {
                    Calendar.current.startOfDay(for: $0.timestamp)
                }).count
                contextualCandidateBuffer.append(ContextualCandidate(
                    accessoryName:  rejectedFirst.accessoryName,
                    action:         rejectedFirst.action.rawValue,
                    roomName:       rejectedFirst.roomName,
                    occurrences:    group.count,
                    stdDevMinutes:  Int(stdDev),
                    distinctDays:   rejectedDistinctDays,
                    minMinuteOfDay: rawMinutes.min()!,
                    maxMinuteOfDay: rawMinutes.max()!
                ))
                continue
            }

            let sorted      = group.sorted { $0.timestamp < $1.timestamp }
            let first       = sorted.first!
            let last        = sorted.last!
            let weekdays    = Array(Set(group.map(\.context.weekday))).sorted()
            let daySpan     = Calendar.current
                .dateComponents([.day], from: first.timestamp, to: last.timestamp).day ?? 0
            let distinctDays = Set(group.map { Calendar.current.startOfDay(for: $0.timestamp) }).count

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

            // For burst-cluster events the groupingKey is the stable cluster ID.
            // Store it as causeSignature so deduplicationKey is stable across runs.
            let clusterSig = group.first?.groupingKey

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
                causeSignature:           clusterSig,
                causeName:                nil,
                avgGapSeconds:            nil,
                observations:             group.count,
                validations:              group.count,
                firstObservedAt:          first.timestamp,
                lastObservedAt:           last.timestamp,
                stabilityDays:            max(1, daySpan),
                distinctActiveDays:       distinctDays,
                status:                   .active,
                dismissedAt:              nil,
                approvedAt:               nil,
                naturalLanguageDescription: description
            )
            #if DEBUG
            if let d = pattern.distinctActiveDays {
                let calSpan = max(1, Calendar.current.dateComponents([.day], from: pattern.firstObservedAt, to: pattern.lastObservedAt).day ?? 0)
                if d > calSpan + 1 {
                    dprint("⚠️ Temporal invariant violated: distinctActiveDays(\(d)) > span(\(calSpan))+1 for \(pattern.accessoryName) [\(pattern.dayType?.rawValue ?? "all")]")
                }
            }
            #endif
            patterns.append(pattern)
            } // end for group in bands
        }
        return patterns
    }

    // MARK: - Sequential Pattern Detection

    private static func detectSequentialPatterns(
        from events: [BehavioralEvent],
        excludingCoupledPairs: Set<String> = []
    ) -> [BehavioralPattern] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 6 else { return [] }

        var causeCounts:         [String: Int]                           = [:]
        var followCounts:        [String: [String: Int]]                = [:]
        var gapSums:             [String: Double]                       = [:]
        var firstExamples:       [String: (BehavioralEvent, BehavioralEvent)] = [:]
        var allEffectTimestamps: [String: [Date]]                       = [:]  // pairKey → all effect timestamps

        for (i, cause) in sorted.enumerated() {
            causeCounts[cause.signature, default: 0] += 1

            // Precompute cluster intersection members once per cause event to avoid
            // re-parsing the groupingKey string in the hot inner loop.
            let causeBurstMembers: Set<String>
            if let gk = cause.groupingKey, gk.hasPrefix("burst_cluster:") {
                let part = String(gk.dropFirst("burst_cluster:".count))
                causeBurstMembers = Set(part.split(separator: "|").map(String.init))
            } else {
                causeBurstMembers = []
            }

            for j in (i + 1)..<sorted.count {
                let effect = sorted[j]
                let gap = effect.timestamp.timeIntervalSince(cause.timestamp)
                guard gap <= sequentialWindowSeconds else { break }
                guard effect.signature != cause.signature else { continue }
                // Never pair an accessory with itself (e.g. "light on → light off" on same device)
                if let cID = cause.accessoryID, let eID = effect.accessoryID, cID == eID { continue }

                // Skip tightly-coupled device pairs that fire together by design, not by habit.
                let couplingKey = "\(cause.accessoryName)\u{00}\(effect.accessoryName)"
                if excludingCoupledPairs.contains(couplingKey) {
                    gate(.coupledPairExcluded)
                    continue
                }

                // Skip auto-referential pairs: the cause is a burst cluster and the effect is
                // either (a) a member of that cluster or (b) another burst cluster that shares
                // members with the cause. These are burst tails, not sequential habits.
                if !causeBurstMembers.isEmpty {
                    if causeBurstMembers.contains(effect.accessoryName) { continue }
                    if let effectGK = effect.groupingKey, effectGK.hasPrefix("burst_cluster:") {
                        let ePart    = String(effectGK.dropFirst("burst_cluster:".count))
                        let effectMs = Set(ePart.split(separator: "|").map(String.init))
                        if !causeBurstMembers.isDisjoint(with: effectMs) { continue }
                    }
                }

                let pairKey = "\(cause.signature)→\(effect.signature)"
                followCounts[cause.signature, default: [:]][effect.signature, default: 0] += 1
                gapSums[pairKey, default: 0] += gap
                if firstExamples[pairKey] == nil {
                    firstExamples[pairKey] = (cause, effect)
                }
                allEffectTimestamps[pairKey, default: []].append(effect.timestamp)
            }
        }

        var patterns: [BehavioralPattern] = []
        for (causeSig, effects) in followCounts {
            let totalCauses = causeCounts[causeSig] ?? 1
            for (effectSig, hitCount) in effects {
                guard hitCount >= minObservations else {
                    gate(.insufficientSequentialHits)
                    continue
                }
                let hitRate = Double(hitCount) / Double(totalCauses)
                guard hitRate >= minSequentialHitRate else {
                    gate(.lowSequentialHitRate, detail: "hitRate=\(Int(hitRate * 100))%")
                    continue
                }

                let pairKey = "\(causeSig)→\(effectSig)"
                let avgGap  = (gapSums[pairKey] ?? 0) / Double(hitCount)
                guard let (exCause, exEffect) = firstExamples[pairKey] else { continue }

                // Compute span and regularity from all observed effect timestamps
                let effectTimes  = (allEffectTimestamps[pairKey] ?? [exEffect.timestamp]).sorted()
                let firstEffectDate = effectTimes.first!
                let lastEffectDate  = effectTimes.last!
                let seqDistinctDays = Set(effectTimes.map { Calendar.current.startOfDay(for: $0) }).count
                let seqDaySpan = max(1, Calendar.current.dateComponents([.day], from: firstEffectDate, to: lastEffectDate).day ?? 0)

                // Hits must span at least 3 distinct calendar days — a burst of 5 triggers in one
                // evening does not constitute a habit.
                guard seqDistinctDays >= 3 else {
                    gate(.insufficientDistinctDays, detail: "days=\(seqDistinctDays)")
                    continue
                }

                let description = sequentialDescription(
                    causeName: exCause.accessoryName,
                    effectName: exEffect.accessoryName,
                    effectAction: exEffect.action,
                    avgGapSeconds: avgGap
                )

                // For burst-caused sequential patterns, use the stable cluster ID as causeSignature
                // so the deduplication key survives across runs even if the burst label changes.
                let patternCauseSig = (exCause.eventTypeRaw == "burst" && exCause.groupingKey != nil)
                    ? exCause.groupingKey!
                    : causeSig

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
                    causeSignature:           patternCauseSig,
                    causeName:                exCause.accessoryName,
                    avgGapSeconds:            avgGap,
                    observations:             hitCount,
                    validations:              hitCount,
                    firstObservedAt:          firstEffectDate,
                    lastObservedAt:           lastEffectDate,
                    stabilityDays:            seqDaySpan,
                    distinctActiveDays:       seqDistinctDays,
                    status:                   .active,
                    dismissedAt:              nil,
                    approvedAt:               nil,
                    naturalLanguageDescription: description
                )
                #if DEBUG
                if seqDistinctDays > seqDaySpan + 1 {
                    dprint("⚠️ Sequential invariant violated: distinctActiveDays(\(seqDistinctDays)) > span(\(seqDaySpan))+1 for \(exCause.accessoryName)→\(exEffect.accessoryName)")
                }
                #endif
                patterns.append(pattern)
            }
        }

        // In-run dedup: if two patterns display identically (same causeName, effectName,
        // effectAction, dayType) keep only the one with the most observations.
        // This eliminates near-duplicates caused by "device on" vs "device off" trigger variants
        // that look the same in the UI because only causeName is shown.
        var deduped: [String: BehavioralPattern] = [:]
        for p in patterns {
            let displayKey = "\(p.causeName ?? "")|\(p.accessoryName)|\(p.action.rawValue)|\(p.dayType?.rawValue ?? "any")"
            if let existing = deduped[displayKey] {
                if p.observations > existing.observations { deduped[displayKey] = p }
            } else {
                deduped[displayKey] = p
            }
        }
        return Array(deduped.values)
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
            // Burst-cluster scene patterns are always derived fresh — never matched against existing.
            // User decisions (approved/dismissed) are applied by BehavioralAnalysisService after
            // detect() returns, using the burstClusterDecisions dictionary keyed by clusterID.
            if new.patternType == .scene,
               let sig = new.causeSignature, sig.hasPrefix("burst_cluster:") {
                result.append(new)
                continue
            }

            if let existingIdx = existing.firstIndex(where: {
                $0.deduplicationKey == new.deduplicationKey &&
                $0.status != .dismissed &&
                $0.status != .approved &&
                // Sequential patterns are not time-of-day bound — skip the minute-of-day check.
                (new.patternType == .sequential || abs($0.avgMinuteOfDay - new.avgMinuteOfDay) < 30)
            }) {
                var updated = existing[existingIdx]
                updatedExistingIDs.insert(updated.id)

                // Refresh statistical fields from the current detection window.
                updated.observations         = new.observations
                updated.validations          = new.validations
                updated.firstObservedAt      = min(updated.firstObservedAt, new.firstObservedAt)
                updated.lastObservedAt       = new.lastObservedAt
                updated.stabilityDays        = new.stabilityDays
                updated.distinctActiveDays   = new.distinctActiveDays
                updated.dayType              = new.dayType
                updated.weekdays             = new.weekdays
                updated.avgMinuteOfDay       = new.avgMinuteOfDay
                updated.timeDeviationMinutes = new.timeDeviationMinutes
                updated.naturalLanguageDescription = new.naturalLanguageDescription

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

    // MARK: - Event Deduplication

    /// Collapses duplicate events: same accessory + same action within 30 seconds → keep first.
    /// Prevents HomeKit delegate double-fires from inflating sequential hit counts.
    private static func deduplicateEvents(_ events: [BehavioralEvent]) -> [BehavioralEvent] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var result: [BehavioralEvent] = []
        var lastSeen: [String: Date] = [:]
        for event in sorted {
            let key = "\(event.accessoryID?.uuidString ?? event.accessoryName):\(event.action.rawValue)"
            if let last = lastSeen[key], event.timestamp.timeIntervalSince(last) < 30 {
                continue  // duplicate within 30s
            }
            lastSeen[key] = event.timestamp
            result.append(event)
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
            ?? String(localized: "behavioral.dayType.daily", defaultValue: "every day")

        switch action {
        case .on:
            return String(format: String(localized: "behavioral.pattern.temporal.on",
                                          defaultValue: "%1$@ turns on %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .off:
            return String(format: String(localized: "behavioral.pattern.temporal.off",
                                          defaultValue: "%1$@ turns off %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .dim:
            return String(format: String(localized: "behavioral.pattern.temporal.dim",
                                          defaultValue: "%1$@ dims %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .activate:
            return String(format: String(localized: "behavioral.pattern.temporal.activate",
                                          defaultValue: "%1$@ activates %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .lock:
            return String(format: String(localized: "behavioral.pattern.temporal.lock",
                                          defaultValue: "%1$@ locks %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .unlock:
            return String(format: String(localized: "behavioral.pattern.temporal.unlock",
                                          defaultValue: "%1$@ unlocks %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .open:
            return String(format: String(localized: "behavioral.pattern.temporal.open",
                                          defaultValue: "%1$@ opens %2$@ at %3$@"),
                          accessoryName, dayLabel, timeStr)
        case .close:
            return String(format: String(localized: "behavioral.pattern.temporal.close",
                                          defaultValue: "%1$@ closes %2$@ at %3$@"),
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
                                          defaultValue: "After %1$@, %2$@ turns on within %3$d min"),
                          causeName, effectName, gapMinutes)
        case .off:
            return String(format: String(localized: "behavioral.pattern.sequential.off",
                                          defaultValue: "After %1$@, %2$@ turns off within %3$d min"),
                          causeName, effectName, gapMinutes)
        case .dim:
            return String(format: String(localized: "behavioral.pattern.sequential.dim",
                                          defaultValue: "After %1$@, %2$@ dims within %3$d min"),
                          causeName, effectName, gapMinutes)
        case .activate:
            return String(format: String(localized: "behavioral.pattern.sequential.activate",
                                          defaultValue: "After %1$@, %2$@ activates within %3$d min"),
                          causeName, effectName, gapMinutes)
        default:
            return String(format: String(localized: "behavioral.pattern.sequential.default",
                                          defaultValue: "When %1$@ is used, %2$@ changes within %3$d min"),
                          causeName, effectName, gapMinutes)
        }
    }
}
