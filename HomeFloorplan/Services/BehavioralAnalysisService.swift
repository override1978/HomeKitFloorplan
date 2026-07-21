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

// MARK: - SuppressedOpportunity

/// Opportunità non proposta perché già coperta da un'automazione HomeKit esistente.
struct SuppressedOpportunity: Identifiable {
    let id = UUID()
    let patternName: String
    let coveredByAutomation: String
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
    /// Total AccessoryEvents absorbed by burst detection in the last run.
    var lastAbsorbedEventCount: Int = 0
    /// Coupled device-pair reports from the last analysis run.

    /// Wired up from HomeFloorplanApp after both services are created.
    /// Called at the end of analyze() to trigger cluster naming without tying to view lifecycle.
    weak var habitNamingService: HabitAnalysisService?

    /// Fotografie delle automazioni HomeKit esistenti, iniettate da HomeFloorplanApp
    /// e rivalutate a ogni analisi: le opportunità già coperte vengono soppresse.
    var existingAutomationsProvider: (@MainActor () -> [ExistingAutomationSnapshot])?

    /// Opportunità soppresse nell'ultima analisi perché già coperte da automazioni
    /// HomeKit esistenti (diagnostica: dimostra che il motore le ha viste).
    private(set) var lastSuppressedDuplicates: [SuppressedOpportunity] = []

    /// Eventi esclusi dall'ultima analisi perché adiacenti a esecuzioni scena
    /// (effetti di scene/SmartLighting, non abitudini umane).
    private(set) var lastSceneDrivenExcludedCount: Int = 0

    /// Esiti della correlazione contestuale dell'ultima analisi (P2, diagnostica).

    // MARK: - Computed

    /// Pending opportunities ready to be shown to the user.
    var pendingOpportunities: [AutomationOpportunity] {
        opportunities
            .filter { opp in
                opp.status == .pending &&
                opp.isStructurallyConvertibleToAutomation &&
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

    /// Dedicated SwiftData context for opportunity CRUD. Lives as long as the service.
    @ObservationIgnored
    private lazy var opportunityContext = ModelContext(modelContainer)

    /// Dedicated SwiftData context for pattern CRUD. Lives as long as the service.
    @ObservationIgnored
    private lazy var patternContext = ModelContext(modelContainer)

    // MARK: - Init

    /// MOTORE RITIRATO (pivot Abitudini, 2026-07): l'analisi statistica non
    /// produceva valore su dati domestici reali ed è sostituita da evidenze
    /// deterministiche (UsageEvidenceBuilder) + interprete LLM
    /// (HabitInterpreterCore/Service). La classe resta come stub inerte finché
    /// i consumer non vengono smontati (fase 2 della rimozione): patterns e
    /// opportunities restano vuoti e l'analisi è un no-op.
    static let engineRetired = true

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if Self.engineRetired {
            // Motore ritirato: `patterns`/`opportunities` restano vuoti in
            // memoria (nessun `loadPersisted()`), quindi ogni consumer vede
            // liste vuote e la UI legacy si nasconde da sola. NON si cancellano
            // i record persistiti: `PersistedBehavioralPattern` e
            // `AutomationOpportunity` sono tipi SINCRONIZZATI via CloudKit —
            // un delete locale propagherebbe agli altri device o entrerebbe in
            // conflitto con installazioni non aggiornate. I record orfani su
            // disco sono inerti (nessuno li legge) e verranno rimossi nella
            // fase 2 con una migrazione dedicata.
            patterns = []
            opportunities = []
        } else {
            loadPersisted()
        }
    }

    // MARK: - Public API

    /// Runs a full behavioral analysis cycle if sufficient time has passed.
    func analyzeIfNeeded() async {
        guard !Self.engineRetired else { return }
        if let last = lastAnalyzed,
           Date().timeIntervalSince(last) < minAnalysisInterval { return }
        await analyze()
    }

    /// Forces a full analysis regardless of interval.
    func analyze() async {
        // Motore statistico ritirato: no-op. Il corpo (rilevamento pattern,
        // opportunity, naming) è stato rimosso col pivot Abitudini.
        guard !Self.engineRetired else { return }
    }

    /// User dismisses an opportunity permanently.
    func dismiss(_ opportunity: AutomationOpportunity) {
        var changedOpportunity: AutomationOpportunity?
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status      = .dismissed
            opportunities[idx].dismissedAt = Date()
            opportunities[idx].modifiedAt  = Date()
            changedOpportunity = opportunities[idx]
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
        if let changedOpportunity {
            upsertHomeInsight(for: changedOpportunity)
        }
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
        var changedOpportunity: AutomationOpportunity?
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status      = .snoozed
            opportunities[idx].snoozedUntil = Date().addingTimeInterval(Double(days) * 24 * 3600)
            opportunities[idx].modifiedAt  = Date()
            changedOpportunity = opportunities[idx]
        }
        persist()
        if let changedOpportunity {
            upsertHomeInsight(for: changedOpportunity)
        }
    }

