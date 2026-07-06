import Foundation
import SwiftData

// MARK: - HomeSignalEvent

struct HomeSignalEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var sourceKind: HomeSignalSourceKind
    var entityKind: HomeEntityKind
    var entityID: String?
    var entityName: String
    var roomID: String?
    var roomName: String?
    var signalType: HomeSignalType
    var value: HomeSignalValue
    var timestamp: Date
    var profileID: UUID?
    var rawSourceType: String
    var rawSourceID: String?

    init(
        id: UUID = UUID(),
        sourceKind: HomeSignalSourceKind,
        entityKind: HomeEntityKind,
        entityID: String? = nil,
        entityName: String,
        roomID: String? = nil,
        roomName: String? = nil,
        signalType: HomeSignalType,
        value: HomeSignalValue,
        timestamp: Date = Date(),
        profileID: UUID? = nil,
        rawSourceType: String,
        rawSourceID: String? = nil
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.entityKind = entityKind
        self.entityID = entityID
        self.entityName = entityName
        self.roomID = roomID
        self.roomName = roomName
        self.signalType = signalType
        self.value = value
        self.timestamp = timestamp
        self.profileID = profileID
        self.rawSourceType = rawSourceType
        self.rawSourceID = rawSourceID
    }
}

enum HomeSignalSourceKind: String, Codable, Hashable, CaseIterable {
    case homeKit
    case sensor
    case weather
    case app
    case scene
    case automation
    case ai
    case manual
    case derived
}

enum HomeEntityKind: String, Codable, Hashable, CaseIterable {
    case accessory
    case sensor
    case room
    case home
    case person
    case scene
    case rule
    case system
}

enum HomeSignalType: String, Codable, Hashable, CaseIterable {
    case power
    case active
    case contact
    case motion
    case lock
    case brightness
    case temperature
    case humidity
    case airQuality
    case carbonMonoxide
    case carbonDioxide
    case smoke
    case vocDensity
    case pm25
    case pm10
    case lightLevel
    case battery
    case reachability
    case presence
    case sceneActivation
    case automationExecution
    case userAction
    case unknown
}

enum HomeSignalValue: Codable, Hashable {
    case bool(Bool)
    case double(Double)
    case int(Int)
    case string(String)

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var displayValue: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .double(let value): return String(format: "%.2f", value)
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

// MARK: - HomeStateInterval

struct HomeStateInterval: Identifiable, Codable, Hashable {
    var id: UUID
    var entityID: String?
    var entityName: String
    var roomID: String?
    var roomName: String?
    var signalType: HomeSignalType
    var stateRaw: String
    /// Ruolo del dispositivo ("light" | "outlet") noto strutturalmente
    /// dall'eventType o dall'AccessoryCategorizer. Nil = ricadi sui token del nome.
    var deviceRoleRaw: String?
    var startedAt: Date
    var endedAt: Date?
    var sourceEventIDs: [UUID]
    var confidence: Double

    var isActive: Bool { endedAt == nil }

    var durationSeconds: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    init(
        id: UUID = UUID(),
        entityID: String? = nil,
        entityName: String,
        roomID: String? = nil,
        roomName: String? = nil,
        signalType: HomeSignalType,
        stateRaw: String,
        deviceRoleRaw: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        sourceEventIDs: [UUID] = [],
        confidence: Double = 1.0
    ) {
        self.id = id
        self.entityID = entityID
        self.entityName = entityName
        self.roomID = roomID
        self.roomName = roomName
        self.signalType = signalType
        self.stateRaw = stateRaw
        self.deviceRoleRaw = deviceRoleRaw
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceEventIDs = sourceEventIDs
        self.confidence = confidence
    }
}

// MARK: - HomeBaseline

struct HomeBaseline: Identifiable, Codable, Hashable {
    var id: UUID
    var entityID: String?
    var entityName: String?
    var roomName: String?
    var signalType: HomeSignalType
    var baselineKind: HomeBaselineKind
    var windowRaw: String
    var mean: Double?
    var standardDeviation: Double?
    var p90: Double?
    var p95: Double?
    var sampleCount: Int
    var firstSampleAt: Date?
    var lastSampleAt: Date?
    var confidence: Double
    var contextKey: String?

