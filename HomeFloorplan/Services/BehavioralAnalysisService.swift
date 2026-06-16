import Foundation
import SwiftData
import Observation

// MARK: - LightingInsight

/// Derived from .lighting BehavioralPatterns — a recurring brightness habit in a specific room.
struct LightingInsight: Identifiable {
    let id: UUID
    let roomName: String
    let accessoryName: String
    let timeSlot: TimeOfDay
    let avgBrightness: Double   // 0.0–1.0
    let observations: Int
    let confidence: Double
    let suggestedIntent: ActionIntent
}

// MARK: - BehavioralAnalysisService

/// Main orchestrator for the Sprint 13 Behavioral AI Engine.
///
/// Responsibilities:
///   1. Load and normalize raw events into BehavioralEvent
///   2. Run PatternDetectionEngine to find recurring behaviors
///   3. Score and tier each pattern via confidence model
///   4. Generate AutomationOpportunity objects for qualifying patterns
///   5. Persist patterns + opportunities in UserDefaults
///
/// This service observes, learns, and suggests — never acts autonomously.
@Observable
@MainActor
final class BehavioralAnalysisService {

    // MARK: - Published State

    /// All detected behavioral patterns (all tiers).
    var patterns: [BehavioralPattern] = []

    /// Automation opportunities generated from stable patterns.
    var opportunities: [AutomationOpportunity] = []

    /// True while an async analysis run is in progress.
    var isAnalyzing: Bool = false

    /// Date of the most recent successful analysis.
    var lastAnalyzed: Date?

    /// Count of habit-eligible AccessoryEvents that were passed to the engine in the last run.
    var lastAnalyzedEventCount: Int = 0
    /// Timestamp of the earliest eligible event in the last run.
    var lastAnalyzedEventEarliestAt: Date?
    /// Timestamp of the latest eligible event in the last run.
    var lastAnalyzedEventLatestAt: Date?

    /// Burst cluster reports from the last analysis run (populated by PatternDetectionEngine).
    var lastBurstReport: [BurstReport] = []
    /// Total AccessoryEvents absorbed by burst detection in the last run.
    var lastAbsorbedEventCount: Int = 0
    /// Coupled device-pair reports from the last analysis run.
    var lastCoupledPairs: [CoupledPairReport] = []

    /// Wired up from HomeFloorplanApp after both services are created.
    /// Called at the end of analyze() to trigger cluster naming without tying to view lifecycle.
    weak var habitNamingService: HabitAnalysisService?

    // MARK: - Computed

