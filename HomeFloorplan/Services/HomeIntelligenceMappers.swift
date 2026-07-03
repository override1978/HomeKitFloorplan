import Foundation

// MARK: - HomeSignalEvent Mappers

enum HomeSignalEventMapper {
    static func map(_ event: AccessoryEvent) -> HomeSignalEvent {
        HomeSignalEvent(
            id: event.id,
            sourceKind: .homeKit,
            entityKind: .accessory,
            entityID: event.accessoryID.uuidString,
            entityName: event.accessoryName,
            roomID: event.roomID?.uuidString,
            roomName: event.roomName,
            signalType: signalType(forAccessoryEventType: event.eventType),
            value: .bool(event.state),
            timestamp: event.timestamp,
            profileID: event.profileID,
            rawSourceType: String(describing: AccessoryEvent.self),
            rawSourceID: event.id.uuidString
        )
    }

    static func mapBrightness(_ event: AccessoryEvent) -> HomeSignalEvent? {
        guard let brightness = event.brightness else { return nil }
        return HomeSignalEvent(
            id: event.id,
            sourceKind: .homeKit,
            entityKind: .accessory,
            entityID: event.accessoryID.uuidString,
            entityName: event.accessoryName,
            roomID: event.roomID?.uuidString,
            roomName: event.roomName,
            signalType: .brightness,
            value: .double(brightness),
            timestamp: event.timestamp,
            profileID: event.profileID,
            rawSourceType: String(describing: AccessoryEvent.self),
            rawSourceID: event.id.uuidString
        )
    }

    static func map(_ reading: SensorReading) -> HomeSignalEvent {
        let type = reading.serviceType
        return HomeSignalEvent(
            id: reading.id,
            sourceKind: type.isWeatherKitSource ? .weather : .sensor,
            entityKind: .sensor,
            entityID: reading.accessoryUUID,
            entityName: type.displayName,
            roomName: reading.roomName,
            signalType: signalType(forSensorServiceType: type),
            value: .double(reading.value),
            timestamp: reading.timestamp,
            rawSourceType: String(describing: SensorReading.self),
            rawSourceID: reading.id.uuidString
        )
    }

    static func map(_ event: ActivityEvent) -> HomeSignalEvent {
        HomeSignalEvent(
            id: event.id,
            sourceKind: sourceKind(forActivityCategory: event.category),
            entityKind: event.category == .sceneExecution ? .scene : .accessory,
            entityName: event.accessoryName ?? event.title,
            roomName: event.roomName,
            signalType: event.category == .sceneExecution ? .sceneActivation : .userAction,
            value: .string(event.subtitle),
            timestamp: event.timestamp,
            rawSourceType: String(describing: ActivityEvent.self),
            rawSourceID: event.id.uuidString
        )
    }

    static func map(_ event: BehavioralEvent) -> HomeSignalEvent {
        HomeSignalEvent(
            id: event.id,
            sourceKind: sourceKind(forBehavioralSource: event.source),
            entityKind: event.source == .scene ? .scene : .accessory,
            entityID: event.accessoryID?.uuidString,
            entityName: event.accessoryName,
            roomName: event.roomName,
            signalType: signalType(forAccessoryEventType: event.eventTypeRaw),
            value: event.numericValue.map(HomeSignalValue.double) ?? .string(event.action.rawValue),
            timestamp: event.timestamp,
            rawSourceType: String(describing: BehavioralEvent.self),
            rawSourceID: event.id.uuidString
        )
    }

    private static func signalType(forAccessoryEventType raw: String) -> HomeSignalType {
        switch raw {
        case AccessoryEventType.light.rawValue,
             AccessoryEventType.switch.rawValue,
             AccessoryEventType.outlet.rawValue:
            return .power
        case AccessoryEventType.contact.rawValue:
            return .contact
        case AccessoryEventType.motion.rawValue:
            return .motion
        case AccessoryEventType.thermostat.rawValue,
             AccessoryEventType.fan.rawValue,
             AccessoryEventType.airPurifier.rawValue,
             AccessoryEventType.humidifier.rawValue:
            return .active
        case AccessoryEventType.blind.rawValue:
            return .active
        default:
            return .unknown
        }
    }