    /// Marks an opportunity as approved after it has been converted through the unified automation builder.
    func markApproved(_ opportunity: AutomationOpportunity) {
        var changedOpportunity: AutomationOpportunity?
        if let idx = opportunities.firstIndex(where: { $0.id == opportunity.id }) {
            opportunities[idx].status     = .approved
            opportunities[idx].approvedAt = Date()
            opportunities[idx].modifiedAt = Date()
            changedOpportunity = opportunities[idx]
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
        if let changedOpportunity {
            upsertHomeInsight(for: changedOpportunity)
        }
    }

    /// Removes stale dismissed patterns and expired opportunities.
    func cleanupStale() {
        let dismissedCutoff = Date().addingTimeInterval(-60 * 24 * 3600)  // 60 days
        let dormantCutoff   = Date().addingTimeInterval(-90 * 24 * 3600)  // 90 days

        patterns.removeAll {
            ($0.status == .dismissed && ($0.dismissedAt ?? .distantPast) < dismissedCutoff) ||
            ($0.status == .dormant   && $0.lastObservedAt < dormantCutoff)
        }
        let toDelete = opportunities.filter { $0.status == .dismissed || $0.status == .expired }
        toDelete.forEach { opportunityContext.delete($0) }
        opportunities = opportunities.filter { $0.status != .dismissed && $0.status != .expired }
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
            $0.tier.isVisible &&
            $0.status == .active &&
            $0.confidence >= 0.60 &&
            $0.observations >= 3 &&
            isAutomationConvertible($0) &&
            AutomationSemanticPolicy.allowsPromotion($0)
        }

        // Preserve user decisions (dismissed / approved / snoozed) AND all conversational
        // opportunities — they are user input, never regenerable from the pattern engine.
        let preserved = opportunities.filter {
            $0.status == .dismissed || $0.status == .approved ||
            ($0.status == .snoozed && ($0.snoozedUntil ?? .distantPast) > Date()) ||
            $0.origin != .detected
        }
        let preservedPatternIDs = Set(preserved.map(\.patternID))

        // Anti-duplicazione: pattern già coperti da automazioni HomeKit esistenti
        // non generano opportunità (e quelle pendenti vengono fatte scadere).
        let automationSnapshots = existingAutomationsProvider?() ?? []
        var suppressed: [SuppressedOpportunity] = []
        var suppressedPatternIDs: Set<UUID> = []
        if !automationSnapshots.isEmpty {
            for pattern in qualifying {
                if let coveredBy = existingAutomationName(covering: pattern, snapshots: automationSnapshots) {
                    suppressedPatternIDs.insert(pattern.id)
                    suppressed.append(SuppressedOpportunity(
                        patternName: pattern.accessoryName,
                        coveredByAutomation: coveredBy
                    ))
                }
            }
        }
        lastSuppressedDuplicates = suppressed
        if !suppressed.isEmpty {
            dprint("🧠 BehavioralAnalysis: \(suppressed.count) opportunità soppresse (già coperte da automazioni HomeKit)")
        }

        let activePatternIDs = Set(qualifying.map(\.id)).subtracting(suppressedPatternIDs)

        for pattern in qualifying where !preservedPatternIDs.contains(pattern.id) && !suppressedPatternIDs.contains(pattern.id) {
            if let existing = opportunities.first(where: { $0.patternID == pattern.id && $0.status == .pending }) {
                // Direct mutation — reference semantics on @Model
                existing.confidence    = pattern.confidence
                existing.observations  = pattern.observations
                existing.lastUpdatedAt = Date()
                existing.modifiedAt    = Date()
            } else {
                let newOpp = AutomationOpportunity(from: pattern, profileID: activeProfileID)
                opportunityContext.insert(newOpp)
                opportunities.append(newOpp)
            }
        }

        // Expire opportunities whose pattern has decayed or been dismissed
        for opp in opportunities where opp.status == .pending {
            if !activePatternIDs.contains(opp.patternID) {
                opp.status     = .expired
                opp.modifiedAt = Date()
            }
        }

        // Remove expired from in-memory array (stay in SwiftData as .expired until cleanupStale())
        opportunities = opportunities.filter { $0.status != .expired }
    }