    /// Pending opportunities ready to be shown to the user.
    var pendingOpportunities: [AutomationOpportunity] {
        opportunities
            .filter { opp in
                opp.status == .pending &&
                (opp.snoozedUntil == nil || opp.snoozedUntil! <= Date())
            }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Patterns that are stable or high-confidence.
    var stablePatterns: [BehavioralPattern] {
        patterns.filter { $0.tier == .stable || $0.tier == .highConfidence }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Count of patterns actively being learned (shown in HabitsView Tier 2 "Listening" section).
    /// Excludes already-approved/dismissed patterns. Includes burst-cluster temporal patterns
    /// still accumulating confidence (forming or below), so the morning routine appears even
    /// before it reaches the 60% opportunity threshold.
    var visiblePatternCount: Int {
        patterns.filter {
            $0.status == .active &&
            ($0.tier.isVisible ||
             ($0.patternType == .scene &&
              ($0.causeSignature?.hasPrefix("burst_cluster:") ?? false) &&
              $0.observations >= 3))
        }.count
    }

    /// Lighting habits derived from .lighting patterns, sorted by confidence.
    var lightingInsights: [LightingInsight] {
        patterns
            .filter { $0.patternType == .lighting && $0.tier.isVisible }
            .compactMap { pattern in
                guard let brightness = pattern.numericValue else { return nil }
                let slot   = TimeOfDay(hour: pattern.avgMinuteOfDay / 60)
                let intent: ActionIntent = brightness <= 0.45 ? .dimRoom : .brightenRoom
                return LightingInsight(
                    id:            pattern.id,
                    roomName:      pattern.roomName,
                    accessoryName: pattern.accessoryName,
                    timeSlot:      slot,
                    avgBrightness: brightness,
                    observations:  pattern.observations,
                    confidence:    pattern.confidence,
                    suggestedIntent: intent
                )
            }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Profile

    /// UUID of the family profile used to filter behavioral events.
    /// Nil = global (all events, no profile filter).
    var activeProfileID: UUID?

    // MARK: - Private

    private let modelContainer: ModelContainer

    /// Persisted user decisions for burst-cluster scene patterns (keyed by clusterID).
    /// Burst-cluster patterns are derived fresh each run; this dict re-applies approved/dismissed.
    private var burstClusterDecisions: [String: BehavioralPatternStatus] = [:]

    /// Storage key scoped to the active profile (or global if none).
    private var patternKey: String {
        activeProfileID.map { "behavioral.patterns.v1.\($0.uuidString)" }
            ?? "behavioral.patterns.v1"
    }
    private var opportunityKey: String {
        activeProfileID.map { "behavioral.opportunities.v1.\($0.uuidString)" }
            ?? "behavioral.opportunities.v1"
    }
    private var decisionsKey: String {
        activeProfileID.map { "behavioral.clusterDecisions.v1.\($0.uuidString)" }
            ?? "behavioral.clusterDecisions.v1"
    }

    /// The VersionedStore key currently in use for patterns — exposed for diagnostics.
    var currentPatternKey: String { patternKey }
    /// The VersionedStore key currently in use for opportunities — exposed for diagnostics.
    var currentOpportunityKey: String { opportunityKey }

    private let minAnalysisInterval: TimeInterval = 60 * 60  // 1 hour

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        loadPersisted()
    }

    // MARK: - Public API

    /// Runs a full behavioral analysis cycle if sufficient time has passed.
    func analyzeIfNeeded() async {
        if let last = lastAnalyzed,
           Date().timeIntervalSince(last) < minAnalysisInterval { return }
        await analyze()
    }

    /// Forces a full analysis regardless of interval.
    func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer {
            isAnalyzing = false
            lastAnalyzed = Date()
            persist()
            let diskInfo = versionedStoreInfo(key: patternKey)
            dprint("🧠 BehavioralAnalysis: persisted \(patterns.count) patterns → \(diskInfo.stored) bytes [\(patternKey)]")
        }

        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-30 * 24 * 3600)

        let accDescriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let sceneRaw = ActivityEventCategory.sceneExecution.rawValue
        let actDescriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.categoryRaw == sceneRaw }
        )

        let allAccessory = (try? context.fetch(accDescriptor)) ?? []

        // Include events recorded in global mode (profileID == nil) so that history
        // captured before a profile was selected is not silently dropped.
        let rawAccessory: [AccessoryEvent]
        if let pid = activeProfileID {
            rawAccessory = allAccessory.filter { $0.profileID == pid || $0.profileID == nil }
        } else {
            rawAccessory = allAccessory
        }
        let rawActivity  = (try? context.fetch(actDescriptor)) ?? []

        guard !rawAccessory.isEmpty || !rawActivity.isEmpty else { return }

        // Normalize to BehavioralEvent
        let accessoryEvents = rawAccessory.map { BehavioralEventPreprocessor.convert($0) }
        let sceneEvents     = rawActivity.map  { BehavioralEventPreprocessor.convert($0) }

        // Track stats for diagnostics (same eligibility filter as the engine)
        let eligibleSet: Set<String> = ["light", "blind", "switch", "thermostat", "fan", "airPurifier", "outlet"]
        let eligibleForStats = accessoryEvents.filter { eligibleSet.contains($0.eventTypeRaw) }
        lastAnalyzedEventCount      = eligibleForStats.count
        lastAnalyzedEventEarliestAt = eligibleForStats.map(\.timestamp).min()
        lastAnalyzedEventLatestAt   = eligibleForStats.map(\.timestamp).max()

        // Harvest user decisions from existing burst-cluster scene patterns before removing them.
        // Burst-cluster patterns are re-derived fresh each run; only the approved/dismissed decisions
        // are preserved across analyses so a dismissed pattern stays dismissed after re-detection.
        for p in patterns {
            guard p.patternType == .scene,
                  let sig = p.causeSignature, sig.hasPrefix("burst_cluster:"),
                  p.status == .approved || p.status == .dismissed else { continue }
            burstClusterDecisions[sig] = p.status
        }

        // Remove ALL scene-type burst patterns — they are always re-derived fresh.
        // Covers legacy signature formats ("burst:" prefix or nil) so fossils from
        // earlier engine versions can never linger with frozen statistics.
        patterns.removeAll { $0.patternType == .scene }

        // Detect patterns
        let detected = PatternDetectionEngine.detect(
            accessoryEvents: accessoryEvents,
            sceneEvents: sceneEvents,
            existingPatterns: patterns
        )
        patterns = detected

        // Re-apply persisted user decisions to freshly derived burst-cluster patterns.
        for i in patterns.indices {
            guard patterns[i].patternType == .scene,
                  let sig = patterns[i].causeSignature,
                  sig.hasPrefix("burst_cluster:"),
                  let decision = burstClusterDecisions[sig] else { continue }
            patterns[i].status = decision
            if decision == .approved  && patterns[i].approvedAt  == nil { patterns[i].approvedAt  = Date() }
            if decision == .dismissed && patterns[i].dismissedAt == nil { patterns[i].dismissedAt = Date() }
        }

        // Copy diagnostics from the engine
        lastBurstReport        = PatternDetectionEngine.lastBurstReport
        lastAbsorbedEventCount = PatternDetectionEngine.lastAbsorbedEventCount
        lastCoupledPairs       = PatternDetectionEngine.lastCoupledPairs

        // Remove sequential artefacts: active/decaying patterns not re-detected in this run
        // that were recently observed — these are burst fragments from prior analyses.
        // Temporal/scene artefacts are left to decay naturally; sequential ones are the noisy ones.
        let detectedKeys = PatternDetectionEngine.lastDetectedKeys
        patterns.removeAll { p in
            guard p.status == .active || p.status == .decaying else { return false }
            guard p.patternType == .sequential else { return false }
            guard !detectedKeys.contains(p.deduplicationKey) else { return false }
            return -p.lastObservedAt.timeIntervalSinceNow / 86400 < 14
        }

        // Cleanup one-time: remove auto-referential sequential patterns where the cause is a
        // burst cluster and the effect is a member of that same cluster.
        // These are cascade tails artefacts — the burst "caused" a device that was already in it.
        patterns.removeAll { p in
            guard p.patternType == .sequential,
                  p.status != .approved, p.status != .dismissed,
                  let cs = p.causeSignature else { return false }
            if cs.hasPrefix("burst_cluster:") {
                let part    = String(cs.dropFirst("burst_cluster:".count))
                let members = Set(part.split(separator: "|").map(String.init))
                return members.contains(p.accessoryName)
            }
            // Legacy format "burst:label:activate" — heuristic: effectName appears in causeName
            if cs.hasPrefix("burst:") {
                return p.causeName.map { !p.accessoryName.isEmpty && $0.contains(p.accessoryName) } ?? false
            }
            return false
        }

        // Generate opportunities from qualifying patterns
        rebuildOpportunities()

        dprint("🧠 BehavioralAnalysis: \(patterns.count) patterns (\(lastBurstReport.count) burst sigs, \(lastAbsorbedEventCount) events absorbed), \(opportunities.count) opportunities")

        // Trigger cluster naming after each analysis run (AI-01).
        // scheduleNaming spawns its own unstructured Task so naming is never cancelled by a view.
        habitNamingService?.scheduleNaming(reports: lastBurstReport, patterns: patterns)
    }

    /// User dismisses an opportunity permanently.
    func dismiss(_ opportunity: AutomationOpportunity) {
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status      = .dismissed
            opportunities[idx].dismissedAt = Date()
        }
        // Also mark the source pattern as dismissed
        if let pIdx = patterns.firstIndex(where: { $0.id == opportunity.patternID }) {
            patterns[pIdx].status      = .dismissed
            patterns[pIdx].dismissedAt = Date()
            // Persist decision for burst-cluster patterns so it survives the next fresh re-derivation.
            if patterns[pIdx].patternType == .scene,
               let sig = patterns[pIdx].causeSignature, sig.hasPrefix("burst_cluster:") {
                burstClusterDecisions[sig] = .dismissed
            }
        }
        persist()
    }

    /// Dismisses a pattern directly (without an existing opportunity).
    /// Called from the HabitsView "Sto imparando" tier when the user swipes away a learning pattern.
    func dismissPattern(_ pattern: BehavioralPattern) {
        if let idx = patterns.firstIndex(where: { $0.id == pattern.id }) {
            patterns[idx].status      = .dismissed
            patterns[idx].dismissedAt = Date()
            if patterns[idx].patternType == .scene,
               let sig = patterns[idx].causeSignature, sig.hasPrefix("burst_cluster:") {
                burstClusterDecisions[sig] = .dismissed
            }
        }
        persist()
    }

    /// User asks to be reminded about this opportunity later.
    func snooze(_ opportunity: AutomationOpportunity, days: Int = 7) {
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status      = .snoozed
            opportunities[idx].snoozedUntil = Date().addingTimeInterval(Double(days) * 24 * 3600)
        }
        persist()
    }

    /// Adds a conversational opportunity proposed by the chatbot.
    /// Deduplicates only exact matches (same accessory + action + triggerTime) among pending
    /// conversationals. Different trigger times = distinct automations, always allowed.
    func addConversationalOpportunity(_ opp: AutomationOpportunity) {
        let isDuplicate = opportunities.contains {
            $0.origin == .conversational &&
            $0.status == .pending &&
            $0.effectAccessoryIDString == opp.effectAccessoryIDString &&
            $0.effectActionRaw == opp.effectActionRaw &&
            $0.triggerTime == opp.triggerTime
        }
        guard !isDuplicate else { return }
        opportunities.append(opp)
        persist()
    }

    /// User approves — returns a Rule ready to be inserted into RuleEngineService.
    @discardableResult
    func approve(_ opportunity: AutomationOpportunity) -> Rule {
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status     = .approved
            opportunities[idx].approvedAt = Date()
        }
        if let pIdx = patterns.firstIndex(where: { $0.id == opportunity.patternID }) {
            patterns[pIdx].status     = .approved
            patterns[pIdx].approvedAt = Date()
            // Persist decision for burst-cluster patterns so it survives the next fresh re-derivation.
            if patterns[pIdx].patternType == .scene,
               let sig = patterns[pIdx].causeSignature, sig.hasPrefix("burst_cluster:") {
                burstClusterDecisions[sig] = .approved
            }
        }
        persist()
        return opportunity.buildRule()
    }

    /// Removes stale dismissed patterns and expired opportunities.
    func cleanupStale() {
        let dismissedCutoff = Date().addingTimeInterval(-60 * 24 * 3600)  // 60 days
        let dormantCutoff   = Date().addingTimeInterval(-90 * 24 * 3600)  // 90 days

        patterns.removeAll {
            ($0.status == .dismissed && ($0.dismissedAt ?? .distantPast) < dismissedCutoff) ||
            ($0.status == .dormant   && $0.lastObservedAt < dormantCutoff)
        }
        opportunities.removeAll {
            $0.status == .dismissed || $0.status == .expired
        }
        persist()
    }

    // MARK: - Profile Switching

    /// Saves the current profile's data, loads the new profile's persisted data, then re-analyzes.
    func switchProfile(to profileID: UUID?) {
        persist()                    // Save patterns + decisions under the current profile key
        activeProfileID = profileID
        patterns             = []
        opportunities        = []
        burstClusterDecisions = [:]  // Reset; loadPersisted() loads the new profile's decisions
        loadPersisted()              // Load patterns + decisions under the new profile key
    }

    // MARK: - Opportunity Generation

    private func rebuildOpportunities() {
        let qualifying = patterns.filter {
            $0.tier.isVisible && $0.status == .active && $0.confidence >= 0.60 && $0.observations >= 3
        }

        // Preserve user decisions (dismissed / approved / snoozed) AND all conversational
        // opportunities — they are user input, never regenerable from the pattern engine.
        let preserved = opportunities.filter {
            $0.status == .dismissed || $0.status == .approved ||
            ($0.status == .snoozed && ($0.snoozedUntil ?? .distantPast) > Date()) ||
            $0.origin != .detected
        }
        let preservedPatternIDs = Set(preserved.map(\.patternID))

        var fresh: [AutomationOpportunity] = preserved
        for pattern in qualifying where !preservedPatternIDs.contains(pattern.id) {
            if let existing = opportunities.first(where: { $0.patternID == pattern.id && $0.status == .pending }) {
                // Update confidence on existing pending opportunity
                var updated = existing
                updated.confidence    = pattern.confidence
                updated.observations  = pattern.observations
                updated.lastUpdatedAt = Date()
                fresh.append(updated)
            } else {
                fresh.append(AutomationOpportunity(from: pattern))
            }
        }

        // Expire opportunities whose pattern has decayed or been dismissed
        let activePatternIDs = Set(qualifying.map(\.id))
        for i in fresh.indices where fresh[i].status == .pending {
            if !activePatternIDs.contains(fresh[i].patternID) {
                fresh[i].status = .expired
            }
        }

        opportunities = fresh.filter { $0.status != .expired }
    }

    // MARK: - Persistence

    private func makeOpportunityStore() -> VersionedStore<[AutomationOpportunity]> {
        VersionedStore(key: opportunityKey, version: 2, migrate: { _, payload in
            // v1 → v2: origin field added; decodeIfPresent in AutomationOpportunity defaults to .detected
            try? JSONDecoder().decode([AutomationOpportunity].self, from: payload)
        })
    }

    private func persist() {
        VersionedStore<[BehavioralPattern]>(key: patternKey, version: 1).save(patterns)
        makeOpportunityStore().save(opportunities)
        let decisionsRaw = burstClusterDecisions.mapValues(\.rawValue)
        VersionedStore<[String: String]>(key: decisionsKey, version: 1).save(decisionsRaw)
        if let date = lastAnalyzed {
            UserDefaults.standard.set(date, forKey: "behavioral.lastAnalyzed")
        }
    }

    private func loadPersisted() {
        patterns      = VersionedStore<[BehavioralPattern]>(key: patternKey, version: 1).load() ?? []
        opportunities = makeOpportunityStore().load() ?? []
        lastAnalyzed  = UserDefaults.standard.object(forKey: "behavioral.lastAnalyzed") as? Date
        let decisionsRaw = VersionedStore<[String: String]>(key: decisionsKey, version: 1).load() ?? [:]
        burstClusterDecisions = decisionsRaw.compactMapValues { BehavioralPatternStatus(rawValue: $0) }
    }

    // MARK: - Diagnostics

    /// Returns the count of AccessoryEvents recorded in the last N days.
    func rawEventCount(days: Int = 30) -> Int {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        return (try? context.fetch(descriptor))?.count ?? 0
    }

    /// Returns the count of AccessoryEvents that pass the habitEligibleTypes filter in the last N days.
    func eligibleEventCount(days: Int = 30) -> Int {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let eligible: Set<String> = ["light", "blind", "switch", "thermostat", "fan", "airPurifier", "outlet"]
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { eligible.contains($0.eventType) }.count
    }

    /// Timestamp of the oldest AccessoryEvent in the store (all-time).
    func firstEventDate() -> Date? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<AccessoryEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.timestamp
    }

    /// Timestamp of the newest AccessoryEvent in the store (all-time).
    func lastEventDate() -> Date? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<AccessoryEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.timestamp
    }

    /// Number of distinct calendar days in the last N days that have at least one AccessoryEvent.
    func daysWithEvents(days: Int = 30) -> Int {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        let cal = Calendar.current
        return Set(all.map { cal.startOfDay(for: $0.timestamp) }).count
    }
}
