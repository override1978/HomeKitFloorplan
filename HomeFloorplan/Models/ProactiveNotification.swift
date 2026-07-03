import Foundation
import SwiftData

// MARK: - NotificationCategory

enum NotificationCategory: String, Codable, CaseIterable {
    case environment          = "environment"
    case comfort              = "comfort"
    case security             = "security"
    case lighting             = "lighting"
    case presence             = "presence"
    case hvac                 = "hvac"
    case scenes               = "scenes"
    case learning             = "learning"
    case behavioralAI         = "behavioralAI"
    case automationOpportunity = "automationOpportunity"
    case maintenance          = "maintenance"
    case deviceHealth         = "deviceHealth"
    case aiDiscovery          = "aiDiscovery"
    case weather              = "weather"

    var sfSymbol: String {
        switch self {
        case .environment:           return "thermometer.medium"
        case .comfort:               return "bed.double.fill"
        case .security:              return "lock.shield.fill"
        case .lighting:              return "lightbulb.fill"
        case .presence:              return "person.fill.viewfinder"
        case .hvac:                  return "air.conditioner.horizontal.fill"
        case .scenes:                return "theatermasks.fill"
        case .learning:              return "brain.head.profile"
        case .behavioralAI:          return "arrow.triangle.branch"
        case .automationOpportunity: return "wand.and.stars"
        case .maintenance:           return "wrench.and.screwdriver.fill"
        case .deviceHealth:          return "exclamationmark.circle.fill"
        case .aiDiscovery:           return "sparkles"
        case .weather:               return "cloud.sun.fill"
        }
    }

    var defaultPriority: NotificationPriority {
        switch self {
        case .security, .deviceHealth:                               return .high
        case .maintenance:                                            return .high
        case .environment, .hvac, .presence, .automationOpportunity: return .medium
        case .comfort, .lighting, .scenes, .behavioralAI:             return .low
        case .learning, .aiDiscovery:                                 return .info
        case .weather:                                                return .low
        }
    }

    // String-based color token — converted to SwiftUI Color in the view layer
    var accentColorToken: String {
        switch self {
        case .environment:           return "blue"
        case .comfort:               return "purple"
        case .security:              return "red"
        case .lighting:              return "amber"
        case .presence:              return "teal"
        case .hvac:                  return "orange"
        case .scenes:                return "indigo"
        case .learning:              return "brand"
        case .behavioralAI:          return "brand"
        case .automationOpportunity: return "green"
        case .maintenance:           return "orange"
        case .deviceHealth:          return "red"
        case .aiDiscovery:           return "brand"
        case .weather:               return "blue"
        }
    }

    var localizedTitle: String {
        switch self {
        case .environment:           return String(localized: "notif.cat.environment",    defaultValue: "Environment")
        case .comfort:               return String(localized: "notif.cat.comfort",        defaultValue: "Comfort")
        case .security:              return String(localized: "notif.cat.security",       defaultValue: "Security")
        case .lighting:              return String(localized: "notif.cat.lighting",       defaultValue: "Lighting")
        case .presence:              return String(localized: "notif.cat.presence",       defaultValue: "Presence")
        case .hvac:                  return String(localized: "notif.cat.hvac",           defaultValue: "Climate")
        case .scenes:                return String(localized: "notif.cat.scenes",         defaultValue: "Scenes")
        case .learning:              return String(localized: "notif.cat.learning",       defaultValue: "Learning")
        case .behavioralAI:          return String(localized: "notif.cat.behavioral",     defaultValue: "Behavioral AI")
        case .automationOpportunity: return String(localized: "notif.cat.automation",     defaultValue: "Automation")
        case .maintenance:           return String(localized: "notif.cat.maintenance",    defaultValue: "Maintenance")
        case .deviceHealth:          return String(localized: "notif.cat.deviceHealth",   defaultValue: "Devices")
        case .aiDiscovery:           return String(localized: "notif.cat.aiDiscovery",    defaultValue: "AI Discovery")
        case .weather:               return String(localized: "notif.cat.weather",        defaultValue: "Weather")
        }
    }

    // UNNotificationCategory identifier for delivery
    var unCategoryIdentifier: String { "com.homefloorplan.\(rawValue)" }
}

// MARK: - NotificationPriority

enum NotificationPriority: Int, Codable, Comparable {
    case info     = 0
    case low      = 1
    case medium   = 2
    case high     = 3
    case critical = 4

    static func < (lhs: NotificationPriority, rhs: NotificationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var sendsSystemNotification: Bool { self >= .high }
    var incrementsBadge: Bool         { self >= .medium }
    var breaksQuietHours: Bool        { self == .critical }
}

// MARK: - ProactiveNotificationStatus

enum ProactiveNotificationStatus: String, Codable {
    case pending
    case live
    case updated
    case acknowledged
    case actedOn
    case snoozed
    case dismissed
    case resolved
    case archived
    case expired

    var isLive: Bool       { self == .live || self == .updated }
    var isActionable: Bool { self == .live || self == .updated || self == .acknowledged }
    var isTerminal: Bool   { self == .dismissed || self == .resolved || self == .archived || self == .expired }