    init(
        id: UUID = UUID(),
        entityID: String? = nil,
        entityName: String? = nil,
        roomName: String? = nil,
        signalType: HomeSignalType,
        baselineKind: HomeBaselineKind,
        windowRaw: String,
        mean: Double? = nil,
        standardDeviation: Double? = nil,
        p90: Double? = nil,
        p95: Double? = nil,
        sampleCount: Int,
        firstSampleAt: Date? = nil,
        lastSampleAt: Date? = nil,
        confidence: Double,
        contextKey: String? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.entityName = entityName
        self.roomName = roomName
        self.signalType = signalType
        self.baselineKind = baselineKind
        self.windowRaw = windowRaw
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.p90 = p90
        self.p95 = p95
        self.sampleCount = sampleCount
        self.firstSampleAt = firstSampleAt
        self.lastSampleAt = lastSampleAt
        self.confidence = confidence
        self.contextKey = contextKey
    }
}

enum HomeBaselineKind: String, Codable, Hashable, CaseIterable {
    case range
    case duration
    case frequency
    case timing
    case effectiveness
}

// MARK: - HomeInsight

struct HomeInsight: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: HomeInsightKind
    var category: HomeInsightCategory
    /// Tipo di segnale strutturato all'origine dell'insight (nil per sorgenti narrative/AI).
    /// Usato dal resolver per classificare dominio e issue in modo deterministico,
    /// senza dipendere dal matching testuale di titolo/messaggio (fragile e locale-dipendente).
    var signalType: HomeSignalType?
    var severity: HomeInsightSeverity
    var status: HomeInsightStatus
    var title: String
    var message: String
    var whyExplanation: String?
    var recommendation: String?
    var sourceEntityID: String?
    var sourceEntityName: String?
    var relatedEntityID: String?
    var relatedEntityName: String?
    var relatedRecordType: String?
    var relatedRecordID: String?
    var roomName: String?
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var resolvedAt: Date?
    var confidence: Double
    var score: HomeInsightScore?
    var dedupeKey: String
    var suggestedActionJSON: String?
    var sourceRecordType: String?
    var sourceRecordID: String?
    var syncPolicy: HomeInsightSyncPolicy

    init(
        id: UUID = UUID(),
        kind: HomeInsightKind,
        category: HomeInsightCategory,
        signalType: HomeSignalType? = nil,
        severity: HomeInsightSeverity,
        status: HomeInsightStatus = .active,
        title: String,
        message: String,
        whyExplanation: String? = nil,
        recommendation: String? = nil,
        sourceEntityID: String? = nil,
        sourceEntityName: String? = nil,
        relatedEntityID: String? = nil,
        relatedEntityName: String? = nil,
        relatedRecordType: String? = nil,
        relatedRecordID: String? = nil,
        roomName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        resolvedAt: Date? = nil,
        confidence: Double = 0.7,
        score: HomeInsightScore? = nil,
        dedupeKey: String,
        suggestedActionJSON: String? = nil,
        sourceRecordType: String? = nil,
        sourceRecordID: String? = nil,
        syncPolicy: HomeInsightSyncPolicy = .localOnly
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.signalType = signalType
        self.severity = severity
        self.status = status
        self.title = title
        self.message = message
        self.whyExplanation = whyExplanation
        self.recommendation = recommendation
        self.sourceEntityID = sourceEntityID
        self.sourceEntityName = sourceEntityName
        self.relatedEntityID = relatedEntityID
        self.relatedEntityName = relatedEntityName
        self.relatedRecordType = relatedRecordType
        self.relatedRecordID = relatedRecordID
        self.roomName = roomName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.resolvedAt = resolvedAt
        self.confidence = confidence
        self.score = score
        self.dedupeKey = dedupeKey
        self.suggestedActionJSON = suggestedActionJSON
        self.sourceRecordType = sourceRecordType
        self.sourceRecordID = sourceRecordID
        self.syncPolicy = syncPolicy
    }
}

