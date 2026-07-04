import Foundation
import SwiftData
import Observation

// MARK: - HomeKnowledgeService

/// Aggregates all learning data produced by the AI subsystem and exposes a
/// user-friendly snapshot for the Home Intelligence Dashboard.
///
/// This is a read-only presentation layer — it never writes to any store.
/// All business logic remains in HabitAnalysisService and ActionEffectivenessTracker.
/// This service only reads and aggregates.
@Observable
@MainActor
final class HomeKnowledgeService {

    // MARK: - Exposed State

    /// Overall learning progress 0–1.
    var learningProgress: Double = 0

    /// Days since the first AccessoryEvent was ever recorded.
    var daysSinceLearningStarted: Int = 0

    /// Total events recorded in the last 30 days (accessory + scene).
    var totalEventsCount: Int = 0

    /// Per-domain maturity, ordered for display.
    var domainMaturities: [DomainMaturity] = []

    /// Natural-language observations derived from HabitPattern descriptions.
    var observations: [String] = []

    /// Total AI suggestion chips executed in the last 30 days.
    var totalExecuted: Int = 0

    /// Count of individual measured actions with effectivenessScore ≥ 0.60.
    var totalHelpful: Int = 0

    /// Raw intent string of the most effective AI intent (for display mapping in view).
    var bestIntentRaw: String? = nil

    /// Descriptions of pending HabitPatterns (opportunities the user has not yet approved).
    var opportunityDescriptions: [String] = []

    /// Per-intent effectiveness scores (last 30 days, only intents with ≥ 1 measurement).
    var effectivenessBreakdown: [IntentEffectiveness] = []

    /// Top room per sensor type based on 7-day averages.
    var environmentalTrends: [RoomTrend] = []

    /// Recent environmental AI insights from the unified home insight store (last 7 days), most recent first.
    var recentInsights: [HomeInsightSummary] = []

    /// Current learning phase derived from houseKnowledgeScore.
    var learningPhase: LearningPhase = .observing

    /// House Knowledge Score 0–100 (internal ranking value — not displayed as primary metric).
    var houseKnowledgeScore: Int = 0

    /// AI trust score 0–100 (internal — not displayed as primary metric).
    var aiTrustScore: Int = 0

    /// Deterministic natural-language summary of what the system has learned (Sprint 25.B).
    var learningNarrative: String = ""

    /// Count of HabitPatterns with confidence ≥ 0.80 and status != dismissed.
    var stableHabitsCount: Int = 0

    /// Count of user-approved habit patterns.
    var acceptedSuggestionsCount: Int = 0

    /// True while an async refresh is running.
    var isLoading: Bool = false

    /// True if there is no recorded data at all (first-launch state).
    var hasAnyData: Bool { totalEventsCount > 0 }

    // MARK: - Private

    private let modelContainer: ModelContainer

    // MARK: - Sendable transfer types

    private struct AccessoryEventLite: Sendable {
        let timestamp: Date
        let eventType: String
    }

    private struct SensorReadingLite: Sendable {
        let serviceTypeRaw: String
        let roomName: String
        let value: Double
    }

    private struct DBSnapshot: Sendable {
        let totalAccessoryCount30: Int
        let totalSceneCount30: Int
        let oldestTimestamp: Date?
        let events14: [AccessoryEventLite]
        let sceneCount14: Int
        let sensorReadings7: [SensorReadingLite]
        let recentInsights: [HomeInsightSummary]
    }

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Refresh