    /// Chiave stabile per preservare le decisioni utente sui pattern contestuali
    /// tra le ri-derivazioni (senza soglia: la decisione sopravvive alla sua deriva).
    private static func contextualDecisionKey(for pattern: BehavioralPattern) -> String {
        let sensorType = pattern.causeSignature
            .flatMap(ContextualCondition.parse(fromSignature:))?.sensorTypeRaw ?? "?"
        return "ctx:\(pattern.accessoryName)|\(pattern.action.rawValue)|\(pattern.roomName)|\(sensorType)"
    }

    /// Nome dell'automazione HomeKit esistente che copre già il pattern, nil se nessuna.
    private func existingAutomationName(
        covering pattern: BehavioralPattern,
        snapshots: [ExistingAutomationSnapshot]
    ) -> String? {
        switch pattern.patternType {
        case .temporal, .lighting:
            guard let accessoryID = pattern.accessoryID else { return nil }
            return AutomationDuplicateChecker.automationCovering(
                accessoryID: accessoryID,
                avgMinuteOfDay: pattern.avgMinuteOfDay,
                in: snapshots
            )
        case .scene:
            guard let sceneName = pattern.causeName else { return nil }
            return AutomationDuplicateChecker.automationTriggering(sceneName: sceneName, in: snapshots)
        case .sequential:
            // L'effetto è già coperto da un'automazione esistente (event-trigger o timer
            // vicino) → la sequenza osservata è probabilmente l'eco di quell'automazione.
            guard let accessoryID = pattern.accessoryID else { return nil }
            return AutomationDuplicateChecker.automationCovering(
                accessoryID: accessoryID,
                avgMinuteOfDay: pattern.avgMinuteOfDay,
                in: snapshots
            )

        case .contextual:
            guard let accessoryID = pattern.accessoryID else { return nil }
            return AutomationDuplicateChecker.automationCovering(
                accessoryID: accessoryID,
                avgMinuteOfDay: pattern.avgMinuteOfDay,
                in: snapshots
            )
        }
    }

    private func isAutomationConvertible(_ pattern: BehavioralPattern) -> Bool {
        switch pattern.patternType {
        case .temporal, .lighting:
            return pattern.accessoryID != nil && isSupportedAutomationAction(pattern.action)

        case .scene:
            let sceneName = pattern.causeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !sceneName.isEmpty

        case .sequential:
            // P1: convertibile se effetto azionabile e causa risolvibile
            // (un singolo accessorio con azione on/off/dim — i cluster burst no).
            guard pattern.accessoryID != nil,
                  isSupportedAutomationAction(pattern.action),
                  let causeName = pattern.causeName,
                  !causeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let signature = pattern.causeSignature,
                  !signature.hasPrefix("burst_cluster:"),
                  AutomationProposalMapper.causeTriggerState(fromSignature: signature) != nil else {
                return false
            }
            return true

        case .contextual:
            // P2: convertibile se OGNI condizione è parsabile, HomeKit-backed
            // (i tipi WeatherKit non hanno characteristic → niente CTA su un wizard
            // che fallirebbe sempre) e l'effetto azionabile.
            guard pattern.accessoryID != nil,
                  isSupportedAutomationAction(pattern.action),
                  let signature = pattern.causeSignature,
                  let conditions = ContextualCondition.parseConditions(fromSignature: signature),
                  !conditions.isEmpty,
                  conditions.allSatisfy(\.isHomeKitBacked) else {
                return false
            }
            return true
        }
    }