enum HomeInsightKind: String, Codable, Hashable, CaseIterable {
    case anomaly
    case incoherence
    case environment
    case security
    case habit
    case opportunity
    case prediction
    case recommendation
    case maintenance
    case deviceHealth
}

enum HomeInsightCategory: String, Codable, Hashable, CaseIterable {
    case environment
    case security
    case habits
    case automation
    case maintenance
    case deviceHealth
    case presence
    case lighting
    case weather
    case system
}

enum HomeInsightSeverity: String, Codable, Hashable, CaseIterable, Comparable {
    case info
    case low
    case medium
    case high
    case critical

    private var sortOrder: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    static func < (lhs: HomeInsightSeverity, rhs: HomeInsightSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

enum HomeInsightStatus: String, Codable, Hashable, CaseIterable {
    case active
    case resolved
    case dismissed
    case snoozed
    case accepted
    case executed
    case expired
}

enum HomeInsightSyncPolicy: String, Codable, Hashable, CaseIterable {
    case localOnly
    case syncStatusOnly
    case syncFull
}

struct HomeInsightScore: Codable, Hashable {
    var relevance: Double
    var confidence: Double
    var urgency: Double
    var actionability: Double
    var novelty: Double

    var composite: Double {
        min(1.0,
            0.25 * relevance +
            0.25 * confidence +
            0.20 * urgency +
            0.20 * actionability +
            0.10 * novelty)
    }

    static let zero = HomeInsightScore(
        relevance: 0,
        confidence: 0,
        urgency: 0,
        actionability: 0,
        novelty: 0
    )
}

// MARK: - PersistedHomeInsight

@Model
final class PersistedHomeInsight {
    #Index<PersistedHomeInsight>([\.dedupeKey], [\.updatedAt], [\.statusRaw])

    var id: UUID
    var kindRaw: String
    var categoryRaw: String
    /// Raw di HomeSignalType (nil per insight senza segnale strutturato o record pre-v21).
    var signalTypeRaw: String?
    var severityRaw: String
    var statusRaw: String
    var title: String
    var message: String
    var whyExplanation: String?
    var recommendation: String?
    var sourceEntityID: String?
    var sourceEntityName: String?
    var relatedEntityID: String?
    var relatedEntityName: String?
    var relatedRecordType: String?
    var relatedRecordID: String?
    var roomName: String?
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var resolvedAt: Date?
    var confidence: Double
    var scoreRelevance: Double?
    var scoreConfidence: Double?
    var scoreUrgency: Double?
    var scoreActionability: Double?
    var scoreNovelty: Double?
    var dedupeKey: String
    var suggestedActionJSON: String?
    var sourceRecordType: String?
    var sourceRecordID: String?
    var syncPolicyRaw: String

    init(insight: HomeInsight) {
        self.id = insight.id
        self.kindRaw = insight.kind.rawValue
        self.categoryRaw = insight.category.rawValue
        self.signalTypeRaw = insight.signalType?.rawValue
        self.severityRaw = insight.severity.rawValue
        self.statusRaw = insight.status.rawValue
        self.title = insight.title
        self.message = insight.message
        self.whyExplanation = insight.whyExplanation
        self.recommendation = insight.recommendation
        self.sourceEntityID = insight.sourceEntityID
        self.sourceEntityName = insight.sourceEntityName
        self.relatedEntityID = insight.relatedEntityID
        self.relatedEntityName = insight.relatedEntityName
        self.relatedRecordType = insight.relatedRecordType
        self.relatedRecordID = insight.relatedRecordID
        self.roomName = insight.roomName
        self.createdAt = insight.createdAt
        self.updatedAt = insight.updatedAt
        self.startedAt = insight.startedAt
        self.resolvedAt = insight.resolvedAt
        self.confidence = insight.confidence
        if let score = insight.score {
            self.scoreRelevance = score.relevance
            self.scoreConfidence = score.confidence
            self.scoreUrgency = score.urgency
            self.scoreActionability = score.actionability
            self.scoreNovelty = score.novelty
        }
        self.dedupeKey = insight.dedupeKey
        self.suggestedActionJSON = insight.suggestedActionJSON
        self.sourceRecordType = insight.sourceRecordType
        self.sourceRecordID = insight.sourceRecordID
        self.syncPolicyRaw = insight.syncPolicy.rawValue
    }

    func update(from insight: HomeInsight) {
        kindRaw = insight.kind.rawValue
        categoryRaw = insight.category.rawValue
        signalTypeRaw = insight.signalType?.rawValue
        severityRaw = insight.severity.rawValue
        statusRaw = insight.status.rawValue
        title = insight.title
        message = insight.message
        whyExplanation = insight.whyExplanation
        recommendation = insight.recommendation
        sourceEntityID = insight.sourceEntityID
        sourceEntityName = insight.sourceEntityName
        relatedEntityID = insight.relatedEntityID
        relatedEntityName = insight.relatedEntityName
        relatedRecordType = insight.relatedRecordType
        relatedRecordID = insight.relatedRecordID
        roomName = insight.roomName
        updatedAt = insight.updatedAt
        startedAt = insight.startedAt
        resolvedAt = insight.resolvedAt
        confidence = insight.confidence
        if let score = insight.score {
            scoreRelevance = score.relevance
            scoreConfidence = score.confidence
            scoreUrgency = score.urgency
            scoreActionability = score.actionability
            scoreNovelty = score.novelty
        } else {
            scoreRelevance = nil
            scoreConfidence = nil
            scoreUrgency = nil
            scoreActionability = nil
            scoreNovelty = nil
        }
        suggestedActionJSON = insight.suggestedActionJSON
        sourceRecordType = insight.sourceRecordType
        sourceRecordID = insight.sourceRecordID
        syncPolicyRaw = insight.syncPolicy.rawValue
    }

    func markResolved(at date: Date = Date()) {
        statusRaw = HomeInsightStatus.resolved.rawValue
        resolvedAt = date
        updatedAt = date
    }

    func toHomeInsight() -> HomeInsight {
        let restoredScore: HomeInsightScore?
        if let relevance = scoreRelevance,
           let confidence = scoreConfidence,
           let urgency = scoreUrgency,
           let actionability = scoreActionability,
           let novelty = scoreNovelty {
            restoredScore = HomeInsightScore(
                relevance: relevance,
                confidence: confidence,
                urgency: urgency,
                actionability: actionability,
                novelty: novelty
            )
        } else {
            restoredScore = nil
        }

        return HomeInsight(
            id: id,
            kind: HomeInsightKind(rawValue: kindRaw) ?? .anomaly,
            category: HomeInsightCategory(rawValue: categoryRaw) ?? .system,
            signalType: signalTypeRaw.flatMap(HomeSignalType.init(rawValue:)),
            severity: HomeInsightSeverity(rawValue: severityRaw) ?? .info,
            status: HomeInsightStatus(rawValue: statusRaw) ?? .active,
            title: title,
            message: message,
            whyExplanation: whyExplanation,
            recommendation: recommendation,
            sourceEntityID: sourceEntityID,
            sourceEntityName: sourceEntityName,
            relatedEntityID: relatedEntityID,
            relatedEntityName: relatedEntityName,
            relatedRecordType: relatedRecordType,
            relatedRecordID: relatedRecordID,
            roomName: roomName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            resolvedAt: resolvedAt,
            confidence: confidence,
            score: restoredScore,
            dedupeKey: dedupeKey,
            suggestedActionJSON: suggestedActionJSON,
            sourceRecordType: sourceRecordType,
            sourceRecordID: sourceRecordID,
            syncPolicy: HomeInsightSyncPolicy(rawValue: syncPolicyRaw) ?? .localOnly
        )
    }
}
