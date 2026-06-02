import Foundation
import SwiftUI

// MARK: - SecurityInsightPriority

enum SecurityInsightPriority: String, Codable, Comparable {
    case critical = "critical"
    case warning  = "warning"
    case info     = "info"

    static func < (lhs: SecurityInsightPriority, rhs: SecurityInsightPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .warning:  return 1
        case .info:     return 2
        }
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .purple
        }
    }

    var sfSymbol: String {
        switch self {
        case .critical: return "flame.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .info:     return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .critical: return String(localized: "security.insights.priority.critical", defaultValue: "Critico")
        case .warning:  return String(localized: "security.insights.priority.warning",  defaultValue: "Attenzione")
        case .info:     return String(localized: "security.insights.priority.info",     defaultValue: "Info")
        }
    }
}

// MARK: - SecurityInsight

/// Insight di sicurezza derivato dallo stato in tempo reale dei sensori HomeKit.
/// Non richiede AI — è computato localmente da SecurityScoreService.
struct SecurityInsight: Identifiable {
    let id: UUID
    let priority: SecurityInsightPriority
    /// Stanza di riferimento (nil = insight globale).
    let room: String?
    /// Testo descrittivo (localizzato).
    let message: String
    /// Azione suggerita (localizzata).
    let suggestedAction: String?
    /// SF Symbol associato al sensore o evento.
    let sfSymbol: String
    let timestamp: Date
    /// UUID dell'accessorio HomeKit correlato (per navigazione drill-down).
    let accessoryID: UUID?

    init(
        id: UUID = UUID(),
        priority: SecurityInsightPriority,
        room: String? = nil,
        message: String,
        suggestedAction: String? = nil,
        sfSymbol: String,
        timestamp: Date = Date(),
        accessoryID: UUID? = nil
    ) {
        self.id = id
        self.priority = priority
        self.room = room
        self.message = message
        self.suggestedAction = suggestedAction
        self.sfSymbol = sfSymbol
        self.timestamp = timestamp
        self.accessoryID = accessoryID
    }
}