    /// Aggregates all available learning data into the exposed state properties.
    ///
    /// All SwiftData fetches run on a background thread to keep the main actor free.
    func refresh(
        habitPatterns: [HabitPattern],
        tracker: ActionEffectivenessTracker,
        aiIsOperational: Bool
    ) async {
        isLoading = true
        defer { isLoading = false }

        // Pre-extract tracker stats on main actor (ActionEffectivenessTracker is @MainActor).
        let summaryStats = tracker.summaryStats(days: 30)
        let outcomeStats = tracker.outcomeStats(days: 30)

        // Pre-extract HabitPattern values before background work
        // (SwiftData @Model instances must not escape the main actor).
        let patternCount  = habitPatterns.filter { $0.status != .dismissed }.count
        let stableCount   = habitPatterns.filter { $0.status != .dismissed && $0.confidence >= 0.80 }.count
        let acceptedCount = habitPatterns.filter { $0.status == .approved }.count
        let pendingDescs  = habitPatterns.filter { $0.status == .pending }.prefix(4).map(\.patternDescription)
        let topObs        = habitPatterns
            .filter  { $0.status != .dismissed }
            .sorted  { $0.confidence > $1.confidence }
            .prefix(6)
            .map(\.patternDescription)

        let container = modelContainer
        let rawScene  = ActivityEventCategory.sceneExecution.rawValue

        // Move all DB fetches onto a background thread.
        let snapshot = await Task.detached(priority: .userInitiated) { () -> DBSnapshot in
            let ctx = ModelContext(container)
            let now = Date()
            let cutoff30 = now.addingTimeInterval(-30 * 24 * 3600)
            let cutoff14 = now.addingTimeInterval(-14 * 24 * 3600)
            let cutoff7  = now.addingTimeInterval(-7  * 24 * 3600)

            // 30-day accessory events → converted to lite structs immediately
            let desc30 = FetchDescriptor<AccessoryEvent>(
                predicate: #Predicate { $0.timestamp >= cutoff30 }
            )
            let raw30    = (try? ctx.fetch(desc30)) ?? []
            let events30 = raw30.map { AccessoryEventLite(timestamp: $0.timestamp, eventType: $0.eventType) }

            // 30-day scene events
            let sceneDesc = FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { $0.timestamp >= cutoff30 && $0.categoryRaw == rawScene }
            )
            let rawScene30    = (try? ctx.fetch(sceneDesc)) ?? []
            let sceneEvents30 = rawScene30.map(\.timestamp)

            // Oldest event — single row with ascending sort (avoids full 365-day scan)
            var oldestDesc = FetchDescriptor<AccessoryEvent>(
                sortBy: [SortDescriptor(\.timestamp)]
            )
            oldestDesc.fetchLimit = 1
            let oldestTimestamp = (try? ctx.fetch(oldestDesc))?.first?.timestamp

            // 14-day slices derived from the 30-day arrays (no extra DB query)
            let events14   = events30.filter    { $0.timestamp >= cutoff14 }
            let sceneCount14 = sceneEvents30.filter { $0 >= cutoff14 }.count

            // 7-day sensor readings
            let sensorDesc = FetchDescriptor<SensorReading>(
                predicate: #Predicate { $0.timestamp >= cutoff7 }
            )
            let rawSensor     = (try? ctx.fetch(sensorDesc)) ?? []
            let sensorReadings7 = rawSensor.map {
                SensorReadingLite(serviceTypeRaw: $0.serviceTypeRaw, roomName: $0.roomName, value: $0.value)
            }

            // Recent environmental situations from the unified home insight store.
            let environmentCategory = HomeInsightCategory.environment.rawValue
            let insightDesc = FetchDescriptor<PersistedHomeInsight>(
                predicate: #Predicate { $0.createdAt >= cutoff7 && $0.categoryRaw == environmentCategory },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let rawInsights   = (try? ctx.fetch(insightDesc)) ?? []
            let recentInsights = HomeSituationResolver.resolve(rawInsights.map { $0.toHomeInsight() }).map { situation in
                let insight = situation.primary
                return HomeInsightSummary(
                    id: insight.id,
                    roomName: insight.roomName ?? "",
                    message: insight.message,
                    severityRaw: insight.severity.rawValue,
                    generatedAt: insight.createdAt,
                    statusRaw: insight.status.rawValue
                )
            }

            return DBSnapshot(
                totalAccessoryCount30: events30.count,
                totalSceneCount30:     rawScene30.count,
                oldestTimestamp:       oldestTimestamp,
                events14:              events14,
                sceneCount14:          sceneCount14,
                sensorReadings7:       sensorReadings7,
                recentInsights:        recentInsights
            )
        }.value

        // ── Apply snapshot to @Observable state (back on main actor) ──────────

        totalEventsCount = snapshot.totalAccessoryCount30 + snapshot.totalSceneCount30

        if let oldest = snapshot.oldestTimestamp {
            daysSinceLearningStarted = max(0,
                Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0)
        } else {
            daysSinceLearningStarted = 0
        }

        let daysWithEvents = Set(snapshot.events14.map {
            Calendar.current.startOfDay(for: $0.timestamp)
        }).count

        let daysFactor:     Double = min(1.0, Double(daysWithEvents) / 14.0)
        let patternsFactor: Double = min(1.0, Double(patternCount)   / 5.0)

        // Base score from observable behavior only. Capped at 1.0 regardless of AI key,
        // so users without an API key are never penalised — AI is a product choice, not
        // a quality prerequisite (Sprint 25.B).
        let baseScore = daysFactor * 0.40 + patternsFactor * 0.30
        learningProgress = min(1.0, baseScore / 0.90)

        houseKnowledgeScore      = Int(learningProgress * 100)
        learningPhase            = LearningPhase(score: houseKnowledgeScore)
        stableHabitsCount        = stableCount
        acceptedSuggestionsCount = acceptedCount

        domainMaturities = buildDomains(events14: snapshot.events14, sceneCount14: snapshot.sceneCount14)
        observations     = Array(topObs)

        totalExecuted = summaryStats.map { $0.executed }.reduce(0, +)

        totalHelpful = outcomeStats
            .filter { $0.averageScore >= 0.60 && $0.sampleCount >= 2 }
            .map(\.sampleCount).reduce(0, +)

        bestIntentRaw = outcomeStats
            .filter { $0.sampleCount >= 2 }
            .max(by: { $0.averageScore < $1.averageScore })
            .map(\.intentRaw)

        effectivenessBreakdown = outcomeStats
            .filter { $0.sampleCount >= 3 }   // consistent with ActionEffectivenessTracker minimum
            .map { IntentEffectiveness(intentRaw: $0.intentRaw, averageScore: $0.averageScore, sampleCount: $0.sampleCount) }
            .sorted { $0.averageScore > $1.averageScore }

        let totalSamples = effectivenessBreakdown.map(\.sampleCount).reduce(0, +)
        aiTrustScore = totalSamples > 0
            ? Int(effectivenessBreakdown
                .map { $0.averageScore * Double($0.sampleCount) }
                .reduce(0, +) / Double(totalSamples) * 100)
            : 0

        opportunityDescriptions = Array(pendingDescs)
        environmentalTrends     = buildTrends(readings: snapshot.sensorReadings7)
        recentInsights          = snapshot.recentInsights

        // Sprint 25.B — deterministic narrative
        learningNarrative = buildNarrative(
            phase:                   learningPhase,
            stableHabitsCount:       stableCount,
            totalExecuted:           totalExecuted,
            totalHelpful:            totalHelpful,
            daysSinceLearningStarted: daysSinceLearningStarted
        )
    }