    var localizedLabel: String {
        switch self {
        case .pending:      return String(localized: "notif.status.pending",      defaultValue: "Pending")
        case .live:         return String(localized: "notif.status.live",         defaultValue: "Active")
        case .updated:      return String(localized: "notif.status.updated",      defaultValue: "Updated")
        case .acknowledged: return String(localized: "notif.status.acknowledged", defaultValue: "Seen")
        case .actedOn:      return String(localized: "notif.status.actedOn",      defaultValue: "Done")
        case .snoozed:      return String(localized: "notif.status.snoozed",      defaultValue: "Snoozed")
        case .dismissed:    return String(localized: "notif.status.dismissed",    defaultValue: "Dismissed")
        case .resolved:     return String(localized: "notif.status.resolved",     defaultValue: "Resolved")
        case .archived:     return String(localized: "notif.status.archived",     defaultValue: "Archived")
        case .expired:      return String(localized: "notif.status.expired",      defaultValue: "Expired")
        }
    }
}

// MARK: - NotificationTrend

enum NotificationTrend: String, Codable {
    case rising, stable, falling

    var sfSymbol: String {
        switch self {
        case .rising:  return "arrow.up"
        case .stable:  return "minus"
        case .falling: return "arrow.down"
        }
    }

    var localizedLabel: String {
        switch self {
        case .rising:  return String(localized: "notif.trend.rising",  defaultValue: "Rising")
        case .stable:  return String(localized: "notif.trend.stable",  defaultValue: "Stable")
        case .falling: return String(localized: "notif.trend.falling", defaultValue: "Falling")
        }
    }
}

// MARK: - IntelligenceScore

/// 5-axis AI quality score. Every notification exposes this for explainability.
struct IntelligenceScore: Codable {
    var relevance:     Double   // 0–1: relevant to current context?
    var confidence:    Double   // 0–1: how certain is the AI?
    var urgency:       Double   // 0–1: how time-sensitive?
    var actionability: Double   // 0–1: can the user act on it?
    var novelty:       Double   // 0–1: is it new information?

    var composite: Double {
        min(1.0,
            0.25 * relevance +
            0.25 * confidence +
            0.20 * urgency +
            0.20 * actionability +
            0.10 * novelty)
    }

    static let zero = IntelligenceScore(
        relevance: 0, confidence: 0, urgency: 0, actionability: 0, novelty: 0
    )
}

// MARK: - ProactiveNotification (@Model)

@Model
final class ProactiveNotification {

    var id:             UUID
    var categoryRaw:    String
    var priorityRaw:    Int
    var statusRaw:      String
    var semanticKey:    String      // stable deduplication key (e.g. "environment|Bagno|humidity")
    var headline:       String
    var body:           String
    var contextNote:    String?     // seasonal / contextual annotation
    var currentValue:   String?     // latest sensor reading string
    var peakValue:      String?     // worst value observed so far
    var trendRaw:       String?     // NotificationTrend raw
    var recommendation: String?     // actionable suggestion
    var deepLink:       String?     // homefloorplan:// URL scheme
    var sourceID:       String?     // patternID / opportunityID / accessoryUUID
    var whyExplanation: String?     // plain-language "why am I seeing this?"
    var createdAt:      Date
    var lastUpdatedAt:  Date
    var acknowledgedAt: Date?
    var resolvedAt:     Date?
    var snoozedUntil:   Date?
    var dismissCount:   Int
    var scoreData:      Data?       // JSON-encoded IntelligenceScore

    // MARK: Computed accessors

    var category: NotificationCategory {
        NotificationCategory(rawValue: categoryRaw) ?? .aiDiscovery
    }

    var priority: NotificationPriority {
        NotificationPriority(rawValue: priorityRaw) ?? .info
    }

    var status: ProactiveNotificationStatus {
        get { ProactiveNotificationStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var trend: NotificationTrend? {
        guard let r = trendRaw else { return nil }
        return NotificationTrend(rawValue: r)
    }

    var score: IntelligenceScore? {
        guard let d = scoreData else { return nil }
        return try? JSONDecoder().decode(IntelligenceScore.self, from: d)
    }

    // MARK: Display

    var displayHeadline: String {
        headline
    }

    var displayBody: String {
        body
    }

    var displayRecommendation: String? {
        recommendation
    }

    var displayWhyExplanation: String? {
        whyExplanation
    }

    // MARK: Init

    init(
        category:       NotificationCategory,
        priority:       NotificationPriority,
        semanticKey:    String,
        headline:       String,
        body:           String,
        contextNote:    String?           = nil,
        currentValue:   String?           = nil,
        peakValue:      String?           = nil,
        trend:          NotificationTrend? = nil,
        recommendation: String?           = nil,
        deepLink:       String?           = nil,
        sourceID:       String?           = nil,
        whyExplanation: String?           = nil,
        score:          IntelligenceScore? = nil
    ) {
        self.id             = UUID()
        self.categoryRaw    = category.rawValue
        self.priorityRaw    = priority.rawValue
        self.statusRaw      = ProactiveNotificationStatus.pending.rawValue
        self.semanticKey    = semanticKey
        self.headline       = headline
        self.body           = body
        self.contextNote    = contextNote
        self.currentValue   = currentValue
        self.peakValue      = peakValue
        self.trendRaw       = trend?.rawValue
        self.recommendation = recommendation
        self.deepLink       = deepLink
        self.sourceID       = sourceID
        self.whyExplanation = whyExplanation
        self.createdAt      = Date()
        self.lastUpdatedAt  = Date()
        self.dismissCount   = 0
        self.scoreData      = score.flatMap { try? JSONEncoder().encode($0) }
    }
}
