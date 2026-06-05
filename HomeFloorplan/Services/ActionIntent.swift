import Foundation

// MARK: - Season

enum Season {
    case winter, spring, summer, autumn

    static var current: Season {
        let month = Calendar.current.component(.month, from: Date())
        switch month {
        case 12, 1, 2:  return .winter
        case 3, 4, 5:   return .spring
        case 6, 7, 8:   return .summer
        case 9, 10, 11: return .autumn
        default:         return .spring
        }
    }
}

// MARK: - ResolvedAction

/// Describes the HomeKit action a resolver should emit for a given intent + accessory category.
struct ResolvedAction {
    /// HAP action type: "on"|"off"|"setMode"|"setSpeed"|"setTemp"|"open"|"close"|"dim"
    let actionType: String
    /// Numeric value: nil for on/off, 0.0–1.0 for dim/setSpeed, °C for setTemp, mode index for setMode
    let value: Double?
    /// Secondary temperature in °C for setMode on thermostats/heat-pumps
    let value2: Double?
    /// Printf-style format string for the chip label, e.g. "Raffredda %@" where %@ = accessory name
    let labelKey: String
}

// MARK: - ActionIntent

/// Semantic intent catalog.  Each case represents a single environmental goal,
/// independent of which specific accessory will satisfy it.
enum ActionIntent: String, CaseIterable {
    case coolRoom
    case heatRoom
    case reduceHumidity
    case increaseHumidity
    case improveAirQuality
    case ventilateRoom
    case reduceCO2
    case respondToSmoke
    case respondToCO

    // MARK: - Category Filtering

    /// Accessory categories that are eligible to satisfy this intent.
    var allowedCategories: Set<String> {
        switch self {
        case .coolRoom:           return ["airConditioner", "thermostat", "fan"]
        case .heatRoom:           return ["thermostat", "valve"]
        case .reduceHumidity:     return ["airPurifier", "fan"]
        case .increaseHumidity:   return ["airPurifier"]
        case .improveAirQuality:  return ["airPurifier"]
        case .ventilateRoom:      return ["fan", "airPurifier"]
        case .reduceCO2:          return ["fan", "airPurifier"]
        case .respondToSmoke:     return []  // tip only
        case .respondToCO:        return []  // tip only
        }
    }

    /// Accessory categories that must never be used for this intent,
    /// even if they appear in allowedCategories (belt-and-suspenders safety).
    var forbiddenCategories: Set<String> {
        switch self {
        case .reduceHumidity:  return ["windowCovering"]  // blinds ≠ dehumidification
        case .respondToSmoke:  return ["windowCovering"]
        default:               return []
        }
    }

    /// True if this action should be suppressed during evening/night hours (19:00–07:00).
    var nightRestricted: Bool {
        switch self {
        case .ventilateRoom: return true
        default:             return false  // reduceCO2 is never night-restricted (CO₂ peaks at night in bedrooms)
        }
    }

    // MARK: - Resolution

    /// Returns the concrete HomeKit action for the given accessory category, season and hour.
    /// Returns nil when the category is not handled for this intent.
    func resolveAction(for category: String, season: Season, hour: Int) -> ResolvedAction? {
        switch self {
        case .coolRoom:
            switch category {
            case "thermostat", "airConditioner":
                return ResolvedAction(actionType: "setMode", value: 2, value2: 24, labelKey: "Raffredda con %@")
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Ventila con %@")
            default: return nil
            }

        case .heatRoom:
            switch category {
            case "thermostat":
                return ResolvedAction(actionType: "setMode", value: 1, value2: 21, labelKey: "Riscalda con %@")
            case "valve":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Apri %@")
            default: return nil
            }

        case .reduceHumidity:
            switch category {
            case "airPurifier":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Deumidifica con %@")
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Ventila con %@")
            default: return nil
            }

        case .increaseHumidity:
            if category == "airPurifier" {
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Umidifica con %@")
            }
            return nil

        case .improveAirQuality:
            if category == "airPurifier" {
                return ResolvedAction(actionType: "setMode", value: 1, value2: nil, labelKey: "Purifica con %@")
            }
            return nil

        case .ventilateRoom:
            switch category {
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Ventila con %@")
            case "airPurifier":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Ricambio aria con %@")
            default: return nil
            }

        case .reduceCO2:
            switch category {
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: "Abbassa CO₂ con %@")
            case "airPurifier":
                return ResolvedAction(actionType: "setMode", value: 1, value2: nil, labelKey: "Abbassa CO₂ con %@")
            default: return nil
            }

        case .respondToSmoke, .respondToCO:
            return nil  // always handled via fallbackTip
        }
    }

    /// Manual tip shown when no suitable accessory is found in the room.
    /// Room-type-aware: returns nil to suppress the tip when it would be nonsensical
    /// (e.g. "Apri le finestre" outdoors, "Arieggia la stanza" on a balcony).
    func fallbackTip(for roomType: RoomType) -> AINextAction? {
        let label: String
        switch (self, roomType) {
        case (.coolRoom, .outdoor):
            label = "Attiva la tenda da sole"
        case (.heatRoom, .outdoor):
            label = "Rientra in casa"
        case (.reduceHumidity, .outdoor):
            return nil  // non ha senso deumidificare all'aperto
        case (.ventilateRoom, .outdoor):
            return nil  // sei già all'aperto
        case (.coolRoom, _):
            label = "Apri le finestre"
        case (.heatRoom, _):
            label = "Chiudi porte e finestre"
        case (.reduceHumidity, _):
            label = "Arieggia la stanza"
        case (.increaseHumidity, _):
            label = "Usa un umidificatore"
        case (.improveAirQuality, _):
            label = "Apri le finestre"
        case (.ventilateRoom, _):
            label = "Apri le finestre"
        case (.reduceCO2, .outdoor):
            return nil  // outdoors CO₂ is naturally dispersed
        case (.reduceCO2, _):
            label = "Arieggia la stanza"
        case (.respondToSmoke, _):
            label = "Evacua e chiama i soccorsi"
        case (.respondToCO, _):
            label = "Apri tutto e esci"
        }
        return AINextAction(label: label, actionType: "tip")
    }

    /// Backward-compatible wrapper: tip per stanze indoor (default).
    var fallbackTip: AINextAction { fallbackTip(for: .indoor)! }
}