    // MARK: - Domain Building

    private func buildDomains(
        events14: [AccessoryEventLite],
        sceneCount14: Int
    ) -> [DomainMaturity] {
        // Calibrated percentile thresholds (P75 of an active household, 14-day window).
        // Replacing arbitrary flat values with realistic usage-based targets (Sprint 25.D).
        let lightThreshold:   Int = 50   // ~3–4 light/switch events per day
        let motionThreshold:  Int = 35   // ~2.5 motion events per day
        let contactThreshold: Int = 30   // ~2 contact/blind events per day
        let sceneThreshold:   Int = 18   // ~1 scene per day
        let totalThreshold:   Int = 100  // aggregate across all domains

        let lightCount   = events14.filter { $0.eventType == "light" || $0.eventType == "switch" }.count
        let motionCount  = events14.filter { $0.eventType == "motion"  }.count
        let contactCount = events14.filter { $0.eventType == "contact" }.count
        let blindCount   = events14.filter { $0.eventType == "blind"   }.count
        let totalCount   = events14.count

        // Returns a contextualHint pointing to the next status tier.
        func hint(count: Int, threshold: Int, unit: String) -> String? {
            let progress = Double(count) / Double(threshold)
            let nextTierProgress: Double
            let nextTierLabel: String
            switch progress {
            case 0..<0.10:
                nextTierProgress = 0.10
                nextTierLabel    = DomainStatus.learning.localizedLabel
            case 0.10..<0.40:
                nextTierProgress = 0.40
                nextTierLabel    = DomainStatus.growing.localizedLabel
            case 0.40..<0.75:
                nextTierProgress = 0.75
                nextTierLabel    = DomainStatus.stable.localizedLabel
            default:
                return nil   // already stable
            }
            let needed = max(1, Int(ceil(nextTierProgress * Double(threshold))) - count)
            return String(
                format: String(localized: "domain.hint.format",
                               defaultValue: "%lld more %@ to reach the %@ level."),
                Int64(needed), unit, nextTierLabel
            )
        }

        return [
            DomainMaturity(
                icon:     "thermometer.medium",
                titleKey: "intelligence.domain.environment",
                progress: min(1.0, Double(totalCount) / Double(totalThreshold)),
                contextualHint: hint(count: totalCount, threshold: totalThreshold,
                                     unit: String(localized: "domain.hint.unit.events", defaultValue: "readings"))
            ),
            DomainMaturity(
                icon:     "lightbulb.fill",
                titleKey: "intelligence.domain.lighting",
                progress: min(1.0, Double(lightCount) / Double(lightThreshold)),
                contextualHint: hint(count: lightCount, threshold: lightThreshold,
                                     unit: String(localized: "domain.hint.unit.lightEvents", defaultValue: "light events"))
            ),
            DomainMaturity(
                icon:     "figure.walk",
                titleKey: "intelligence.domain.presence",
                progress: min(1.0, Double(motionCount) / Double(motionThreshold)),
                contextualHint: hint(count: motionCount, threshold: motionThreshold,
                                     unit: String(localized: "domain.hint.unit.motionEvents", defaultValue: "presence readings"))
            ),
            DomainMaturity(
                icon:     "wand.and.sparkles",
                titleKey: "intelligence.domain.scenes",
                progress: min(1.0, Double(sceneCount14) / Double(sceneThreshold)),
                contextualHint: hint(count: sceneCount14, threshold: sceneThreshold,
                                     unit: String(localized: "domain.hint.unit.scenes", defaultValue: "scene activations"))
            ),
            DomainMaturity(
                icon:     "shield.lefthalf.filled",
                titleKey: "intelligence.domain.security",
                progress: min(1.0, Double(contactCount + blindCount) / Double(contactThreshold)),
                contextualHint: hint(count: contactCount + blindCount, threshold: contactThreshold,
                                     unit: String(localized: "domain.hint.unit.securityEvents", defaultValue: "security events"))
            ),
        ]
    }