    private static func signalType(forSensorServiceType type: SensorServiceType) -> HomeSignalType {
        switch type {
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

    private static func sourceKind(forActivityCategory category: ActivityEventCategory) -> HomeSignalSourceKind {
        switch category {
        case .sceneExecution: return .scene
        case .write: return .app
        case .externalChange: return .homeKit
        }
    }

    private static func sourceKind(forBehavioralSource source: BehavioralEventSource) -> HomeSignalSourceKind {
        switch source {
        case .accessory: return .homeKit
        case .scene: return .scene
        case .rule: return .automation
        }
    }
}

// MARK: - HomeBaseline Mappers

enum HomeBaselineMapper {
    static func map(_ summary: DailySensorSummary) -> HomeBaseline {
        HomeBaseline(
            id: summary.id,
            roomName: summary.roomName,
            signalType: signalType(forSensorRawValue: summary.serviceTypeRaw),
            baselineKind: .range,
            windowRaw: "daily",
            mean: summary.average,
            standardDeviation: summary.standardDeviation,
            p90: nil,
            p95: summary.peakValue,
            sampleCount: summary.sampleCount,
            firstSampleAt: summary.date,
            lastSampleAt: summary.peakAt,
            confidence: summary.isOutlierDay ? 0.25 : min(1.0, Double(summary.sampleCount) / 24.0),
            contextKey: dayKey(summary.date)
        )
    }

    static func map(_ summary: AccessoryUsageSummary) -> HomeBaseline {
        HomeBaseline(
            id: summary.id,
            entityID: summary.accessoryID.uuidString,
            entityName: summary.accessoryName,
            roomName: summary.roomName,
            signalType: HomeSignalEventMapperSignalBridge.signalType(forAccessoryEventType: summary.eventType),
            baselineKind: .frequency,
            windowRaw: "weekly",
            mean: Double(summary.onCount),
            standardDeviation: nil,
            p90: nil,
            p95: nil,
            sampleCount: summary.onCount + summary.offCount,
            firstSampleAt: summary.weekStartDate,
            lastSampleAt: Calendar.current.date(byAdding: .day, value: 7, to: summary.weekStartDate),
            confidence: min(1.0, Double(summary.onCount + summary.offCount) / 14.0),
            contextKey: "week|\(summary.weekStartDate.timeIntervalSince1970)"
        )
    }

    static func map(roomName: String, serviceTypeRaw: String, result: BaselineResult) -> HomeBaseline? {
        guard let stats = result.byType[serviceTypeRaw] else { return nil }
        let confidence: Double
        switch result.level {
        case .personal: confidence = 0.85
        case .seasonal: confidence = 0.45
        case .none: confidence = 0
        }
        return HomeBaseline(
            roomName: roomName,
            signalType: signalType(forSensorRawValue: serviceTypeRaw),
            baselineKind: .range,
            windowRaw: "14d",
            mean: stats.avg,
            standardDeviation: stats.stdDev,
            sampleCount: 0,
            confidence: confidence,
            contextKey: result.level.contextKey
        )
    }

    private static func signalType(forSensorRawValue raw: String) -> HomeSignalType {
        guard let type = SensorServiceType(rawValue: raw) else { return .unknown }
        switch type {
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

    private static func dayKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "day|\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }
}

private enum HomeSignalEventMapperSignalBridge {
    static func signalType(forAccessoryEventType raw: String) -> HomeSignalType {
        switch raw {
        case AccessoryEventType.light.rawValue,
             AccessoryEventType.switch.rawValue,
             AccessoryEventType.outlet.rawValue:
            return .power
        case AccessoryEventType.contact.rawValue:
            return .contact
        case AccessoryEventType.motion.rawValue:
            return .motion
        case AccessoryEventType.thermostat.rawValue,
             AccessoryEventType.fan.rawValue,
             AccessoryEventType.airPurifier.rawValue,
             AccessoryEventType.humidifier.rawValue,
             AccessoryEventType.blind.rawValue:
            return .active
        default:
            return .unknown
        }
    }
}

private extension BaselineLevel {
    var contextKey: String {
        switch self {
        case .personal: return "personal"
        case .seasonal: return "seasonal"
        case .none: return "none"
        }
    }
}

// MARK: - HomeInsight Mappers

enum HomeInsightMapper {
    static func map(_ insight: PersistedInsight) -> HomeInsight {
        let severity = HomeInsightSeverity(insightSeverityRaw: insight.severityRaw)
        let kind = HomeInsightKind(intelligenceLevelRaw: insight.intelligenceLevelRaw, severityRaw: insight.severityRaw)
        return HomeInsight(
            id: insight.id,
            kind: kind,
            category: .environment,
            severity: severity,
            status: HomeInsightStatus(persistedInsightStatusRaw: insight.statusRaw),
            title: insight.patternKey ?? insight.roomName,
            message: insight.message,
            whyExplanation: insight.whyExplanation,
            sourceEntityID: insight.sourceAccessoryID,
            sourceEntityName: insight.sourceAccessoryName,
            roomName: insight.roomName,
            createdAt: insight.generatedAt,
            updatedAt: insight.generatedAt,
            startedAt: insight.generatedAt,
            resolvedAt: nil,
            confidence: insight.confidenceScore ?? 0.7,
            dedupeKey: insight.patternKey ?? "persistedInsight|\(insight.roomName)|\(insight.id.uuidString)",
            suggestedActionJSON: insight.nextActionsJSON,
            sourceRecordType: String(describing: PersistedInsight.self),
            sourceRecordID: insight.id.uuidString,
            syncPolicy: .syncFull
        )
    }

    static func map(_ opportunity: AutomationOpportunity) -> HomeInsight {
        return HomeInsight(
            id: opportunity.id,
            kind: .opportunity,
            category: .automation,
            severity: opportunity.confidence >= 0.80 ? .medium : .low,
            status: HomeInsightStatus(opportunityStatus: opportunity.status),
            title: opportunity.title,
            message: opportunity.naturalLanguage,
            whyExplanation: opportunity.scheduleSummary,
            recommendation: opportunity.isStructurallyConvertibleToAutomation ? "Review automation" : "Create manually",
            sourceEntityID: opportunity.effectAccessoryIDString,
            roomName: opportunity.roomName,
            createdAt: opportunity.createdAt,
            updatedAt: opportunity.lastUpdatedAt,
            startedAt: opportunity.firstObservedAt,
            resolvedAt: opportunity.approvedAt ?? opportunity.dismissedAt,
            confidence: opportunity.confidence,
            dedupeKey: "automationOpportunity|\(opportunity.patternID.uuidString)",
            suggestedActionJSON: encodeOpportunityAction(opportunity),
            sourceRecordType: String(describing: AutomationOpportunity.self),
            sourceRecordID: opportunity.id.uuidString,
            syncPolicy: .syncFull
        )
    }

    static func map(_ insight: SecurityInsight) -> HomeInsight {
        HomeInsight(
            id: insight.id,
            kind: .security,
            category: .security,
            severity: HomeInsightSeverity(securityPriority: insight.priority),
            status: .active,
            title: insight.room ?? "Security",
            message: insight.message,
            recommendation: insight.suggestedAction,
            sourceEntityID: insight.accessoryID?.uuidString,
            roomName: insight.room,
            createdAt: insight.timestamp,
            updatedAt: insight.timestamp,
            startedAt: insight.timestamp,
            confidence: 0.9,
            dedupeKey: "security|\(insight.room ?? "home")|\(insight.accessoryID?.uuidString ?? insight.message)",
            sourceRecordType: String(describing: SecurityInsight.self),
            sourceRecordID: insight.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    static func map(_ alert: PredictiveEnvironmentAlert) -> HomeInsight {
        HomeInsight(
            id: alert.id,
            kind: .prediction,
            category: .environment,
            severity: alert.confidence >= 0.80 ? .medium : .low,
            status: .active,
            title: alert.roomName,
            message: alert.message,
            sourceEntityName: alert.sensorTypeRaw,
            roomName: alert.roomName,
            createdAt: alert.generatedAt,
            updatedAt: alert.generatedAt,
            startedAt: alert.generatedAt,
            confidence: alert.confidence,
            dedupeKey: "predictiveEnvironment|\(alert.roomName)|\(alert.sensorTypeRaw)|\(alert.weekday)|\(alert.hourOfDay)",
            sourceRecordType: String(describing: PredictiveEnvironmentAlert.self),
            sourceRecordID: alert.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    static func map(_ signal: PredictiveSignal) -> HomeInsight {
        let typeName = signal.pattern.sensorType?.displayName ?? signal.pattern.sensorTypeRaw
        return HomeInsight(
            id: signal.pattern.id,
            kind: .prediction,
            category: .environment,
            severity: signal.score.urgency >= 0.70 ? .medium : .low,
            status: .active,
            title: String(format:
                String(localized: "notif.predictive.headline",
                       defaultValue: "Expected %@ peak in %@"),
                typeName, signal.pattern.roomName),
            message: String(format:
                String(localized: "notif.predictive.body",
                       defaultValue: "Tends to exceed threshold in ~%d min. Ventilate now to prevent it."),
                signal.expectedInMinutes),
            whyExplanation: String(format:
                String(localized: "notif.predictive.why",
                       defaultValue: "Detected in %.0f%% of %d similar days observed."),
                signal.pattern.exceedanceRate * 100, signal.pattern.sampleCount),
            recommendation: String(localized: "notif.predictive.rec",
                defaultValue: "Open windows or activate ventilation in advance."),
            sourceEntityName: typeName,
            roomName: signal.pattern.roomName,
            updatedAt: signal.pattern.lastUpdatedAt,
            confidence: signal.score.confidence,
            score: HomeInsightScore(signal.score),
            dedupeKey: signal.semanticKey,
            sourceRecordType: String(describing: PredictiveSignal.self),
            sourceRecordID: signal.pattern.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    static func map(_ signal: EnvironmentalSignal) -> HomeInsight {
        HomeInsight(
            kind: .environment,
            category: .environment,
            severity: HomeInsightSeverity(notificationPriority: signal.priority),
            status: .active,
            title: EnvironmentalAlertBuilder.headline(for: signal),
            message: EnvironmentalAlertBuilder.body(for: signal),
            whyExplanation: EnvironmentalAlertBuilder.whyExplanation(for: signal),
            recommendation: EnvironmentalAlertBuilder.recommendation(for: signal),
            sourceEntityName: signal.sensorType.displayName,
            roomName: signal.roomName,
            confidence: signal.score.confidence,
            score: HomeInsightScore(signal.score),
            dedupeKey: signal.semanticKey,
            sourceRecordType: String(describing: EnvironmentalSignal.self),
            syncPolicy: .localOnly
        )
    }

    static func map(_ signal: AnomalySignal) -> HomeInsight {
        HomeInsight(
            kind: .anomaly,
            category: .environment,
            severity: .medium,
            status: .active,
            title: anomalyTitle(for: signal),
            message: signal.description,
            sourceEntityName: signal.sensorType.displayName,
            roomName: signal.roomName,
            confidence: signal.score.confidence,
            score: HomeInsightScore(signal.score),
            dedupeKey: signal.semanticKey,
            sourceRecordType: String(describing: AnomalySignal.self),
            syncPolicy: .localOnly
        )
    }

    static func map(_ signal: MaintenanceSignal) -> HomeInsight {
        HomeInsight(
            kind: .maintenance,
            category: .deviceHealth,
            severity: signal.score.urgency >= 0.60 ? .medium : .low,
            status: .active,
            title: String(format:
                String(localized: "notif.maintenance.headline",
                       defaultValue: "Check %@"),
                signal.accessoryName),
            message: signal.detail,
            whyExplanation: String(localized: "notif.maintenance.why",
                defaultValue: "Anomaly detected by comparing usage history."),
            recommendation: String(localized: "notif.maintenance.rec",
                defaultValue: "Verify that the device is working correctly."),
            sourceEntityID: signal.accessoryID.uuidString,
            sourceEntityName: signal.accessoryName,
            roomName: signal.roomName,
            confidence: signal.score.confidence,
            score: HomeInsightScore(signal.score),
            dedupeKey: signal.semanticKey,
            sourceRecordType: String(describing: MaintenanceSignal.self),
            sourceRecordID: signal.accessoryID.uuidString,
            syncPolicy: .localOnly
        )
    }

    static func map(_ signal: DeviationSignal) -> HomeInsight {
        HomeInsight(
            kind: .anomaly,
            category: .habits,
            severity: signal.consecutiveMisses >= 2 ? .medium : .low,
            status: .active,
            title: BehavioralDeviationDetector.headline(for: signal),
            message: BehavioralDeviationDetector.body(for: signal),
            whyExplanation: BehavioralDeviationDetector.whyExplanation(for: signal),
            sourceEntityID: signal.pattern.accessoryID?.uuidString,
            sourceEntityName: signal.pattern.accessoryName,
            roomName: signal.pattern.roomName,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: signal.expectedAt,
            confidence: signal.pattern.confidence,
            score: HomeInsightScore(BehavioralDeviationDetector.score(for: signal)),
            dedupeKey: "behavioral|\(signal.pattern.accessoryName)|\(signal.pattern.action.rawValue)",
            sourceRecordType: String(describing: DeviationSignal.self),
            sourceRecordID: signal.pattern.id.uuidString,
            syncPolicy: .localOnly
        )
    }

    static func map(_ notification: ProactiveNotification) -> HomeInsight {
        let mappedScore = notification.score.map {
            HomeInsightScore(
                relevance: $0.relevance,
                confidence: $0.confidence,
                urgency: $0.urgency,
                actionability: $0.actionability,
                novelty: $0.novelty
            )
        }
        return HomeInsight(
            id: notification.id,
            kind: HomeInsightKind(notificationCategory: notification.category),
            category: HomeInsightCategory(notificationCategory: notification.category),
            severity: HomeInsightSeverity(notificationPriority: notification.priority),
            status: HomeInsightStatus(notificationStatus: notification.status),
            title: notification.displayHeadline,
            message: notification.displayBody,
            whyExplanation: notification.displayWhyExplanation,
            recommendation: notification.displayRecommendation,
            sourceEntityID: notification.sourceID,
            createdAt: notification.createdAt,
            updatedAt: notification.lastUpdatedAt,
            resolvedAt: notification.resolvedAt,
            confidence: notification.score?.confidence ?? 0.7,
            score: mappedScore,
            dedupeKey: notification.semanticKey,
            sourceRecordType: String(describing: ProactiveNotification.self),
            sourceRecordID: notification.id.uuidString,
            syncPolicy: .syncStatusOnly
        )
    }

    private static func anomalyTitle(for signal: AnomalySignal) -> String {
        switch signal.kind {
        case .oscillating:
            return String(format: "Unstable %@ readings", signal.sensorType.displayName)
        case .stuck:
            return String(format: "%@ sensor may be stuck", signal.sensorType.displayName)
        case .outOfRange:
            return String(format: "Impossible %@ value", signal.sensorType.displayName)
        }
    }

    private static func encodeOpportunityAction(_ opportunity: AutomationOpportunity) -> String? {
        struct Payload: Codable {
            var triggerType: String
            var triggerTime: String?
            var triggerWeekdays: [Int]
            var triggerSensorType: String?
            var triggerThreshold: Double?
            var triggerDirection: String?
            var effectAccessoryID: String?
            var effectAction: String
            var effectValue: Double?
            var effectValue2: Double?
            var effectSceneName: String?
        }
        let payload = Payload(
            triggerType: opportunity.triggerType,
            triggerTime: opportunity.triggerTime,
            triggerWeekdays: opportunity.triggerWeekdays,
            triggerSensorType: opportunity.triggerSensorType,
            triggerThreshold: opportunity.triggerThreshold,
            triggerDirection: opportunity.triggerDirection,
            effectAccessoryID: opportunity.effectAccessoryIDString,
            effectAction: opportunity.effectActionRaw,
            effectValue: opportunity.effectValue,
            effectValue2: opportunity.effectValue2,
            effectSceneName: opportunity.effectSceneName
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension HomeInsightScore {
    init(_ score: IntelligenceScore) {
        self.init(
            relevance: score.relevance,
            confidence: score.confidence,
            urgency: score.urgency,
            actionability: score.actionability,
            novelty: score.novelty
        )
    }
}

private extension HomeInsightKind {
    init(intelligenceLevelRaw: String?, severityRaw: String) {
        if severityRaw == InsightSeverity.anomaly.rawValue {
            self = .anomaly
            return
        }
        switch intelligenceLevelRaw.flatMap(IntelligenceLevel.init(rawValue:)) {
        case .prediction:
            self = .prediction
        case .recommendation:
            self = .recommendation
        case .pattern:
            self = .environment
        case .observation, nil:
            self = .environment
        }
    }

    init(notificationCategory: NotificationCategory) {
        switch notificationCategory {
        case .security:
            self = .security
        case .automationOpportunity:
            self = .opportunity
        case .behavioralAI, .learning:
            self = .habit
        case .maintenance:
            self = .maintenance
        case .deviceHealth:
            self = .deviceHealth
        case .weather:
            self = .prediction
        default:
            self = .environment
        }
    }
}

private extension HomeInsightCategory {
    init(notificationCategory: NotificationCategory) {
        switch notificationCategory {
        case .environment, .comfort, .hvac:
            self = .environment
        case .security:
            self = .security
        case .lighting:
            self = .lighting
        case .presence:
            self = .presence
        case .scenes, .automationOpportunity:
            self = .automation
        case .learning, .behavioralAI, .aiDiscovery:
            self = .habits
        case .maintenance:
            self = .maintenance
        case .deviceHealth:
            self = .deviceHealth
        case .weather:
            self = .weather
        }
    }
}

private extension HomeInsightSeverity {
    init(insightSeverityRaw: String) {
        switch InsightSeverity(rawValue: insightSeverityRaw) {
        case .anomaly:
            self = .high
        case .warning:
            self = .medium
        case .info, nil:
            self = .info
        }
    }

    init(securityPriority: SecurityInsightPriority) {
        switch securityPriority {
        case .critical: self = .critical
        case .warning: self = .high
        case .info: self = .info
        }
    }

    init(notificationPriority: NotificationPriority) {
        switch notificationPriority {
        case .critical: self = .critical
        case .high: self = .high
        case .medium: self = .medium
        case .low: self = .low
        case .info: self = .info
        }
    }
}

private extension HomeInsightStatus {
    init(persistedInsightStatusRaw: String) {
        switch InsightPersistedStatus(rawValue: persistedInsightStatusRaw) {
        case .dismissed:
            self = .dismissed
        case .expired:
            self = .expired
        case .executed:
            self = .executed
        case .active, nil:
            self = .active
        }
    }

    init(opportunityStatus: OpportunityStatus) {
        switch opportunityStatus {
        case .pending:
            self = .active
        case .snoozed:
            self = .snoozed
        case .approved:
            self = .accepted
        case .dismissed:
            self = .dismissed
        case .expired:
            self = .expired
        }
    }

    init(notificationStatus: ProactiveNotificationStatus) {
        switch notificationStatus {
        case .pending, .live, .updated, .acknowledged:
            self = .active
        case .actedOn:
            self = .executed
        case .snoozed:
            self = .snoozed
        case .dismissed, .archived:
            self = .dismissed
        case .resolved:
            self = .resolved
        case .expired:
            self = .expired
        }
    }
}
