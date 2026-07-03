import Foundation
import SwiftData
import Observation

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
        weatherService:     WeatherKitService?            = nil
    ) async {
        if let last = lastCycleAt,
           Date().timeIntervalSince(last) < minCycleInterval { return }
        await runCycle(
            behavioralService:  behavioralService,
            habitService:       habitService,
            occupancyService:   occupancyService,
            maintenanceService: maintenanceService,
            presenceOverride:   presenceOverride,
            weatherService:     weatherService
        )
    }

    func runCycle(
        behavioralService:  BehavioralAnalysisService,
        habitService:       HabitAnalysisService,
        occupancyService:   OccupancyPredictionService?   = nil,
        maintenanceService: MaintenancePredictionService? = nil,
        presenceOverride:   PresenceState?                = nil,
        weatherService:     WeatherKitService?            = nil
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
            for dev in devs {
                await processDeviation(dev, context: context)
            }
            autoResolveDeviationInsights(currentSignals: devs)
        }

        // 2. Automation opportunities
        let automationOpportunities = Array(behavioralService.pendingOpportunities.prefix(3))
        let automationInsights = automationOpportunities.map(HomeInsightMapper.map)
        upsertHomeInsights(automationInsights)
        for opp in automationOpportunities {
            await processOpportunity(opp, context: context)
        }

        // 3. Environmental alerts
        let envSignals = await EnvironmentalAlertBuilder.build(modelContainer: modelContainer)
        let environmentalInsights = envSignals.map(HomeInsightMapper.map)
        upsertHomeInsights(environmentalInsights)
        for sig in envSignals where sig.score.composite >= deliveryThreshold {
            await processEnvironmental(sig, context: context)
        }

        // 4. Auto-resolve environmental alerts whose condition cleared
        autoResolveEnvironmental(currentSignals: envSignals)

        // 5. Learning milestones
        await processLearningMilestones(behavioralService: behavioralService)

        // 6. Predictive environmental alerts (pattern-based, before-the-fact)
        if !context.suppressNonCritical {
            let recurrence = EnvironmentalPatternAnalyzer.loadPatterns()
            let predictive = PredictiveAlertBuilder.build(patterns: recurrence)
            let predictiveInsights = predictive.map(HomeInsightMapper.map)
            upsertHomeInsights(predictiveInsights)
            for sig in predictive where sig.score.composite >= deliveryThreshold {
                await processPredictiveAlert(sig, context: context)
            }
            autoResolvePredictiveInsights(currentSignals: predictive)
        }

        // 8. Sensor anomaly detection (device health)
        let anomalies = await SensorAnomalyDetector.detect(modelContainer: modelContainer)
        let anomalyInsights = anomalies.map(HomeInsightMapper.map)
        upsertHomeInsights(anomalyInsights)
        for anom in anomalies where anom.score.composite >= deliveryThreshold {
            await processAnomaly(anom, context: context)
        }
        autoResolveSensorAnomalyInsights(currentSignals: anomalies)

        // 8.5. Home intelligence anomalies (central baseline domain)
        let homeInsightAnomalies = HomeInsightAnomalyPipeline.detect(modelContainer: modelContainer)
        upsertHomeInsights(homeInsightAnomalies)
        for insight in homeInsightAnomalies where !context.suppressNonCritical || insight.severity >= .high {
            await processHomeInsightAnomaly(insight, context: context)
        }
        autoResolveHomeInsightAnomalies(currentInsights: homeInsightAnomalies)

        // 9. Maintenance prediction (usage pattern anomalies)
        if let maint = maintenanceService {
            let maintenanceSignals = maint.signals
            let maintenanceInsights = maintenanceSignals.map(HomeInsightMapper.map)
            upsertHomeInsights(maintenanceInsights)
            for sig in maintenanceSignals where sig.score.composite >= deliveryThreshold {
                await processMaintenance(sig, context: context)
            }
            autoResolveMaintenanceInsights(currentSignals: maintenanceSignals)
        }

        // 10. Weather prediction (Sprint 31) — morning-only, next-day extremes
        if !context.suppressNonCritical, let weather = weatherService {
            await processWeatherPrediction(weatherService: weather, context: context)
        }

        // 12. Auto-expire old notifications
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

    // MARK: - Signal Processors

    private func processDeviation(_ signal: DeviationSignal, context: ContextSnapshot) async {
        let key  = "behavioral|\(signal.pattern.accessoryName)|\(signal.pattern.action.rawValue)"
        let score = BehavioralDeviationDetector.score(for: signal)
        guard score.composite >= deliveryThreshold else { return }

        // Priority escalates after consecutive misses
        let priority: NotificationPriority = signal.consecutiveMisses >= 3 ? .medium : .low

        if let existing = findLive(semanticKey: key) {
            existing.body           = BehavioralDeviationDetector.body(for: signal)
            existing.whyExplanation = BehavioralDeviationDetector.whyExplanation(for: signal)
            existing.status         = .updated
            existing.lastUpdatedAt  = Date()
            existing.scoreData      = try? JSONEncoder().encode(score)
        } else {
            let notif = ProactiveNotification(
                category:       .behavioralAI,
                priority:       priority,
                semanticKey:    key,
                headline:       BehavioralDeviationDetector.headline(for: signal),
                body:           BehavioralDeviationDetector.body(for: signal),
                sourceID:       signal.pattern.id.uuidString,
                whyExplanation: BehavioralDeviationDetector.whyExplanation(for: signal),
                score:          score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)
            if checkRateLimit(priority: priority, category: .behavioralAI) {
                await NotificationDeliveryOrchestrator.deliver(notif, context: context)
            }
        }
        BehavioralDeviationDetector.recordMiss(for: signal.pattern.id)
    }

    private func processOpportunity(_ opp: AutomationOpportunity, context: ContextSnapshot) async {
        let key   = "automationOpportunity|\(opp.patternID.uuidString)"
        let score = IntelligenceScore(
            relevance:     min(1.0, opp.confidence * 1.1),
            confidence:    opp.confidence,
            urgency:       0.30,
            actionability: 1.00,
            novelty:       opportunityNovelty(opp)
        )
        guard score.composite >= deliveryThreshold else { return }

        if let existing = findLive(semanticKey: key) {
            existing.body           = opportunityBody(opp)
            existing.whyExplanation = opportunityWhy(opp)
            existing.status         = .updated
            existing.lastUpdatedAt  = Date()
            existing.scoreData      = try? JSONEncoder().encode(score)
        } else {
            let notif = ProactiveNotification(
                category:    .automationOpportunity,
                priority:    opp.confidence >= 0.90 ? .medium : .low,
                semanticKey: key,
                headline:    opportunityHeadline(opp),
                body:        opportunityBody(opp),
                sourceID:    opp.id.uuidString,
                whyExplanation: opportunityWhy(opp),
                score:       score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)
            if opp.confidence >= 0.90 {
                await NotificationDeliveryOrchestrator.deliver(notif, context: context)
            }
        }
    }

    private func processEnvironmental(_ sig: EnvironmentalSignal, context: ContextSnapshot) async {
        let key = sig.semanticKey

        if let existing = findLive(semanticKey: key) {
            // Update without re-sending system notification (unless priority escalated)
            let oldPriority = existing.priority
            existing.currentValue   = EnvironmentalAlertBuilder.formattedCurrentValue(for: sig)
            existing.peakValue      = EnvironmentalAlertBuilder.formattedPeakValue(for: sig)
            existing.trendRaw       = sig.trend.rawValue
            existing.body           = EnvironmentalAlertBuilder.body(for: sig)
            existing.priorityRaw    = sig.priority.rawValue
            existing.recommendation = EnvironmentalAlertBuilder.recommendation(for: sig)
            existing.whyExplanation = EnvironmentalAlertBuilder.whyExplanation(for: sig)
            existing.status         = .updated
            existing.lastUpdatedAt  = Date()
            existing.scoreData      = try? JSONEncoder().encode(sig.score)
            // Re-deliver only on priority escalation
            if sig.priority > oldPriority && sig.priority.sendsSystemNotification {
                await NotificationDeliveryOrchestrator.deliver(existing, context: context)
            }
        } else {
            let notif = ProactiveNotification(
                category:       .environment,
                priority:       sig.priority,
                semanticKey:    key,
                headline:       EnvironmentalAlertBuilder.headline(for: sig),
                body:           EnvironmentalAlertBuilder.body(for: sig),
                contextNote:    sig.contextNote,
                currentValue:   EnvironmentalAlertBuilder.formattedCurrentValue(for: sig),
                peakValue:      EnvironmentalAlertBuilder.formattedPeakValue(for: sig),
                trend:          sig.trend,
                recommendation: EnvironmentalAlertBuilder.recommendation(for: sig),
                whyExplanation: EnvironmentalAlertBuilder.whyExplanation(for: sig),
                score:          sig.score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)
            if checkRateLimit(priority: sig.priority, category: .environment) {
                await NotificationDeliveryOrchestrator.deliver(notif, context: context)
            }
        }
    }

    private func processPredictiveAlert(_ signal: PredictiveSignal, context: ContextSnapshot) async {
        let key = signal.semanticKey
        if let existing = findLive(semanticKey: key) {
            existing.recommendation = String(localized: "notif.predictive.rec",
                defaultValue: "Open windows or activate ventilation in advance.")
            existing.whyExplanation = String(format:
                String(localized: "notif.predictive.why",
                       defaultValue: "Detected in %1$.0f%% of the %2$d similar days observed."),
                signal.pattern.exceedanceRate * 100, signal.pattern.sampleCount)
            return
        }

        let typeName = signal.pattern.sensorType?.displayName ?? signal.pattern.sensorTypeRaw
        let notif = ProactiveNotification(
            category:    .aiDiscovery,
            priority:    .low,
            semanticKey: key,
            headline:    String(format:
                String(localized: "notif.predictive.headline",
                       defaultValue: "Expected %@ peak in %@"),
                typeName, signal.pattern.roomName),
            body:        String(format:
                String(localized: "notif.predictive.body",
                       defaultValue: "Tends to exceed threshold in ~%d min. Ventilate now to prevent it."),
                signal.expectedInMinutes),
            recommendation: String(localized: "notif.predictive.rec",
                defaultValue: "Open windows or activate ventilation in advance."),
            whyExplanation: String(format:
                String(localized: "notif.predictive.why",
                       defaultValue: "Detected in %.0f%% of %d similar days observed."),
                signal.pattern.exceedanceRate * 100, signal.pattern.sampleCount),
            score: signal.score
        )
        notif.statusRaw = ProactiveNotificationStatus.live.rawValue
        modelContainer.mainContext.insert(notif)
        if signal.score.urgency >= 0.70, checkRateLimit(priority: .low, category: .aiDiscovery) {
            await NotificationDeliveryOrchestrator.deliver(notif, context: context)
        }
    }

    private func processAnomaly(_ signal: AnomalySignal, context: ContextSnapshot) async {
        let key = signal.semanticKey
        let detailStr = String(format: "%g", signal.numericDetail)
        if let existing = findLive(semanticKey: key) {
            existing.body         = signal.description
            existing.currentValue = detailStr
            return
        }

        let notif = ProactiveNotification(
            category:     .deviceHealth,
            priority:     .medium,
            semanticKey:  key,
            headline:     String(format:
                String(localized: "notif.anomaly.headline",
                       defaultValue: "Anomalous %@ in %@"),
                signal.sensorType.displayName, signal.roomName),
            body:         signal.description,
            currentValue: detailStr,
            recommendation: String(localized: "notif.anomaly.rec",
                defaultValue: "Check the sensor and verify it is correctly positioned."),
            score: signal.score
        )
        notif.statusRaw = ProactiveNotificationStatus.live.rawValue
        modelContainer.mainContext.insert(notif)
        if checkRateLimit(priority: .medium, category: .deviceHealth) {
            await NotificationDeliveryOrchestrator.deliver(notif, context: context)
        }
    }

    private func processHomeInsightAnomaly(_ insight: HomeInsight, context: ContextSnapshot) async {
        let key = "homeInsight|\(insight.dedupeKey)"
        let priority = notificationPriority(for: insight.severity)
        let category = notificationCategory(for: insight)
        let score = intelligenceScore(for: insight)

        guard priority >= .medium else { return }
        guard score.composite >= deliveryThreshold else { return }

        if let existing = findLive(semanticKey: key) {
            let oldPriority = existing.priority
            existing.headline = insight.title
            existing.body = insight.message
            existing.priorityRaw = priority.rawValue
            existing.recommendation = insight.recommendation
            existing.whyExplanation = insight.whyExplanation
            existing.sourceID = insight.sourceRecordID ?? insight.sourceEntityID
            existing.status = .updated
            existing.lastUpdatedAt = Date()
            existing.scoreData = try? JSONEncoder().encode(score)
            if priority > oldPriority && checkRateLimit(priority: priority, category: category) {
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
            recommendation: insight.recommendation,
            sourceID: insight.sourceRecordID ?? insight.sourceEntityID,
            whyExplanation: insight.whyExplanation,
            score: score
        )
        notif.statusRaw = ProactiveNotificationStatus.live.rawValue
        modelContainer.mainContext.insert(notif)
        if checkRateLimit(priority: priority, category: category) {
            await NotificationDeliveryOrchestrator.deliver(notif, context: context)
        }
    }

    private func processMaintenance(_ signal: MaintenanceSignal, context: ContextSnapshot) async {
        let key = signal.semanticKey
        if let existing = findLive(semanticKey: key) {
            existing.recommendation = String(localized: "notif.maintenance.rec",
                defaultValue: "Verify that the device is working correctly.")
            existing.whyExplanation = String(localized: "notif.maintenance.why",
                defaultValue: "Anomaly detected by comparing usage history.")
            return
        }

        let notif = ProactiveNotification(
            category:    .deviceHealth,
            priority:    .low,
            semanticKey: key,
            headline:    String(format:
                String(localized: "notif.maintenance.headline",
                       defaultValue: "Check %@"), signal.accessoryName),
            body:        signal.detail,
            recommendation: String(localized: "notif.maintenance.rec",
                defaultValue: "Verify that the device is working correctly."),
            whyExplanation: String(localized: "notif.maintenance.why",
                defaultValue: "Anomaly detected by comparing usage history."),
            score: signal.score
        )
        notif.statusRaw = ProactiveNotificationStatus.live.rawValue
        modelContainer.mainContext.insert(notif)
        // Maintenance alerts are low-priority — no system notification needed
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

        if forecast.maxTemperature >= 30 {
            let key = "weather|hot|\(tomorrowDate)"
            guard findLive(semanticKey: key) == nil else { return }

            let score = IntelligenceScore(
                relevance:     0.85,
                confidence:    0.80,
                urgency:       0.55,
                actionability: 0.75,
                novelty:       0.90
            )
            guard score.composite >= deliveryThreshold else { return }

            let tempStr = String(format: "%.0f", forecast.maxTemperature)
            let notif = ProactiveNotification(
                category:    .weather,
                priority:    .low,
                semanticKey: key,
                headline:    String(localized: "notif.weather.hot.headline",
                                   defaultValue: "Hot Day Ahead"),
                body:        String(format:
                    String(localized: "notif.weather.hot.body",
                           defaultValue: "Tomorrow's forecast is %1$@°C. Consider pre-cooling main rooms in the morning, before temperatures peak."),
                    tempStr),
                recommendation: String(localized: "notif.weather.hot.rec",
                    defaultValue: "Turn on the AC now to cool your home before temperatures peak."),
                whyExplanation: String(format:
                    String(localized: "notif.weather.hot.why",
                           defaultValue: "Forecast of %1$@°C tomorrow. Pre-cooling in the morning is more efficient."),
                    tempStr),
                score: score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)

        } else if forecast.minTemperature <= 2 {
            let key = "weather|cold|\(tomorrowDate)"
            guard findLive(semanticKey: key) == nil else { return }

            let score = IntelligenceScore(
                relevance:     0.85,
                confidence:    0.80,
                urgency:       0.55,
                actionability: 0.75,
                novelty:       0.90
            )
            guard score.composite >= deliveryThreshold else { return }

            let tempStr = String(format: "%.0f", forecast.minTemperature)
            let notif = ProactiveNotification(
                category:    .weather,
                priority:    .low,
                semanticKey: key,
                headline:    String(localized: "notif.weather.cold.headline",
                                   defaultValue: "Cold Night Ahead"),
                body:        String(format:
                    String(localized: "notif.weather.cold.body",
                           defaultValue: "Tomorrow night temperatures will drop to %1$@°C. Consider pre-heating your home this evening."),
                    tempStr),
                recommendation: String(localized: "notif.weather.cold.rec",
                    defaultValue: "Turn on heating tonight to wake up to a warm home."),
                whyExplanation: String(format:
                    String(localized: "notif.weather.cold.why",
                           defaultValue: "Tomorrow's low is %1$@°C. Pre-heating in the evening is more efficient."),
                    tempStr),
                score: score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)
        }
    }

    /// Returns the localized weekday name for a Calendar weekday integer (1 = Sunday … 7 = Saturday).
    private func localizedWeekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let idx     = max(0, min(weekday - 1, symbols.count - 1))
        return symbols[idx]
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
            guard findLive(semanticKey: key) == nil else { continue }

            let score = IntelligenceScore(
                relevance: 0.70, confidence: pattern.confidence,
                urgency: 0.10, actionability: 0.60, novelty: 0.90
            )
            let notif = ProactiveNotification(
                category:    .learning,
                priority:    .info,
                semanticKey: key,
                headline:    String(localized: "notif.learning.headline",
                                   defaultValue: "New Behavior Learned"),
                body:        pattern.naturalLanguageDescription,
                sourceID:    pattern.id.uuidString,
                whyExplanation: String(format:
                    String(localized: "notif.learning.why",
                           defaultValue: "Detected in %d sessions with %@ confidence."),
                    pattern.observations, pattern.confidenceLabel),
                score:    score
            )
            notif.statusRaw = ProactiveNotificationStatus.live.rawValue
            modelContainer.mainContext.insert(notif)
            notifiedIDs.insert(pattern.id)
        }

        saveNotifiedPatternIDs(notifiedIDs)
    }

    // MARK: - Auto-resolve / Auto-expire

    private func autoResolveEnvironmental(currentSignals: [EnvironmentalSignal]) {
        let activeKeys = Set(currentSignals.map(\.semanticKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.categoryRaw == "environment" &&
                ($0.statusRaw == "live" || $0.statusRaw == "updated")
            }
        )
        let live = (try? ctx.fetch(descriptor)) ?? []
        for notif in live where !activeKeys.contains(notif.semanticKey) {
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
        where insight.sourceRecordType == String(describing: EnvironmentalSignal.self) &&
            !activeKeys.contains(insight.dedupeKey) {
            insight.markResolved()
        }
    }

    private func autoResolveHomeInsightAnomalies(currentInsights: [HomeInsight]) {
        let activeKeys = Set(currentInsights.map { "homeInsight|\($0.dedupeKey)" })
        let activeDedupeKeys = Set(currentInsights.map(\.dedupeKey))
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.statusRaw == "live" || $0.statusRaw == "updated"
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
            return insight.title.localizedCaseInsensitiveContains("heating") ? .hvac : .environment
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

    // MARK: - Opportunity helpers

    private func opportunityHeadline(_ opp: AutomationOpportunity) -> String {
        String(localized: "notif.opportunity.headline", defaultValue: "Suggested Automation")
    }

    private func opportunityBody(_ opp: AutomationOpportunity) -> String {
        String(format:
            String(localized: "notif.opportunity.body",
                   defaultValue: "%@ · %d observations · %@"),
            opp.naturalLanguage,
            opp.observations,
            opp.confidenceLabel
        )
    }

    private func opportunityWhy(_ opp: AutomationOpportunity) -> String {
        String(format:
            String(localized: "notif.opportunity.why",
                   defaultValue: "You have repeated this action %d times with %@ confidence."),
            opp.observations,
            opp.confidenceLabel
        )
    }

    private func opportunityNovelty(_ opp: AutomationOpportunity) -> Double {
        // Lower novelty for opportunities already in the feed
        let key = "proactive.oppSeen.\(opp.id.uuidString)"
        let seen = UserDefaults.standard.bool(forKey: key)
        if !seen { UserDefaults.standard.set(true, forKey: key) }
        return seen ? 0.20 : 0.90
    }
}
