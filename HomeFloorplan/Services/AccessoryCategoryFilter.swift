import SwiftUI
import HomeKit

/// Categoria per il filtro della AllAccessoriesView.
enum AccessoryCategory: String, CaseIterable, Identifiable {
    case all
    case lights
    case outlets
    case climate
    case windowCoverings
    case sensors
    case security
    case cameras
    case air
    case hubs
    case television
    case switches
    case buttons
    case others

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:             return String(localized: "filter.category.all",            defaultValue: "Tutti")
        case .lights:          return String(localized: "filter.category.lights",         defaultValue: "Luci")
        case .outlets:         return String(localized: "filter.category.outlets",        defaultValue: "Prese")
        case .climate:         return String(localized: "filter.category.climate",        defaultValue: "Clima")
        case .windowCoverings: return String(localized: "filter.category.windowCoverings",defaultValue: "Tende")
        case .sensors:         return String(localized: "filter.category.sensors",        defaultValue: "Sensori")
        case .security:        return String(localized: "filter.category.security",       defaultValue: "Sicurezza")
        case .cameras:         return String(localized: "filter.category.cameras",        defaultValue: "Telecamere")
        case .air:             return String(localized: "filter.category.air",            defaultValue: "Aria")
        case .hubs:            return String(localized: "filter.category.hubs",           defaultValue: "Hub")
        case .television:      return String(localized: "filter.category.television",     defaultValue: "TV")
        case .switches:        return String(localized: "filter.category.switches",       defaultValue: "Switch")
        case .buttons:         return String(localized: "filter.category.buttons",        defaultValue: "Pulsanti")
        case .others:          return String(localized: "filter.category.others",         defaultValue: "Altri")
        }
    }

    var symbolName: String {
        switch self {
        case .all:             return "square.grid.2x2"
        case .lights:          return "lightbulb.fill"
        case .outlets:         return "powerplug.fill"
        case .climate:         return "thermometer"
        case .windowCoverings: return "blinds.horizontal.closed"
        case .sensors:         return "sensor.fill"
        case .security:        return "shield.fill"
        case .cameras:         return "camera.fill"
        case .air:             return "air.purifier"
        case .hubs:            return "wifi.router.fill"
        case .television:      return "tv"
        case .switches:        return "lightswitch.on"
        case .buttons:         return "button.programmable"
        case .others:          return "questionmark.circle"
        }
    }
    
    /// Classifica un accessorio in base al suo adapter.
    @MainActor
    static func classify(adapter: (any AccessoryAdapter)?) -> AccessoryCategory {
        guard let adapter else { return .others }
        switch adapter {
        case is DimmableLightAdapter: return .lights
        case let onOff as OnOffAdapter:
            // Lightbulb → luci; Outlet reale → prese; Switch (NightMode ecc.) → switch
            let lightbulbUUID = "00000043-0000-1000-8000-0026BB765291"
            let outletUUID    = "00000047-0000-1000-8000-0026BB765291"
            let switchUUID    = "00000049-0000-1000-8000-0026BB765291"
            let services = onOff.accessory.services
            if services.contains(where: { $0.serviceType == lightbulbUUID }) { return .lights }
            if services.contains(where: { $0.serviceType == outletUUID    }) { return .outlets }
            if services.contains(where: { $0.serviceType == switchUUID    }) { return .switches }
            return .others
        case is WindowCoveringAdapter:       return .windowCoverings
        case is ThermostatAdapter:           return .climate
        case is LegacyThermostatAdapter:     return .climate
        case is SensorAdapter:               return .sensors
        case is SecuritySystemAdapter:       return .security
        case is DoorLockAdapter:             return .security
        case is GarageDoorAdapter:           return .security
        case is CameraAdapter:               return .cameras
        case is AirPurifierAdapter:            return .air
        case is TelevisionAdapter:             return .television
        case is ProgrammableSwitchAdapter:     return .buttons
        case is MatterDeviceAdapter:           return .others
        case is MultiOutletAdapter:          return .outlets
        default:
            // Fallback: usa la categoria HomeKit ufficiale
            return categoryFromHomeKit(adapter.accessory)
        }
    }
    
    private static func categoryFromHomeKit(_ accessory: HMAccessory) -> AccessoryCategory {
        // UUID HAP standard per le category type (più stabile delle costanti Swift)
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeBridge:           return .hubs
        case HMAccessoryCategoryTypeOutlet:           return .outlets
        case HMAccessoryCategoryTypeSwitch:           return .switches
        case HMAccessoryCategoryTypeLightbulb:        return .lights
        case HMAccessoryCategoryTypeThermostat:       return .climate
        case HMAccessoryCategoryTypeAirConditioner:   return .climate
        case "heater":                                return .climate
        case HMAccessoryCategoryTypeWindowCovering:   return .windowCoverings
        case HMAccessoryCategoryTypeWindow:           return .windowCoverings
        case HMAccessoryCategoryTypeDoor:             return .security
        case HMAccessoryCategoryTypeGarageDoorOpener: return .security
        case "lock":                                  return .security
        case HMAccessoryCategoryTypeSecuritySystem:   return .security
        case HMAccessoryCategoryTypeSensor:           return .sensors
        case HMAccessoryCategoryTypeAirPurifier:      return .air
        case HMAccessoryCategoryTypeFan:              return .air
        case HMAccessoryCategoryTypeIPCamera:         return .cameras
        case HMAccessoryCategoryTypeVideoDoorbell:    return .cameras
        default:                                      return .others
        }
    }
}

/// Filtro di stato dinamico (secondario rispetto a categoria).
enum AccessoryStateFilter: String, CaseIterable, Identifiable {
    case all
    case on
    case offline
    case lowBattery
    case alarm
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .all:        return String(localized: "filter.state.all",        defaultValue: "Tutti")
        case .on:         return String(localized: "filter.state.on",         defaultValue: "Accesi")
        case .offline:    return String(localized: "filter.state.offline",    defaultValue: "Offline")
        case .lowBattery: return String(localized: "filter.state.lowBattery", defaultValue: "Batt. scarica")
        case .alarm:      return String(localized: "filter.state.alarm",      defaultValue: "Allarme")
        }
    }
    
    var symbolName: String {
        switch self {
        case .all:        return "square.grid.2x2"
        case .on:         return "power"
        case .offline:    return "wifi.slash"
        case .lowBattery: return "battery.25percent"
        case .alarm:      return "exclamationmark.triangle.fill"
        }
    }
    
    @MainActor
    func matches(adapter: (any AccessoryAdapter)?, isOffline: Bool) -> Bool {
        guard let adapter else { return self == .all }
        switch self {
        case .all:        return true
        case .on:         return adapter.isOn
        case .offline:    return isOffline
        case .lowBattery: return adapter.batteryInfo?.isLow == true
        case .alarm:      return adapter.visualUrgency == .alarm
        }
    }
}
