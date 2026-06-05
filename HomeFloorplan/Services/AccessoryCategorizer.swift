import HomeKit

// MARK: - AccessoryCategorizer

/// Shared utility that maps an HMAccessory to a category string.
///
/// Used by both AmbientalAIService (payload builder) and ActionResolver (device selection)
/// to guarantee identical category detection logic in both places.
///
/// Category priority chain (mirrors original AmbientalAIService.describeAccessory()):
///   camera > airPurifier > thermostat > valve > dimmableLight > windowCovering
///   > fan | outlet | switch | airConditioner | onOff > sensor
enum AccessoryCategorizer {

    // MARK: - HAP Service UUIDs

    private static let cameraServiceType    = "00000111-0000-1000-8000-0026BB765291"
    private static let purifierServiceType  = "000000BB-0000-1000-8000-0026BB765291"
    private static let heaterCoolerType     = "000000BC-0000-1000-8000-0026BB765291"
    private static let thermostatType       = "0000004A-0000-1000-8000-0026BB765291"
    private static let valveType            = "00000081-0000-1000-8000-0026BB765291"

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

        // Air Purifier
        if services.contains(where: { $0.serviceType == purifierServiceType }) {
            return "airPurifier"
        }

        // Thermostat / HeaterCooler
        if services.contains(where: { $0.serviceType == heaterCoolerType || $0.serviceType == thermostatType }) {
            return "thermostat"
        }

        // Valve (TRV)
        if services.contains(where: { $0.serviceType == valveType }) {
            return "valve"
        }

        // Dimmable Light
        if hasChar(HMCharacteristicTypeBrightness) {
            return "dimmableLight"
        }

        // Window Covering / Blind
        if hasChar(HMCharacteristicTypeCurrentPosition) && hasChar(HMCharacteristicTypeTargetPosition) {
            return "windowCovering"
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
}
