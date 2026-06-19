import Foundation

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
    // Sprint 28 — Lighting AI
    case brightenRoom
    case dimRoom
    case setCircadianLight
    case setScene
    // Sprint 29 — Presence AI
    case prepareForArrival
    case secureForDeparture
    // Sprint 30 — Energy AI
    case reduceConsumption
    case enableEcoMode
    case schedulePeakHours
    // Sprint 32 — Security
    case lockAll
    case closeGarage
    case armNightSecurity
    case armAwaySecurity

    // MARK: - Category Filtering

    /// Accessory categories that are eligible to satisfy this intent.
    var allowedCategories: Set<String> {
        switch self {
        case .coolRoom:           return ["airConditioner", "thermostat", "fan", "windowCovering"]
        case .heatRoom:           return ["thermostat", "valve"]
        case .reduceHumidity:     return ["airPurifier", "fan"]
        case .increaseHumidity:   return ["humidifier", "airPurifier"]
        case .improveAirQuality:  return ["airPurifier"]
        case .ventilateRoom:      return ["fan", "airPurifier"]
        case .reduceCO2:          return ["fan", "airPurifier"]
        case .respondToSmoke:     return []  // tip only
        case .respondToCO:        return []  // tip only
        case .brightenRoom:       return ["dimmableLight", "colorLight"]
        case .dimRoom:            return ["dimmableLight", "colorLight"]
        case .setCircadianLight:  return ["colorLight"]
        case .setScene:           return ["sceneController"]
        case .prepareForArrival:   return ["thermostat", "valve", "colorLight", "dimmableLight", "windowCovering"]
        case .secureForDeparture:  return ["outlet", "switch", "fan", "colorLight", "dimmableLight", "onOff", "doorLock", "garageDoor"]
        case .reduceConsumption:   return ["fan", "airConditioner", "thermostat", "outlet", "switch", "colorLight", "dimmableLight", "onOff"]
        case .enableEcoMode:       return ["thermostat", "airConditioner"]
        case .schedulePeakHours:   return []   // tip-only
        case .lockAll:             return ["doorLock"]
        case .closeGarage:         return ["garageDoor"]
        case .armNightSecurity:    return ["doorLock", "garageDoor"]
        case .armAwaySecurity:     return ["doorLock", "garageDoor"]
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
        case .brightenRoom:  return true  // don't suggest brightening during nighttime hours
        default:             return false  // reduceCO2 is never night-restricted (CO₂ peaks at night in bedrooms)
        }
    }

    // MARK: - Resolution

    /// Returns the concrete HomeKit action for the given accessory category, season and hour.
    /// Returns nil when the category is not handled for this intent.
    func resolveAction(for category: String, season: CalendarSeason, hour: Int) -> ResolvedAction? {
        switch self {
        case .coolRoom:
            switch category {
            case "thermostat", "airConditioner":
                return ResolvedAction(actionType: "setMode", value: 2, value2: 24, labelKey: String(localized: "action.label.cool", defaultValue: "Cool"))
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.fan", defaultValue: "Ventilate"))
            case "windowCovering":
                return ResolvedAction(actionType: "close", value: nil, value2: nil, labelKey: String(localized: "action.label.closeBlinds", defaultValue: "Close blinds"))
            default: return nil
            }

        case .heatRoom:
            switch category {
            case "thermostat":
                return ResolvedAction(actionType: "setMode", value: 1, value2: 21, labelKey: String(localized: "action.label.heat", defaultValue: "Heat"))
            case "valve":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.openValve", defaultValue: "Open valve"))
            default: return nil
            }

        case .reduceHumidity:
            switch category {
            case "airPurifier":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.dehumidify", defaultValue: "Reduce humidity"))
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.fan", defaultValue: "Ventilate"))
            default: return nil
            }

        case .increaseHumidity:
            if category == "humidifier" || category == "airPurifier" {
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.humidify", defaultValue: "Increase humidity"))
            }
            return nil

        case .improveAirQuality:
            if category == "airPurifier" {
                return ResolvedAction(actionType: "setMode", value: 1, value2: nil, labelKey: String(localized: "action.label.purifyAir", defaultValue: "Purify air"))
            }
            return nil

        case .ventilateRoom:
            switch category {
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.fan", defaultValue: "Ventilate"))
            case "airPurifier":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.airExchange", defaultValue: "Refresh air"))
            default: return nil
            }

        case .reduceCO2:
            switch category {
            case "fan":
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.lowerCO2", defaultValue: "Lower CO₂"))
            case "airPurifier":
                return ResolvedAction(actionType: "setMode", value: 1, value2: nil, labelKey: String(localized: "action.label.lowerCO2", defaultValue: "Lower CO₂"))
            default: return nil
            }

        case .respondToSmoke, .respondToCO:
            return nil  // always handled via fallbackTip

        case .brightenRoom:
            switch category {
            case "dimmableLight", "colorLight":
                return ResolvedAction(actionType: "dim", value: 0.8, value2: nil, labelKey: String(localized: "action.label.brighten", defaultValue: "Brighten"))
            default: return nil
            }

        case .dimRoom:
            switch category {
            case "dimmableLight", "colorLight":
                return ResolvedAction(actionType: "dim", value: 0.25, value2: nil, labelKey: String(localized: "action.label.dim", defaultValue: "Dim"))
            default: return nil
            }

        case .setCircadianLight:
            if category == "colorLight" {
                return ResolvedAction(actionType: "dim", value: 0.35, value2: nil, labelKey: String(localized: "action.label.circadian", defaultValue: "Evening light"))
            }
            return nil

        case .setScene:
            if category == "sceneController" {
                return ResolvedAction(actionType: "on", value: nil, value2: nil, labelKey: String(localized: "action.label.activateScene", defaultValue: "Activate scene"))
            }
            return nil

        case .prepareForArrival:
            switch category {
            case "thermostat":
                let isHot = season == .summer
                return ResolvedAction(actionType: "setMode", value: isHot ? 2 : 1, value2: isHot ? 24 : 20,
                                      labelKey: String(localized: "action.label.prepareArrival", defaultValue: "Prepare home"))
            case "valve":
                return ResolvedAction(actionType: "on", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.prepareArrival", defaultValue: "Prepare home"))
            case "colorLight", "dimmableLight":
                return ResolvedAction(actionType: "dim", value: 0.60, value2: nil,
                                      labelKey: String(localized: "action.label.prepareArrival", defaultValue: "Prepare home"))
            case "windowCovering":
                return ResolvedAction(actionType: "open", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.prepareArrival", defaultValue: "Prepare home"))
            default: return nil
            }

        case .secureForDeparture:
            switch category {
            case "colorLight", "dimmableLight", "outlet", "switch", "fan", "onOff":
                return ResolvedAction(actionType: "off", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.secureDeparture", defaultValue: "Turn off"))
            case "doorLock":
                return ResolvedAction(actionType: "lock", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.secureDeparture", defaultValue: "Secure home"))
            case "garageDoor":
                return ResolvedAction(actionType: "closeGarage", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.secureDeparture", defaultValue: "Close garage"))
            default: return nil
            }

        case .reduceConsumption:
            switch category {
            case "colorLight", "dimmableLight":
                return ResolvedAction(actionType: "off", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.reduceConsumption", defaultValue: "Reduce usage"))
            case "fan", "outlet", "switch", "onOff":
                return ResolvedAction(actionType: "off", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.reduceConsumption", defaultValue: "Reduce usage"))
            case "thermostat", "airConditioner":
                let isHot = season == .summer
                return ResolvedAction(actionType: "setMode", value: isHot ? 2 : 1, value2: isHot ? 26 : 18,
                                      labelKey: String(localized: "action.label.reduceConsumption", defaultValue: "Reduce usage"))
            default: return nil
            }

        case .enableEcoMode:
            switch category {
            case "thermostat", "airConditioner":
                switch season {
                case .summer:
                    return ResolvedAction(actionType: "setMode", value: 2, value2: 26,
                                          labelKey: String(localized: "action.label.ecoMode", defaultValue: "Eco mode"))
                case .winter:
                    return ResolvedAction(actionType: "setMode", value: 1, value2: 18,
                                          labelKey: String(localized: "action.label.ecoMode", defaultValue: "Eco mode"))
                default:
                    return ResolvedAction(actionType: "setMode", value: 0, value2: 22,
                                          labelKey: String(localized: "action.label.ecoMode", defaultValue: "Eco mode"))
                }
            default: return nil
            }

        case .schedulePeakHours:
            return nil  // tip-only — no device action

        case .lockAll:
            if category == "doorLock" {
                return ResolvedAction(actionType: "lock", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.lockAll", defaultValue: "Lock doors"))
            }
            return nil

        case .closeGarage:
            if category == "garageDoor" {
                return ResolvedAction(actionType: "closeGarage", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.closeGarage", defaultValue: "Close garage"))
            }
            return nil

        case .armNightSecurity:
            switch category {
            case "doorLock":
                return ResolvedAction(actionType: "lock", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.armNight", defaultValue: "Secure night"))
            case "garageDoor":
                return ResolvedAction(actionType: "closeGarage", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.armNight", defaultValue: "Secure night"))
            default: return nil
            }

        case .armAwaySecurity:
            switch category {
            case "doorLock":
                return ResolvedAction(actionType: "lock", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.armAway", defaultValue: "Secure home"))
            case "garageDoor":
                return ResolvedAction(actionType: "closeGarage", value: nil, value2: nil,
                                      labelKey: String(localized: "action.label.armAway", defaultValue: "Secure home"))
            default: return nil
            }
        }
    }

    /// Manual tip shown when no suitable accessory is found in the room.
    /// Room-type-aware: returns nil to suppress the tip when it would be nonsensical
    /// (e.g. "Apri le finestre" outdoors, "Arieggia la stanza" on a balcony).
    func fallbackTip(for roomType: RoomType) -> AINextAction? {
        let label: String
        let icon: String
        switch (self, roomType) {
        case (.coolRoom, .outdoor):
            label = String(localized: "action.tip.sunshade", defaultValue: "Lower the shade"); icon = "arrow.down.square"
        case (.heatRoom, .outdoor):
            label = String(localized: "action.tip.goInside", defaultValue: "Go back inside");         icon = "house.fill"
        case (.reduceHumidity, .outdoor):
            return nil  // non ha senso deumidificare all'aperto
        case (.ventilateRoom, .outdoor):
            return nil  // sei già all'aperto
        case (.coolRoom, _):
            label = String(localized: "action.tip.openWindows", defaultValue: "Open the windows");        icon = "wind"
        case (.heatRoom, _):
            label = String(localized: "action.tip.closeDoors", defaultValue: "Close doors and windows"); icon = "xmark.square"
        case (.reduceHumidity, _):
            label = String(localized: "action.tip.ventilate", defaultValue: "Air out the room");      icon = "wind"
        case (.increaseHumidity, _):
            label = String(localized: "action.tip.useHumidifier", defaultValue: "Use a humidifier");    icon = "drop.fill"
        case (.improveAirQuality, _):
            label = String(localized: "action.tip.openWindows", defaultValue: "Open the windows");        icon = "wind"
        case (.ventilateRoom, _):
            label = String(localized: "action.tip.openWindows", defaultValue: "Open the windows");        icon = "wind"
        case (.reduceCO2, .outdoor):
            return nil  // outdoors CO₂ is naturally dispersed
        case (.reduceCO2, _):
            label = String(localized: "action.tip.ventilate", defaultValue: "Air out the room");      icon = "wind"
        case (.respondToSmoke, _):
            label = String(localized: "action.tip.evacuate", defaultValue: "Leave and call emergency services"); icon = "sos"
        case (.respondToCO, _):
            label = String(localized: "action.tip.exitAndOpenAll", defaultValue: "Open everything and leave");       icon = "arrow.up.right.square"
        case (.brightenRoom, .outdoor), (.dimRoom, .outdoor), (.setCircadianLight, .outdoor):
            return nil  // outdoor lighting adjustments don't need indoor tips
        case (.setScene, _):
            return nil  // no manual equivalent for scene controllers
        case (.brightenRoom, _):
            label = String(localized: "action.tip.openBlinds", defaultValue: "Open the blinds");      icon = "arrow.up.square"
        case (.dimRoom, _):
            label = String(localized: "action.tip.dimManually", defaultValue: "Lower the brightness"); icon = "light.min"
        case (.setCircadianLight, _):
            label = String(localized: "action.tip.warmLight", defaultValue: "Set warm light");   icon = "sun.min.fill"
        case (.prepareForArrival, _):
            label = String(localized: "action.tip.prepareHome",       defaultValue: "Prepare home for arrival");                icon = "house.circle"
        case (.secureForDeparture, _):
            label = String(localized: "action.tip.secureOnLeave",     defaultValue: "Turn off lights and devices");         icon = "power"
        case (.reduceConsumption, _):
            label = String(localized: "action.tip.reduceConsumption", defaultValue: "Turn off unused devices");                 icon = "bolt.slash.fill"
        case (.enableEcoMode, _):
            label = String(localized: "action.tip.ecoMode",           defaultValue: "Set a reduced temperature");        icon = "leaf.fill"
        case (.schedulePeakHours, _):
            label = String(localized: "action.tip.peakHours",         defaultValue: "Use devices outside peak hours"); icon = "clock.fill"
        case (.lockAll, _):
            label = String(localized: "action.tip.lockManually",        defaultValue: "Check and lock the doors");             icon = "lock.fill"
        case (.closeGarage, _):
            label = String(localized: "action.tip.closeGarageManually", defaultValue: "Close the garage before leaving");      icon = "garage"
        case (.armNightSecurity, _):
            label = String(localized: "action.tip.armNightManually",    defaultValue: "Check doors and windows"); icon = "moon.zzz.fill"
        case (.armAwaySecurity, _):
            label = String(localized: "action.tip.armAwayManually",     defaultValue: "Check everything before leaving"); icon = "house.fill"
        }
        return AINextAction(label: label, actionType: "tip", iconName: icon)
    }

    /// Backward-compatible wrapper: tip per stanze indoor (default).
    var fallbackTip: AINextAction {
        fallbackTip(for: .indoor) ?? AINextAction(
            label: String(localized: "action.tip.ventilate", defaultValue: "Air out the room"),
            actionType: "tip",
            iconName: "wind"
        )
    }
}
