import Foundation
import SwiftData
import Observation

// MARK: - Proactive Signal Types

struct WeatherPredictionSignal {
    enum Kind {
        case hot
        case cold
    }

    let kind: Kind
    let semanticKey: String
    let headline: String
    let body: String
    let recommendation: String
    let whyExplanation: String
    let temperatureCelsius: Double
    let forecastDateKey: String
    let score: IntelligenceScore
}

struct LearningMilestoneSignal {
    let pattern: BehavioralPattern
    let semanticKey: String
    let score: IntelligenceScore
}

// MARK: - ProactiveIntelligenceService

/// Main orchestrator for Sprint 15 Proactive Intelligence Engine.
///
/// Responsibilities:
///   1. Detect behavioral deviations from known stable patterns
///   2. Build environmental alerts from recent sensor readings
///   3. Surface automation opportunities with appropriate timing
///   4. Generate learning milestone notifications
///   5. Deduplicate signals using semantic keys
///   6. Persist notifications in SwiftData
///   7. Deliver system notifications via NotificationDeliveryOrchestrator
///   8. Expose live + feed state to the UI layer
@Observable
@MainActor
final class ProactiveIntelligenceService {

    // MARK: - Published State

    /// Notifications currently requiring attention (live + updated), priority-sorted.
    var liveNotifications:  [ProactiveNotification] = []
    /// Full historical feed (all non-expired), date-sorted newest first.
    var feedNotifications:  [ProactiveNotification] = []
    /// True while a cycle is running.
    var isRunning:          Bool = false
    /// Date of last completed cycle.
    var lastCycleAt:        Date?

    var unreadCount: Int {
        liveNotifications.filter { $0.status == .live || $0.status == .updated }.count
    }

    // MARK: - Private

    private let modelContainer:   ModelContainer
    private let minCycleInterval: TimeInterval = 5 * 60   // 5 min minimum between cycles
    private let deliveryThreshold: Double       = 0.25    // minimum composite score to persist

