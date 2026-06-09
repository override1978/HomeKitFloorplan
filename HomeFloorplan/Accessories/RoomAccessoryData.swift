import SwiftUI
import HomeKit

// MARK: - AccessoryHealthScore

/// Livello di salute sintetico di una stanza, derivato deterministicamente
/// dai dispositivi offline, batteria scarica e irraggiungibili.
enum AccessoryHealthLevel {
    case excellent  // 85–100
    case good       // 65–84
    case warning    // 35–64
    case critical   // 0–34

    var label: String {
        switch self {
        case .excellent: return String(localized: "accessories.room.health.excellent", defaultValue: "Excellent")
        case .good:      return String(localized: "accessories.room.health.good",      defaultValue: "Good")
        case .warning:   return String(localized: "accessories.room.health.warning",   defaultValue: "Warning")
        case .critical:  return String(localized: "accessories.room.health.critical",  defaultValue: "Critical")
        }
    }

    var color: Color {
        switch self {
        case .excellent: return .green
        case .good:      return Color(red: 0.55, green: 0.80, blue: 0.20)
        case .warning:   return .orange
        case .critical:  return .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .excellent: return "checkmark.circle.fill"
        case .good:      return "checkmark.circle"
        case .warning:   return "exclamationmark.triangle.fill"
        case .critical:  return "xmark.circle.fill"
        }
    }

    static func from(score: Int) -> AccessoryHealthLevel {
        switch score {
        case 85...100: return .excellent
        case 65..<85:  return .good
        case 35..<65:  return .warning
        default:       return .critical
        }
    }
}

// MARK: - AccessoryRoomCategory

/// Riassunto per categoria di accessori in una stanza.
/// Usato per i micro-badge nella card collassata.
struct AccessoryRoomCategoryBadge: Identifiable, Equatable {
    let id: AccessoryCategory
    let count: Int
    let symbol: String

    var category: AccessoryCategory { id }
}

// MARK: - RoomAccessoryData

/// Modello di dati aggregato per una stanza nel modulo Accessori.
/// Calcolato dal ViewModel, immutabile dalla view.
struct RoomAccessoryData: Identifiable, Equatable, Hashable {

    // MARK: Identity
    let id: UUID          // UUID di HMRoom
    let roomName: String

    // MARK: Accessories (raw, per navigazione verso AccessoryDetailView)
    let accessories: [HMAccessory]

    // MARK: Counts
    let totalCount: Int
    let offlineCount: Int
    let lowBatteryCount: Int

    // MARK: Health score (0–100, deterministico)
    let healthScore: Int

    var healthLevel: AccessoryHealthLevel { .from(score: healthScore) }

    // MARK: Category breakdown (per micro-badge)
    let categoryBadges: [AccessoryRoomCategoryBadge]

    // MARK: Recent activity
    let lastActivityDate: Date?

    // MARK: - Equatable & Hashable
    // HMAccessory non è Equatable/Hashable: usiamo solo l'UUID della stanza.
    static func == (lhs: RoomAccessoryData, rhs: RoomAccessoryData) -> Bool {
        lhs.id == rhs.id &&
        lhs.totalCount == rhs.totalCount &&
        lhs.offlineCount == rhs.offlineCount &&
        lhs.lowBatteryCount == rhs.lowBatteryCount &&
        lhs.healthScore == rhs.healthScore
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Convenience

extension RoomAccessoryData {

    /// Stringa di sottotitolo: "18 accessori • 100 Ottima"
    var subtitleText: String {
        let countStr = totalCount == 1
            ? String(localized: "accessories.room.accessory.singular", defaultValue: "1 accessory")
            : "\(totalCount) \(String(localized: "accessories.room.accessories.unit", defaultValue: "accessories"))"
        return "\(countStr) • \(healthScore) \(healthLevel.label)"
    }

    /// Problema principale da mostrare nella card collassata (se presente).
    var primaryIssue: String? {
        if offlineCount > 0 {
            if offlineCount == 1 {
                return String(localized: "accessories.room.issue.offline.singular", defaultValue: "1 device offline")
            }
            let unit = String(localized: "accessories.room.issue.offline.unit", defaultValue: "devices offline")
            return "\(offlineCount) \(unit)"
        }
        if lowBatteryCount > 0 {
            if lowBatteryCount == 1 {
                return String(localized: "accessories.room.issue.battery.singular", defaultValue: "Low battery on 1 device")
            }
            let unit = String(localized: "accessories.room.issue.battery.unit", defaultValue: "devices with low battery")
            return "Batteria scarica su \(lowBatteryCount) \(unit)"
        }
        return nil
    }

    /// Accessori divisi per categoria HomeKit.
    @MainActor
    func accessories(in category: AccessoryCategory, homeKit: HomeKitService) -> [HMAccessory] {
        guard category != .all else { return accessories }
        return accessories.filter { accessory in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            return AccessoryCategory.classify(adapter: adapter) == category
        }
    }
}
