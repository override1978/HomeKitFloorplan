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
        case .all:             return String(localized: "filter.category.all",            defaultValue: "All")
        case .lights:          return String(localized: "filter.category.lights",         defaultValue: "Lights")
        case .outlets:         return String(localized: "filter.category.outlets",        defaultValue: "Outlets")
        case .climate:         return String(localized: "filter.category.climate",        defaultValue: "Climate")
        case .windowCoverings: return String(localized: "filter.category.windowCoverings",defaultValue: "Blinds")
        case .sensors:         return String(localized: "filter.category.sensors",        defaultValue: "Sensors")
        case .security:        return String(localized: "filter.category.security",       defaultValue: "Security")
        case .cameras:         return String(localized: "filter.category.cameras",        defaultValue: "Cameras")
        case .air:             return String(localized: "filter.category.air",            defaultValue: "Air")
        case .hubs:            return String(localized: "filter.category.hubs",           defaultValue: "Hub")
        case .television:      return String(localized: "filter.category.television",     defaultValue: "TV")
        case .switches:        return String(localized: "filter.category.switches",       defaultValue: "Switch")
        case .buttons:         return String(localized: "filter.category.buttons",        defaultValue: "Buttons")
        case .others:          return String(localized: "filter.category.others",         defaultValue: "Other")
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
            // Service-type first; then fall back to the official HomeKit category.
            let lightbulbUUID = "00000043-0000-1000-8000-0026BB765291"
            let outletUUID    = "00000047-0000-1000-8000-0026BB765291"
            let switchUUID    = "00000049-0000-1000-8000-0026BB765291"
            let fanV2UUID     = "000000B7-0000-1000-8000-0026BB765291"
            let fanV1UUID     = "00000040-0000-1000-8000-0026BB765291"
            let services = onOff.accessory.services
            if isLikelyAirCareAccessory(onOff.accessory) { return .air }
            if services.contains(where: { $0.serviceType == lightbulbUUID }) { return .lights }
            if services.contains(where: { $0.serviceType == outletUUID    }) { return .outlets }
            if services.contains(where: { $0.serviceType == switchUUID    }) { return .switches }
            if services.contains(where: { $0.serviceType == fanV2UUID || $0.serviceType == fanV1UUID }) { return .air }
            return categoryFromHomeKit(onOff.accessory)
        case is WindowCoveringAdapter:       return .windowCoverings
        case is ThermostatAdapter:           return .climate
        case is LegacyThermostatAdapter:     return .climate
        case is SensorAdapter:               return .sensors
        case is SecuritySystemAdapter:       return .security
        case is DoorLockAdapter:             return .security
        case is GarageDoorAdapter:           return .security
        case is CameraAdapter:               return .cameras
        case is AirPurifierAdapter:            return .air
        case is HumidifierAdapter:             return .air
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
    
    private static func isLikelyAirCareAccessory(_ accessory: HMAccessory) -> Bool {
        let humidifierDehumidifierServiceType = "000000BD-0000-1000-8000-0026BB765291"
        if accessory.services.contains(where: { $0.serviceType == humidifierDehumidifierServiceType }) {
            return true
        }
        let name = accessory.name.lowercased()
        let keywords = ["diffusore", "diffuser", "aroma", "humidifier", "umidificatore", "dehumidifier", "deumidificatore"]
        return keywords.contains { name.contains($0) }
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
        case .all:        return String(localized: "filter.state.all",        defaultValue: "All")
        case .on:         return String(localized: "filter.state.on",         defaultValue: "On")
        case .offline:    return String(localized: "filter.state.offline",    defaultValue: "Offline")
        case .lowBattery: return String(localized: "filter.state.lowBattery", defaultValue: "Low Battery")
        case .alarm:      return String(localized: "filter.state.alarm",      defaultValue: "Alarm")
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