    // MARK: - Narrative Building (Sprint 25.B)

    private func buildNarrative(
        phase:                    LearningPhase,
        stableHabitsCount:        Int,
        totalExecuted:            Int,
        totalHelpful:             Int,
        daysSinceLearningStarted: Int
    ) -> String {
        switch phase {
        case .observing:
            return String(localized: "narrative.observing",
                          defaultValue: "I am collecting the first observations about your home.")
        case .building:
            return String(localized: "narrative.building",
                          defaultValue: "I have started recognizing the first behavioral patterns.")
        case .recognizing:
            if stableHabitsCount > 0 {
                return String(
                    format: String(localized: "narrative.recognizing.habits",
                                   defaultValue: "I have learned %lld stable habit%@ in your home."),
                    Int64(stableHabitsCount),
                    stableHabitsCount == 1 ? "" : "s"
                )
            }
            return String(localized: "narrative.recognizing",
                          defaultValue: "I am recognizing your main habits.")
        case .understanding:
            if totalExecuted > 0 && totalHelpful > 0 {
                return String(
                    format: String(localized: "narrative.understanding.stats",
                                   defaultValue: "You have run %lld AI suggestions. %lld have improved your environment."),
                    Int64(totalExecuted), Int64(totalHelpful)
                )
            }
            return String(localized: "narrative.understanding",
                          defaultValue: "I have a clear view of your home's routines.")
        case .mature:
            return String(
                format: String(localized: "narrative.mature",
                               defaultValue: "I have known your home for %lld days, with %lld stable habit%@ detected."),
                Int64(daysSinceLearningStarted),
                Int64(stableHabitsCount),
                stableHabitsCount == 1 ? "" : "s"
            )
        }
    }

    // MARK: - Trend Building

    private func buildTrends(readings: [SensorReadingLite]) -> [RoomTrend] {
        guard !readings.isEmpty else { return [] }
        let targetTypes = ["temperature", "humidity", "carbonDioxide", "airQuality"]
        var trends: [RoomTrend] = []
        for sensorType in targetTypes {
            let forType = readings.filter { $0.serviceTypeRaw == sensorType }
            guard !forType.isEmpty else { continue }
            let byRoom = Dictionary(grouping: forType, by: \.roomName)
            let roomStats: [(String, Double, Double)] = byRoom.compactMap { roomName, rds in
                let values = rds.map(\.value)
                guard !values.isEmpty else { return nil }
                let avg    = values.reduce(0, +) / Double(values.count)
                let maxVal = values.max() ?? avg
                return (roomName, avg, maxVal)
            }
            guard let worst = roomStats.max(by: { $0.1 < $1.1 }) else { continue }
            trends.append(RoomTrend(sensorTypeRaw: sensorType, roomName: worst.0,
                                    averageValue: worst.1, maxValue: worst.2))
        }
        return trends
    }
}

// MARK: - DomainMaturity