    // Keys for notified pattern IDs (to avoid duplicate learning milestones)
    private let notifiedPatternsKey = "proactive.notifiedPatterns.v1"

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        loadNotifications()
    }

    // MARK: - Public Cycle API

    func runCycleIfNeeded(
        behavioralService:  BehavioralAnalysisService,
        habitService:       HabitAnalysisService,
        occupancyService:   OccupancyPredictionService?   = nil,
        maintenanceService: MaintenancePredictionService? = nil,
        presenceOverride:   PresenceState?                = nil,
        weatherService:     WeatherKitService?            = nil,
        homeKitService:     HomeKitService?               = nil
    ) async {
        if let last = lastCycleAt,
           Date().timeIntervalSince(last) < minCycleInterval { return }
        await runCycle(
            behavioralService:  behavioralService,
            habitService:       habitService,
            occupancyService:   occupancyService,
            maintenanceService: maintenanceService,
            presenceOverride:   presenceOverride,
            weatherService:     weatherService,
            homeKitService:     homeKitService
        )
    }

    func runCycle(
        behavioralService:  BehavioralAnalysisService,
        habitService:       HabitAnalysisService,
        occupancyService:   OccupancyPredictionService?   = nil,
        maintenanceService: MaintenancePredictionService? = nil,
        presenceOverride:   PresenceState?                = nil,
        weatherService:     WeatherKitService?            = nil,
        homeKitService:     HomeKitService?               = nil
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            lastCycleAt = Date()
            loadNotifications()
        }

        let context = ContextResolver.resolve(
            presenceOverride: presenceOverride,
            occupancyIsAway:  occupancyService?.isLikelyAway ?? false
        )

        // 0. Habit analysis — AI-powered, enriched with on-device behavioral patterns.
        //    Passing visiblePatterns lets the AI use pre-validated scaffolding instead of
        //    re-deriving habits from raw events, improving quality and reducing API payload.
        //    analyzeHabits() is throttled internally (max once/hour).
        let visiblePatterns = behavioralService.patterns.filter { $0.tier.isVisible }
        await habitService.analyzeHabits(knownPatterns: visiblePatterns)

        // 1. Behavioral deviations
        if !context.suppressNonCritical {
            let sigs   = await fetchRecentEventSignatures()
            let devs   = BehavioralDeviationDetector.detect(
                patterns:              behavioralService.stablePatterns,
                recentEventSignatures: sigs,
                context:               context
            )
            let deviationInsights = devs.map(HomeInsightMapper.map)
            upsertHomeInsights(deviationInsights)
            autoResolveDeviationInsights(currentSignals: devs)
        }

        // 2. Automation opportunities
        let automationOpportunities = Array(behavioralService.pendingOpportunities.prefix(3))
        let automationInsights = automationOpportunities.map(HomeInsightMapper.map)
        upsertHomeInsights(automationInsights)

        // 3. Learning milestones
        await processLearningMilestones(behavioralService: behavioralService)

        // 4. Predictive environmental alerts (pattern-based, before-the-fact)
        if !context.suppressNonCritical {
            let recurrence = EnvironmentalPatternAnalyzer.loadPatterns()
            let predictive = PredictiveAlertBuilder.build(patterns: recurrence)
            let predictiveInsights = predictive.map(HomeInsightMapper.map)
            upsertHomeInsights(predictiveInsights)
            autoResolvePredictiveInsights(currentSignals: predictive)
        }

        // 5. Sensor anomaly detection (device health)
        let anomalies = await SensorAnomalyDetector.detect(modelContainer: modelContainer)
        let anomalyInsights = anomalies.map(HomeInsightMapper.map)
        upsertHomeInsights(anomalyInsights)
        autoResolveSensorAnomalyInsights(currentSignals: anomalies)

        // 6. Home intelligence anomalies (central baseline domain)
        let homeInsightAnomalies = HomeInsightAnomalyPipeline.detect(
            modelContainer: modelContainer,
            homeKitService: homeKitService
        )
        upsertHomeInsights(homeInsightAnomalies)
        autoResolveHomeInsightAnomalies(currentInsights: homeInsightAnomalies)
        resolveLegacyEnvironmentalInsights()

        // 7. Maintenance prediction (usage pattern anomalies)
        if let maint = maintenanceService {
            let maintenanceSignals = maint.signals
            let maintenanceInsights = maintenanceSignals.map(HomeInsightMapper.map)
            upsertHomeInsights(maintenanceInsights)
            autoResolveMaintenanceInsights(currentSignals: maintenanceSignals)
        }

        // 8. Weather prediction (Sprint 31) — morning-only, next-day extremes
        if !context.suppressNonCritical, let weather = weatherService {
            await processWeatherPrediction(weatherService: weather, context: context)
        }

        // 9. Notification delivery is sourced from the unified home insight store.
        await processActiveHomeInsightNotifications(context: context)
        resolveLegacySignalNotifications()

        // 10. Auto-expire old notifications
        autoExpire()

        // Save any pending changes
        try? modelContainer.mainContext.save()
    }

    // MARK: - User Actions

    func acknowledge(_ notification: ProactiveNotification) {
        guard notification.status.isActionable else { return }
        notification.status        = .acknowledged
        notification.acknowledgedAt = Date()
        notification.lastUpdatedAt = Date()
        save()
        loadNotifications()
    }

    func dismiss(_ notification: ProactiveNotification) {
        notification.status      = .dismissed
        notification.dismissCount += 1
        notification.lastUpdatedAt = Date()
        updatePersistedHomeInsightStatus(for: notification, status: .dismissed)
        // Record miss for behavioral patterns to track repeated dismissals
        if let sourceID = notification.sourceID, let patternID = UUID(uuidString: sourceID),
           notification.category == .behavioralAI {
            BehavioralDeviationDetector.recordMiss(for: patternID)
        }
        save()
        loadNotifications()
    }

    func snooze(_ notification: ProactiveNotification, days: Int = 1) {
        notification.status       = .snoozed
        notification.snoozedUntil = Date().addingTimeInterval(Double(days) * 24 * 3600)
        notification.lastUpdatedAt = Date()
        updatePersistedHomeInsightStatus(for: notification, status: .snoozed)
        save()
        loadNotifications()
    }

    func markActedOn(_ notification: ProactiveNotification) {
        notification.status       = .actedOn
        notification.lastUpdatedAt = Date()
        updatePersistedHomeInsightStatus(for: notification, status: .executed)
        if let sourceID = notification.sourceID, let patternID = UUID(uuidString: sourceID),
           notification.category == .behavioralAI {
            BehavioralDeviationDetector.resetMisses(for: patternID)
        }
        save()
        loadNotifications()
    }

    func resolve(_ notification: ProactiveNotification) {
        notification.status      = .resolved
        notification.resolvedAt  = Date()
        notification.lastUpdatedAt = Date()
        updatePersistedHomeInsightStatus(for: notification, status: .resolved, resolvedAt: notification.resolvedAt)
        save()
        loadNotifications()
    }

    // MARK: - Unified Home Insight Delivery

    private func processHomeInsightAnomaly(_ insight: HomeInsight, context: ContextSnapshot) async {
        let key = "homeInsight|\(insight.dedupeKey)"
        let priority = notificationPriority(for: insight.severity)
        let category = notificationCategory(for: insight)
        let score = intelligenceScore(for: insight)

        guard score.composite >= deliveryThreshold else { return }

        if let existing = findLive(semanticKey: key) {
            let oldPriority = existing.priority
            existing.headline = insight.title
            existing.body = insight.message
            existing.currentValue = currentValueText(for: insight)
            existing.priorityRaw = priority.rawValue
            existing.recommendation = insight.recommendation
            existing.whyExplanation = insight.whyExplanation
            existing.sourceID = insight.sourceRecordID ?? insight.sourceEntityID
            existing.status = .updated
            existing.lastUpdatedAt = Date()
            existing.scoreData = try? JSONEncoder().encode(score)
            if priority > oldPriority,
               shouldDeliverSystemNotification(for: insight, priority: priority),
               checkRateLimit(priority: priority, category: category) {
                await NotificationDeliveryOrchestrator.deliver(existing, context: context)
            }
            return
        }

        guard !findRecentlyDismissed(semanticKey: key, withinHours: 12) else { return }

        let notif = ProactiveNotification(
            category: category,
            priority: priority,
            semanticKey: key,
            headline: insight.title,
            body: insight.message,
            currentValue: currentValueText(for: insight),
            recommendation: insight.recommendation,
            sourceID: insight.sourceRecordID ?? insight.sourceEntityID,
            whyExplanation: insight.whyExplanation,
            score: score
        )
        notif.statusRaw = ProactiveNotificationStatus.live.rawValue
        modelContainer.mainContext.insert(notif)
        if shouldDeliverSystemNotification(for: insight, priority: priority),
           checkRateLimit(priority: priority, category: category) {
            await NotificationDeliveryOrchestrator.deliver(notif, context: context)
        }
    }

    private func currentValueText(for insight: HomeInsight) -> String? {
        let message = insight.message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let reportsRange = message.range(of: " reports ") {
            let valueStart = reportsRange.upperBound
            let valueEnd = message[valueStart...].firstIndex(of: ",") ?? message.endIndex
            let value = message[valueStart..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        if let forRange = message.range(of: " for ") {
            let value = message[..<forRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    private func shouldDeliverSystemNotification(for insight: HomeInsight, priority: NotificationPriority) -> Bool {
        guard priority.sendsSystemNotification else { return false }

        if insight.sourceRecordType == String(describing: HomeSignalEvent.self) {
            let why = insight.whyExplanation ?? ""
            return why.localizedCaseInsensitiveContains("danger threshold")
                || why.localizedCaseInsensitiveContains("critical threshold")
                || why.localizedCaseInsensitiveContains("soglia critica")
        }

        return true
    }

    // MARK: - Sprint 31: Weather Prediction

    /// Surfaces a pre-cool or pre-heat suggestion when tomorrow's forecast is extreme.
    /// Runs only during morning hours (7:00–11:59) to give actionable advance notice.
    /// Semantic key includes tomorrow's date so the suggestion expires naturally.
    private func processWeatherPrediction(weatherService: WeatherKitService, context: ContextSnapshot) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 7 && hour < 12 else { return }

        await weatherService.refreshIfNeeded()
        guard let forecast = weatherService.tomorrowForecast else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let tomorrowDate = fmt.string(from: Date().addingTimeInterval(24 * 3600))

        let signals = weatherPredictionSignals(for: forecast, forecastDateKey: tomorrowDate)
        upsertHomeInsights(signals.map(HomeInsightMapper.map))
        autoResolveWeatherInsights(currentSignals: signals)
    }

    private func weatherPredictionSignals(
        for forecast: TomorrowForecast,
        forecastDateKey: String
    ) -> [WeatherPredictionSignal] {
        if forecast.maxTemperature >= 30 {
            let key = "weather|hot|\(forecastDateKey)"
            let score = IntelligenceScore(
                relevance:     0.85,
                confidence:    0.80,
                urgency:       0.55,
                actionability: 0.75,
                novelty:       0.90
            )
            let tempStr = String(format: "%.0f", forecast.maxTemperature)
            return [
                WeatherPredictionSignal(
                    kind: .hot,
                    semanticKey: key,
                    headline: String(localized: "notif.weather.hot.headline",
                                     defaultValue: "Hot Day Ahead"),
                    body: String(format:
                        String(localized: "notif.weather.hot.body",
                               defaultValue: "Tomorrow's forecast is %1$@°C. Consider pre-cooling main rooms in the morning, before temperatures peak."),
                        tempStr),
                    recommendation: String(localized: "notif.weather.hot.rec",
                        defaultValue: "Turn on the AC now to cool your home before temperatures peak."),
                    whyExplanation: String(format:
                        String(localized: "notif.weather.hot.why",
                               defaultValue: "Forecast of %1$@°C tomorrow. Pre-cooling in the morning is more efficient."),
                        tempStr),
                    temperatureCelsius: forecast.maxTemperature,
                    forecastDateKey: forecastDateKey,
                    score: score
                )
            ]

        } else if forecast.minTemperature <= 2 {
            let key = "weather|cold|\(forecastDateKey)"
            let score = IntelligenceScore(
                relevance:     0.85,
                confidence:    0.80,
                urgency:       0.55,
                actionability: 0.75,
                novelty:       0.90
            )
            let tempStr = String(format: "%.0f", forecast.minTemperature)
            return [
                WeatherPredictionSignal(
                    kind: .cold,
                    semanticKey: key,
                    headline: String(localized: "notif.weather.cold.headline",
                                     defaultValue: "Cold Night Ahead"),
                    body: String(format:
                        String(localized: "notif.weather.cold.body",
                               defaultValue: "Tomorrow night temperatures will drop to %1$@°C. Consider pre-heating your home this evening."),
                        tempStr),
                    recommendation: String(localized: "notif.weather.cold.rec",
                        defaultValue: "Turn on heating tonight to wake up to a warm home."),
                    whyExplanation: String(format:
                        String(localized: "notif.weather.cold.why",
                               defaultValue: "Tomorrow's low is %1$@°C. Pre-heating in the evening is more efficient."),
                        tempStr),
                    temperatureCelsius: forecast.minTemperature,
                    forecastDateKey: forecastDateKey,
                    score: score
                )
            ]
        }
        return []
    }

    private func processLearningMilestones(behavioralService: BehavioralAnalysisService) async {
        var notifiedIDs = notifiedPatternIDsSet()

        let newlyStable = behavioralService.patterns.filter {
            ($0.tier == .stable || $0.tier == .highConfidence) &&
            $0.status == .active &&
            !notifiedIDs.contains($0.id)
        }

        for pattern in newlyStable.prefix(2) {
            let key = "learning|\(pattern.id.uuidString)"

            let score = IntelligenceScore(
                relevance: 0.70, confidence: pattern.confidence,
                urgency: 0.10, actionability: 0.60, novelty: 0.90
            )
            let milestone = LearningMilestoneSignal(pattern: pattern, semanticKey: key, score: score)
            upsertHomeInsights([HomeInsightMapper.map(milestone)])
            notifiedIDs.insert(pattern.id)
        }

        saveNotifiedPatternIDs(notifiedIDs)
    }

    // MARK: - Auto-resolve / Auto-expire

    private func resolveLegacyEnvironmentalInsights() {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.categoryRaw == "environment" &&
                ($0.statusRaw == "live" || $0.statusRaw == "updated" || $0.statusRaw == "acknowledged")
            }
        )
        let live = (try? ctx.fetch(descriptor)) ?? []
        for notif in live
        where !notif.semanticKey.hasPrefix("homeInsight|") {
            notif.status     = .resolved
            notif.resolvedAt = Date()
            notif.lastUpdatedAt = Date()
        }

        let persistedDescriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(persistedDescriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == "EnvironmentalSignal" {
            insight.markResolved()
        }
    }

    private func autoResolveHomeInsightAnomalies(currentInsights: [HomeInsight]) {
        let activeKeys = Set(currentInsights.map { "homeInsight|\($0.dedupeKey)" })
        let activeDedupeKeys = Set(currentInsights.map(\.dedupeKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw == "live" || $0.statusRaw == "updated" || $0.statusRaw == "acknowledged"
            }
        )
        let live = (try? ctx.fetch(descriptor)) ?? []
        for notif in live where notif.semanticKey.hasPrefix("homeInsight|") && !activeKeys.contains(notif.semanticKey) {
            notif.status = .resolved
            notif.resolvedAt = Date()
            notif.lastUpdatedAt = Date()
        }

        let persistedDescriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(persistedDescriptor)) ?? []
        for insight in persisted where isRuntimeAnomalyInsight(insight) && !activeDedupeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolveSensorAnomalyInsights(currentSignals: [AnomalySignal]) {
        let activeKeys = Set(currentSignals.map(\.semanticKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(descriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == String(describing: AnomalySignal.self)
            && !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolveDeviationInsights(currentSignals: [DeviationSignal]) {
        let activeKeys = Set(currentSignals.map { HomeInsightMapper.map($0).dedupeKey })
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(descriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == String(describing: DeviationSignal.self)
            && !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolveMaintenanceInsights(currentSignals: [MaintenanceSignal]) {
        let activeKeys = Set(currentSignals.map(\.semanticKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(descriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == String(describing: MaintenanceSignal.self)
            && !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolveWeatherInsights(currentSignals: [WeatherPredictionSignal]) {
        let activeKeys = Set(currentSignals.map(\.semanticKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(descriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == String(describing: WeatherPredictionSignal.self)
            && !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolvePredictiveInsights(currentSignals: [PredictiveSignal]) {
        let activeKeys = Set(currentSignals.map(\.semanticKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            }
        )
        let persisted = (try? ctx.fetch(descriptor)) ?? []
        for insight in persisted
        where insight.sourceRecordType == String(describing: PredictiveSignal.self)
            && !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoExpire() {
        let ctx = modelContainer.mainContext
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600) // 7 day default TTL for low/info
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw != "dismissed" &&
                $0.statusRaw != "archived"  &&
                $0.statusRaw != "expired"   &&
                $0.lastUpdatedAt < cutoff
            }
        )
        let stale = (try? ctx.fetch(descriptor)) ?? []
        for notif in stale {
            // Higher priority gets longer TTL
            let ttl: TimeInterval
            switch notif.priority {
            case .critical: ttl = 30 * 24 * 3600
            case .high:     ttl = 14 * 24 * 3600
            case .medium:   ttl = 7  * 24 * 3600
            case .low:      ttl = 48 * 3600
            case .info:     ttl = 24 * 3600
            }
            if Date().timeIntervalSince(notif.lastUpdatedAt) > ttl {
                notif.status = .expired
                notif.lastUpdatedAt = Date()
            }
        }
    }

    // MARK: - Load

    func loadNotifications() {
        let ctx = modelContainer.mainContext

        // Live: active notifications sorted by priority desc
        let liveDescriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw == "live" || $0.statusRaw == "updated"
            },
            sortBy: [SortDescriptor(\.priorityRaw, order: .reverse),
                     SortDescriptor(\.lastUpdatedAt, order: .reverse)]
        )
        liveNotifications = ((try? ctx.fetch(liveDescriptor)) ?? []).filter {
            !$0.semanticKey.contains("|lightSensor") && !$0.semanticKey.hasPrefix("occupancy|")
        }

        // Feed: all non-expired, sorted newest first
        let feedDescriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw != "expired"
            },
            sortBy: [SortDescriptor(\.lastUpdatedAt, order: .reverse)]
        )
        feedNotifications = ((try? ctx.fetch(feedDescriptor)) ?? []).filter {
            !$0.semanticKey.contains("|lightSensor") && !$0.semanticKey.hasPrefix("occupancy|")
        }
    }

    // MARK: - Helpers

    private func findLive(semanticKey: String) -> ProactiveNotification? {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.semanticKey == semanticKey &&
                ($0.statusRaw == "live" || $0.statusRaw == "updated" || $0.statusRaw == "acknowledged")
            }
        )
        return try? ctx.fetch(descriptor).first
    }

    /// True if a notification with this key was dismissed or snoozed within the given window.
    /// Used to prevent re-creating energy alerts for always-on devices after the user dismisses them.
    private func findRecentlyDismissed(semanticKey: String, withinHours: Double) -> Bool {
        let ctx    = modelContainer.mainContext
        let cutoff = Date().addingTimeInterval(-withinHours * 3600)
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.semanticKey == semanticKey &&
                ($0.statusRaw == "dismissed" || $0.statusRaw == "snoozed") &&
                $0.lastUpdatedAt >= cutoff
            }
        )
        return (try? ctx.fetch(descriptor).isEmpty) == false
    }

    private func fetchRecentEventSignatures() async -> Set<String> {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-2 * 3600)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var sigs = Set<String>()
        for e in events {
            let action: BehavioralAction
            if let brightness = e.brightness, e.state {
                action = brightness < 0.95 ? .dim : .on
            } else {
                action = e.state ? .on : .off
            }
            sigs.insert("\(e.eventType):\(e.accessoryName):\(action.rawValue)")
        }
        return sigs
    }

    private func save() {
        try? modelContainer.mainContext.save()
    }

    private func upsertHomeInsights(_ insights: [HomeInsight]) {
        let ctx = modelContainer.mainContext
        for insight in insights {
            let dedupeKey = insight.dedupeKey
            let descriptor = FetchDescriptor<PersistedHomeInsight>(
                predicate: #Predicate { $0.dedupeKey == dedupeKey }
            )
            if let existing = (try? ctx.fetch(descriptor))?.first {
                existing.update(from: insight)
            } else {
                ctx.insert(PersistedHomeInsight(insight: insight))
            }
        }
    }

    private func processActiveHomeInsightNotifications(context: ContextSnapshot) async {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == "active"
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let activeInsights = (try? ctx.fetch(descriptor)) ?? []
        let insights = notificationInsights(from: activeInsights.map { $0.toHomeInsight() })
        resolveSuppressedHomeInsightNotifications(allowedInsights: insights)

        for insight in insights {
            guard !context.suppressNonCritical || insight.severity >= .high else { continue }
            await processHomeInsightAnomaly(insight, context: context)
        }
    }

    private func notificationInsights(from insights: [HomeInsight]) -> [HomeInsight] {
        let canonicalEnvironmentKeys = Set(
            insights
                .filter(isCanonicalEnvironmentAnomaly)
                .compactMap(environmentOverlapKey)
        )

        guard !canonicalEnvironmentKeys.isEmpty else { return insights }

        return insights.filter { insight in
            guard isAmbientalAIEnvironmentInsight(insight),
                  let key = environmentOverlapKey(for: insight) else {
                return true
            }
            return !canonicalEnvironmentKeys.contains(key)
        }
    }

    private func resolveSuppressedHomeInsightNotifications(allowedInsights: [HomeInsight]) {
        let allowedKeys = Set(allowedInsights.map { "homeInsight|\($0.dedupeKey)" })
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw == "live" || $0.statusRaw == "updated" || $0.statusRaw == "acknowledged"
            }
        )
        let live = (try? ctx.fetch(descriptor)) ?? []
        let now = Date()

        for notification in live
        where notification.semanticKey.hasPrefix("homeInsight|")
            && !allowedKeys.contains(notification.semanticKey)
            && (notification.categoryRaw == NotificationCategory.environment.rawValue
                || notification.categoryRaw == NotificationCategory.hvac.rawValue) {
            notification.status = .resolved
            notification.resolvedAt = now
            notification.lastUpdatedAt = now
        }
    }

    private func isCanonicalEnvironmentAnomaly(_ insight: HomeInsight) -> Bool {
        insight.category == .environment
            && insight.kind == .anomaly
            && (
                insight.sourceRecordType == String(describing: HomeSignalEvent.self)
                    || insight.sourceRecordType == String(describing: HomeStateInterval.self)
            )
    }

    private func isAmbientalAIEnvironmentInsight(_ insight: HomeInsight) -> Bool {
        insight.category == .environment
            && (
                insight.sourceRecordType == String(describing: AmbientalAIInsight.self)
                    || insight.sourceRecordType == String(describing: PersistedInsight.self)
            )
    }

    private func environmentOverlapKey(for insight: HomeInsight) -> String? {
        guard insight.category == .environment else { return nil }
        let room = normalizedOverlapComponent(insight.roomName ?? "home")
        let text = [
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " ")

        guard let signal = environmentSignalGroup(from: text) else { return nil }
        return "\(room)|\(signal)"
    }

    private func environmentSignalGroup(from text: String) -> String? {
        let value = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if value.contains("co2") || value.contains("co₂") || value.contains("anidride carbonica") || value.contains("carbon dioxide") {
            return "co2"
        }
        if value.contains("airquality") || value.contains("air quality") || value.contains("qualita aria") || value.contains("qualità aria") {
            return "airQuality"
        }
        if value.contains("temperature") || value.contains("temperatura") || value.contains("caldo") || value.contains("heat") || value.contains("solar") {
            return "temperature"
        }
        if value.contains("humidity") || value.contains("umidita") || value.contains("umidità") {
            return "humidity"
        }
        return nil
    }

    private func normalizedOverlapComponent(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveLegacySignalNotifications() {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw == "live" || $0.statusRaw == "updated" || $0.statusRaw == "acknowledged"
            }
        )
        let live = (try? ctx.fetch(descriptor)) ?? []
        let now = Date()
        for notification in live where isLegacySignalNotification(notification) {
            notification.status = .resolved
            notification.resolvedAt = now
            notification.lastUpdatedAt = now
        }
    }

    private func isLegacySignalNotification(_ notification: ProactiveNotification) -> Bool {
        guard !notification.semanticKey.hasPrefix("homeInsight|") else { return false }
        return notification.semanticKey.hasPrefix("environment|")
            || notification.semanticKey.hasPrefix("anomaly|")
            || notification.semanticKey.hasPrefix("predictive|")
            || notification.semanticKey.hasPrefix("deviation|")
            || notification.semanticKey.hasPrefix("maintenance|")
            || notification.semanticKey.hasPrefix("automation|")
            || notification.semanticKey.hasPrefix("opportunity|")
            || notification.semanticKey.hasPrefix("weather|")
            || notification.semanticKey.hasPrefix("learning|")
    }

    private func updatePersistedHomeInsightStatus(
        for notification: ProactiveNotification,
        status: HomeInsightStatus,
        resolvedAt: Date? = nil
    ) {
        let dedupeKey = homeInsightDedupeKey(from: notification.semanticKey) ?? notification.semanticKey
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate { $0.dedupeKey == dedupeKey }
        )
        guard let insight = (try? ctx.fetch(descriptor))?.first else { return }
        insight.statusRaw = status.rawValue
        insight.resolvedAt = resolvedAt
        insight.updatedAt = Date()
    }

    private func homeInsightDedupeKey(from semanticKey: String) -> String? {
        let prefix = "homeInsight|"
        guard semanticKey.hasPrefix(prefix) else { return nil }
        return String(semanticKey.dropFirst(prefix.count))
    }

    private func isRuntimeAnomalyInsight(_ insight: PersistedHomeInsight) -> Bool {
        insight.kindRaw == HomeInsightKind.anomaly.rawValue
            && (
                insight.sourceRecordType == String(describing: HomeSignalEvent.self)
                    || insight.sourceRecordType == String(describing: HomeStateInterval.self)
                    || insight.sourceRecordType == String(describing: AnomalySignal.self)
            )
    }

    // MARK: - Rate Limiting

    private func checkRateLimit(priority: NotificationPriority, category: NotificationCategory) -> Bool {
        guard priority.sendsSystemNotification else { return true }
        let today = todayKey()
        switch priority {
        case .critical:
            let hourKey = "proactive.rate.critical.\(hourKey())"
            let count   = UserDefaults.standard.integer(forKey: hourKey)
            if count >= 1 { return false }
            UserDefaults.standard.set(count + 1, forKey: hourKey)
        case .high:
            let key   = "proactive.rate.high.\(category.rawValue).\(today)"
            let count = UserDefaults.standard.integer(forKey: key)
            if count >= 3 { return false }
            UserDefaults.standard.set(count + 1, forKey: key)
        default:
            let key   = "proactive.rate.medium.\(today)"
            let count = UserDefaults.standard.integer(forKey: key)
            if count >= 5 { return false }
            UserDefaults.standard.set(count + 1, forKey: key)
        }
        return true
    }

    private func todayKey() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private func hourKey() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH"
        return fmt.string(from: Date())
    }

    // MARK: - Notified patterns persistence

    private func notifiedPatternIDsSet() -> Set<UUID> {
        let arr = UserDefaults.standard.stringArray(forKey: notifiedPatternsKey) ?? []
        return Set(arr.compactMap(UUID.init))
    }

    private func saveNotifiedPatternIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(Array(ids).map { $0.uuidString }, forKey: notifiedPatternsKey)
    }

    // MARK: - Home insight anomaly helpers

    private func notificationCategory(for insight: HomeInsight) -> NotificationCategory {
        switch insight.category {
        case .environment:
            let climateText = "\(insight.title) \(insight.message)"
            return containsClimateSignal(climateText) ? .hvac : .environment
        case .security:
            return .security
        case .lighting:
            return .lighting
        case .presence:
            return .presence
        case .maintenance:
            return .maintenance
        case .deviceHealth:
            return .deviceHealth
        case .weather:
            return .weather
        case .automation:
            return .automationOpportunity
        case .habits:
            return .behavioralAI
        case .system:
            return .aiDiscovery
        }
    }

    private func containsClimateSignal(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("heating")
            || value.localizedCaseInsensitiveContains("heat mode")
            || value.localizedCaseInsensitiveContains("requesting heat")
            || value.localizedCaseInsensitiveContains("thermostat")
            || value.localizedCaseInsensitiveContains("thermostatic valve")
            || value.localizedCaseInsensitiveContains("climate")
            || value.localizedCaseInsensitiveContains("clima")
            || value.localizedCaseInsensitiveContains("valvola")
    }

    private func notificationPriority(for severity: HomeInsightSeverity) -> NotificationPriority {
        switch severity {
        case .critical:
            return .critical
        case .high:
            return .high
        case .medium:
            return .medium
        case .low:
            return .low
        case .info:
            return .info
        }
    }

    private func intelligenceScore(for insight: HomeInsight) -> IntelligenceScore {
        if let score = insight.score {
            return IntelligenceScore(
                relevance: score.relevance,
                confidence: score.confidence,
                urgency: score.urgency,
                actionability: score.actionability,
                novelty: score.novelty
            )
        }

        let urgency: Double
        switch insight.severity {
        case .critical: urgency = 1.0
        case .high: urgency = 0.85
        case .medium: urgency = 0.65
        case .low: urgency = 0.35
        case .info: urgency = 0.15
        }

        return IntelligenceScore(
            relevance: insight.confidence,
            confidence: insight.confidence,
            urgency: urgency,
            actionability: insight.recommendation == nil ? 0.55 : 0.75,
            novelty: 0.70
        )
    }

}