    private func isSupportedAutomationAction(_ action: BehavioralAction) -> Bool {
        switch action {
        case .on, .off, .dim, .activate, .lock, .unlock, .open, .close:
            return true
        }
    }

    // MARK: - Persistence

    private func persist() {
        persistPatternsToSwiftData()
        try? opportunityContext.save()  // flush any pending opportunity mutations
        let decisionsRaw = burstClusterDecisions.mapValues(\.rawValue)
        VersionedStore<[String: String]>(key: decisionsKey, version: 1).save(decisionsRaw)
        if let date = lastAnalyzed {
            UserDefaults.standard.set(date, forKey: "behavioral.lastAnalyzed")
        }
    }

    private func loadPersisted() {
        patterns      = fetchPersistedPatterns()
        opportunities = fetchOpportunitiesFromContext()
        lastAnalyzed  = UserDefaults.standard.object(forKey: "behavioral.lastAnalyzed") as? Date
        let decisionsRaw = VersionedStore<[String: String]>(key: decisionsKey, version: 1).load() ?? [:]
        burstClusterDecisions = decisionsRaw.compactMapValues { BehavioralPatternStatus(rawValue: $0) }
    }

    private func fetchOpportunitiesFromContext() -> [AutomationOpportunity] {
        let pid = activeProfileID
        let descriptor = FetchDescriptor<AutomationOpportunity>()
        let all = (try? opportunityContext.fetch(descriptor)) ?? []
        return all.filter { $0.profileID == pid && $0.status != .expired }
    }

    private func persistPatternsToSwiftData() {
        let existingDict = fetchPersistedPatternsDict()
        let currentIDs   = Set(patterns.map(\.id))

        for (id, persisted) in existingDict where !currentIDs.contains(id) {
            patternContext.delete(persisted)
        }
        for pattern in patterns {
            if let persisted = existingDict[pattern.id] {
                persisted.update(from: pattern)
            } else {
                patternContext.insert(PersistedBehavioralPattern(from: pattern, profileID: activeProfileID))
            }
        }
        try? patternContext.save()
    }

    private func fetchPersistedPatterns() -> [BehavioralPattern] {
        fetchPersistedPatternsAll().map { $0.toBehavioralPattern() }
    }

    private func fetchPersistedPatternsAll() -> [PersistedBehavioralPattern] {
        let pid = activeProfileID
        let descriptor = FetchDescriptor<PersistedBehavioralPattern>()
        let all = (try? patternContext.fetch(descriptor)) ?? []
        return all.filter { $0.profileID == pid }
    }

    private func fetchPersistedPatternsDict() -> [UUID: PersistedBehavioralPattern] {
        Dictionary(uniqueKeysWithValues: fetchPersistedPatternsAll().map { ($0.id, $0) })
    }

    /// Inserts a conversational opportunity into SwiftData and the in-memory array.
    /// Call sites that previously appended directly to `opportunities` must use this instead.
    func addOpportunity(_ opp: AutomationOpportunity) {
        opportunityContext.insert(opp)
        opportunities.append(opp)
        try? opportunityContext.save()
        upsertHomeInsight(for: opp)
    }

    private func upsertHomeInsight(for opportunity: AutomationOpportunity) {
        let insight = HomeInsightMapper.map(opportunity)
        let context = modelContainer.mainContext
        let sourceType = String(describing: AutomationOpportunity.self)
        let sourceID = opportunity.id.uuidString

        let sourceDescriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType && $0.sourceRecordID == sourceID
            }
        )
        if let existing = (try? context.fetch(sourceDescriptor))?.first {
            existing.update(from: insight)
            try? context.save()
            return
        }

        let dedupeKey = insight.dedupeKey
        let dedupeDescriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate { $0.dedupeKey == dedupeKey }
        )
        if let existing = (try? context.fetch(dedupeDescriptor))?.first {
            existing.update(from: insight)
        } else {
            context.insert(PersistedHomeInsight(insight: insight))
        }
        try? context.save()
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
        let eligible: Set<String> = ["light", "blind", "switch", "thermostat", "fan", "airPurifier", "humidifier", "outlet"]
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