struct DomainMaturity: Identifiable {
    let id             = UUID()
    let icon:           String
    let titleKey:       String
    let progress:       Double
    /// Hint pointing to the next status tier — nil when already stable (Sprint 25.D).
    var contextualHint: String? = nil

    var localizedTitle: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var status: DomainStatus {
        switch progress {
        case 0.75...1.0:  return .stable
        case 0.40..<0.75: return .growing
        case 0.10..<0.40: return .learning
        default:          return .notEnoughData
        }
    }
}

// MARK: - DomainStatus

enum DomainStatus {
    case notEnoughData, learning, growing, stable

    var localizedLabel: String {
        switch self {
        case .notEnoughData:
            return String(localized: "intelligence.domain.status.notEnoughData",
                          defaultValue: "Not Enough Data")
        case .learning:
            return String(localized: "intelligence.domain.status.learning",
                          defaultValue: "Learning")
        case .growing:
            return String(localized: "intelligence.domain.status.growing",
                          defaultValue: "Growing")
        case .stable:
            return String(localized: "intelligence.domain.status.stable",
                          defaultValue: "Stable")
        }
    }
}

// MARK: - IntentEffectiveness

struct IntentEffectiveness: Identifiable {
    let id           = UUID()
    let intentRaw:    String
    let averageScore: Double  // 0.0 – 1.0
    let sampleCount:  Int
}

// MARK: - RoomTrend

struct RoomTrend: Identifiable {
    let id             = UUID()
    let sensorTypeRaw: String
    let roomName:      String
    let averageValue:  Double
    let maxValue:      Double

    var formattedAvg: String {
        switch sensorTypeRaw {
        case "temperature":   return String(format: "%.1f°",    averageValue)
        case "humidity":      return String(format: "%.0f%%",   averageValue)
        case "carbonDioxide": return String(format: "%.0f ppm", averageValue)
        default:              return String(format: "%.1f",     averageValue)
        }
    }
}

// MARK: - LearningPhase

enum LearningPhase {
    case observing, building, recognizing, understanding, mature

    init(score: Int) {
        switch score {
        case 0..<20:  self = .observing
        case 20..<40: self = .building
        case 40..<60: self = .recognizing
        case 60..<80: self = .understanding
        default:      self = .mature
        }
    }

    var phaseNumber: Int {
        switch self {
        case .observing:     return 1
        case .building:      return 2
        case .recognizing:   return 3
        case .understanding: return 4
        case .mature:        return 5
        }
    }

    var icon: String {
        switch self {
        case .observing:     return "eye"
        case .building:      return "gearshape.2"
        case .recognizing:   return "brain"
        case .understanding: return "lightbulb.fill"
        case .mature:        return "sparkles"
        }
    }

    var localizedTitle: String {
        switch self {
        case .observing:     return String(localized: "intelligence.phase.observing",     defaultValue: "Observing")
        case .building:      return String(localized: "intelligence.phase.building",      defaultValue: "Building")
        case .recognizing:   return String(localized: "intelligence.phase.recognizing",   defaultValue: "Recognizing")
        case .understanding: return String(localized: "intelligence.phase.understanding", defaultValue: "Understanding")
        case .mature:        return String(localized: "intelligence.phase.mature",        defaultValue: "Mature")
        }
    }

    var localizedDescription: String {
        switch self {
        case .observing:
            return String(localized: "intelligence.phase.observing.desc",
                          defaultValue: "Collecting the first observations about your home.")
        case .building:
            return String(localized: "intelligence.phase.building.desc",
                          defaultValue: "Identifying the first behavioral patterns.")
        case .recognizing:
            return String(localized: "intelligence.phase.recognizing.desc",
                          defaultValue: "Recognizing your main habits.")
        case .understanding:
            return String(localized: "intelligence.phase.understanding.desc",
                          defaultValue: "I have a clear view of your home's routines.")
        case .mature:
            return String(localized: "intelligence.phase.mature.desc",
                          defaultValue: "I know your home and its routines well.")
        }
    }
}

// MARK: - HomeInsightSummary

/// Lightweight Sendable DTO for displaying unified home insight records in the Intelligence Dashboard.
struct HomeInsightSummary: Identifiable, Sendable {
    let id:          UUID
    let roomName:    String
    let message:     String
    let severityRaw: String
    let generatedAt: Date
    let statusRaw:   String

    var severity: InsightSeverity {
        switch HomeInsightSeverity(rawValue: severityRaw) {
        case .critical, .high:
            return .anomaly
        case .medium:
            return .warning
        case .low, .info, nil:
            return .info
        }
    }
}
