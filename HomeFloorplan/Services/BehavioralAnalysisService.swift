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

    /// Count of visible patterns (forming, stable, high-confidence).
    var visiblePatternCount: Int {
        patterns.filter { $0.tier.isVisible }.count
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

    /// Storage key scoped to the active profile (or global if none).
    private var patternKey: String {
        activeProfileID.map { "behavioral.patterns.v1.\($0.uuidString)" }
            ?? "behavioral.patterns.v1"
    }
    private var opportunityKey: String {
        activeProfileID.map { "behavioral.opportunities.v1.\($0.uuidString)" }
            ?? "behavioral.opportunities.v1"
    }

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
        }

        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-30 * 24 * 3600)

        // Fetch raw events
        let accDescriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let sceneRaw = ActivityEventCategory.sceneExecution.rawValue
        let actDescriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.categoryRaw == sceneRaw }
        )

        let allAccessory = (try? context.fetch(accDescriptor)) ?? []
        // Filter to active profile when set; otherwise use all events (global mode)
        let rawAccessory = activeProfileID != nil
            ? allAccessory.filter { $0.profileID == activeProfileID }
            : allAccessory
        let rawActivity  = (try? context.fetch(actDescriptor)) ?? []

        guard !rawAccessory.isEmpty || !rawActivity.isEmpty else { return }

        // Normalize to BehavioralEvent
        let accessoryEvents = rawAccessory.map { BehavioralEventPreprocessor.convert($0) }
        let sceneEvents     = rawActivity.map  { BehavioralEventPreprocessor.convert($0) }

        // Detect patterns
        let detected = PatternDetectionEngine.detect(
            accessoryEvents: accessoryEvents,
            sceneEvents: sceneEvents,
            existingPatterns: patterns
        )
        patterns = detected

        // Generate opportunities from qualifying patterns
        rebuildOpportunities()

        dprint("🧠 BehavioralAnalysis: \(patterns.count) patterns, \(opportunities.count) opportunities")
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
        persist()                   // Save patterns under the current profile key
        activeProfileID = profileID
        patterns      = []
        opportunities = []
        loadPersisted()             // Load patterns under the new profile key
    }

    // MARK: - Opportunity Generation

    private func rebuildOpportunities() {
        let qualifying = stablePatterns.filter {
            $0.status == .active && $0.confidence >= 0.75 && $0.observations >= 5
        }

        // Preserve user decisions (dismissed / approved / snoozed)
        let preserved = opportunities.filter {
            $0.status == .dismissed || $0.status == .approved ||
            ($0.status == .snoozed && ($0.snoozedUntil ?? .distantPast) > Date())
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

    private func persist() {
        if let data = try? JSONEncoder().encode(patterns) {
            UserDefaults.standard.set(data, forKey: patternKey)
        }
        if let data = try? JSONEncoder().encode(opportunities) {
            UserDefaults.standard.set(data, forKey: opportunityKey)
        }
    }

    private func loadPersisted() {
        if let data    = UserDefaults.standard.data(forKey: patternKey),
           let decoded = try? JSONDecoder().decode([BehavioralPattern].self, from: data) {
            patterns = decoded
        }
        if let data    = UserDefaults.standard.data(forKey: opportunityKey),
           let decoded = try? JSONDecoder().decode([AutomationOpportunity].self, from: data) {
            opportunities = decoded
        }
    }
}
