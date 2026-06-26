import HomeKit

// MARK: - AccessoryCategorizer

/// Shared utility that maps an HMAccessory to a category string.
///
/// Used by both AmbientalAIService (payload builder) and ActionResolver (device selection)
/// to guarantee identical category detection logic in both places.
///
/// Category priority chain (mirrors original AmbientalAIService.describeAccessory()):
///   camera > television > airPurifier > thermostat > valve > windowCovering(category)
///   > colorLight > dimmableLight > sceneController > windowCovering(chars)
///   > fan | outlet | switch | airConditioner | onOff > sensor
enum AccessoryCategorizer {

    // MARK: - HAP Service UUIDs

    private static let cameraServiceType         = "00000111-0000-1000-8000-0026BB765291"
    private static let purifierServiceType       = "000000BB-0000-1000-8000-0026BB765291"
    private static let humidifierDehumidifierServiceType = "000000BD-0000-1000-8000-0026BB765291"
    private static let heaterCoolerType          = "000000BC-0000-1000-8000-0026BB765291"
    private static let thermostatType            = "0000004A-0000-1000-8000-0026BB765291"
    private static let irrigationSystemType      = "00000081-0000-1000-8000-0026BB765291"
    private static let valveType                 = "000000D0-0000-1000-8000-0026BB765291"
    private static let windowCoveringServiceType     = "0000008C-0000-1000-8000-0026BB765291"
    private static let televisionServiceType         = TelevisionAdapter.televisionServiceUUID
    /// HAP UUID for the Programmable Switch Event characteristic (stateless button presses).
    private static let programmableSwitchEventType   = "00000073-0000-1000-8000-0026BB765291"
    /// HAP LockMechanism service UUID.
    private static let lockMechanismServiceType      = "00000045-0000-1000-8000-0026BB765291"
    /// HAP GarageDoorOpener service UUID.
    private static let garageDoorServiceType         = "00000041-0000-1000-8000-0026BB765291"

    // MARK: - Public API

    /// Returns the category string for the given accessory.
    static func categorize(_ accessory: HMAccessory) -> String {
        let services = accessory.services

        func hasChar(_ type: String) -> Bool {
            services.flatMap(\.characteristics).contains { $0.characteristicType == type }
        }

        // Camera (IP camera o videocitofono)
        let isCameraCategory = accessory.category.categoryType == HMAccessoryCategoryTypeIPCamera
            || accessory.category.categoryType == HMAccessoryCategoryTypeVideoDoorbell
        if isCameraCategory || services.contains(where: { $0.serviceType == cameraServiceType }) {
            return "camera"
        }

        // Television
        if services.contains(where: { $0.serviceType == televisionServiceType }) {
            return "television"
        }

        // Air Purifier
        if services.contains(where: { $0.serviceType == purifierServiceType }) {
            return "airPurifier"
        }
        
        // Diffusers/humidifiers may expose a Lightbulb service for LEDs; classify by primary function first.
        if isLikelyAirCareAccessory(accessory) {
            return "humidifier"
        }

        // Thermostat / HeaterCooler
        if services.contains(where: { $0.serviceType == heaterCoolerType || $0.serviceType == thermostatType }) {
            return "thermostat"
        }

        // Valve / irrigation controller
        if services.contains(where: { $0.serviceType == valveType || $0.serviceType == irrigationSystemType }) {
            return "valve"
        }

        // Window Covering — category type or HAP service UUID, whichever fires first
        if accessory.category.categoryType == HMAccessoryCategoryTypeWindowCovering
            || services.contains(where: { $0.serviceType == windowCoveringServiceType }) {
            return "windowCovering"
        }

        // Color Light — dimmable + a color channel (hue, saturation, or color temperature)
        if hasChar(HMCharacteristicTypeBrightness) &&
           (hasChar(HMCharacteristicTypeHue) ||
            hasChar(HMCharacteristicTypeSaturation) ||
            hasChar(HMCharacteristicTypeColorTemperature)) {
            return "colorLight"
        }

        // Dimmable Light
        if hasChar(HMCharacteristicTypeBrightness) {
            return "dimmableLight"
        }

        // Window Covering / Blind — characteristic-based fallback
        if hasChar(HMCharacteristicTypeCurrentPosition) && hasChar(HMCharacteristicTypeTargetPosition) {
            return "windowCovering"
        }
        if hasChar(HMCharacteristicTypeTargetPosition) {
            return "windowCovering"
        }

        // Scene Controller (programmable button with multi-press events)
        if hasChar(Self.programmableSwitchEventType) {
            return "sceneController"
        }

        // Door Lock
        if services.contains(where: { $0.serviceType == lockMechanismServiceType }) {
            return "doorLock"
        }

        // Garage Door
        if services.contains(where: { $0.serviceType == garageDoorServiceType }) {
            return "garageDoor"
        }

        // Generic On/Off — distinguish by HMAccessoryCategory
        if hasChar(HMCharacteristicTypePowerState) || hasChar(HMCharacteristicTypeActive) {
            let allReadOnly = services.flatMap(\.characteristics).allSatisfy {
                $0.properties.contains(HMCharacteristicPropertyReadable) &&
                !$0.properties.contains(HMCharacteristicPropertyWritable)
            }
            if allReadOnly { return "sensor" }

            switch accessory.category.categoryType {
            case HMAccessoryCategoryTypeFan:            return "fan"
            case HMAccessoryCategoryTypeOutlet:         return "outlet"
            case HMAccessoryCategoryTypeSwitch:         return "switch"
            case HMAccessoryCategoryTypeAirConditioner: return "airConditioner"
            default:                                    return "onOff"
            }
        }

        return "sensor"
    }
    
    private static func isLikelyAirCareAccessory(_ accessory: HMAccessory) -> Bool {
        if accessory.services.contains(where: { $0.serviceType == humidifierDehumidifierServiceType }) {
            return true
        }
        let name = accessory.name.lowercased()
        let keywords = ["diffusore", "diffuser", "aroma", "humidifier", "umidificatore", "dehumidifier", "deumidificatore"]
        return keywords.contains { name.contains($0) }
    }
}
