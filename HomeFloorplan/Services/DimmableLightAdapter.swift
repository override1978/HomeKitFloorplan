import HomeKit
import Observation
import SwiftUI

/// Adapter per luci dimmerabili HomeKit (es. Vimar IoT, Hue, Lifx).
/// Richiede `HMCharacteristicTypeBrightness`; usa `HMCharacteristicTypePowerState`
/// per on/off (se presente, altrimenti deduce on/off dal valore di brightness).
@MainActor
@Observable
final class DimmableLightAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    private let powerCharacteristic: HMCharacteristic?
    private let brightnessCharacteristic: HMCharacteristic
    private let hueCharacteristic: HMCharacteristic?
    private let saturationCharacteristic: HMCharacteristic?
    private let colorTemperatureCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard !Self.isLikelyAirCareAccessory(accessory) else { return nil }
        
        guard accessory.services.contains(where: { $0.serviceType == HMServiceTypeLightbulb })
                || accessory.category.categoryType == HMAccessoryCategoryTypeLightbulb
        else { return nil }
        
        guard let brightness = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeBrightness
        ) else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.brightnessCharacteristic = brightness
        self.powerCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypePowerState
        )
        self.hueCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeHue
        )
        self.saturationCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeSaturation
        )
        self.colorTemperatureCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeColorTemperature
        )
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        isOn ? "lightbulb.fill" : "lightbulb"
    }
    
    var isOn: Bool {
        if let c = powerCharacteristic {
            let raw = homeKit.value(for: c) ?? c.value
            if let b = raw as? Bool { return b }
            if let n = raw as? NSNumber { return n.boolValue }
            return false
        }
        // Fallback: se non c'è PowerState, usa brightness > 0
        return currentBrightness > 0
    }
    
    var supportsQuickToggle: Bool {
        homeKit.isReachable(accessory)
    }
    
    var primaryStatusText: String? { nil }
    var markerStyle: MarkerStyle { .controllable }
    var markerTint: Color? { isOn ? .yellow : nil }
    var visualUrgency: MarkerUrgency { isOn ? .active : .normal }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        if let power = powerCharacteristic {
            try await homeKit.write(!isOn, to: power)
        } else {
            let newBrightness = currentBrightness > 0 ? 0 : 80
            try await setBrightness(newBrightness)
        }
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(DimmableLightControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state for control views
    
    var supportsFloorplanPlacement: Bool { true }
    
    /// Luminosità corrente in percentuale (0-100).
    var currentBrightness: Int {
        let raw = homeKit.value(for: brightnessCharacteristic) ?? brightnessCharacteristic.value
        return Self.intValue(raw) ?? 0
    }

    var supportsColor: Bool {
        hueCharacteristic != nil && saturationCharacteristic != nil
    }

    var supportsColorTemperature: Bool {
        colorTemperatureCharacteristic != nil
    }

    var currentHue: Double {
        guard let hueCharacteristic else { return 45 }
        let raw = homeKit.value(for: hueCharacteristic) ?? hueCharacteristic.value
        return Self.doubleValue(raw) ?? 45
    }

    var currentSaturation: Double {
        guard let saturationCharacteristic else { return 0 }
        let raw = homeKit.value(for: saturationCharacteristic) ?? saturationCharacteristic.value
        return Self.doubleValue(raw) ?? 0
    }

    /// HomeKit color temperature is expressed in mireds. Lower values are cooler.
    var currentColorTemperature: Int {
        guard let colorTemperatureCharacteristic else { return 250 }
        let raw = homeKit.value(for: colorTemperatureCharacteristic) ?? colorTemperatureCharacteristic.value
        return Self.intValue(raw) ?? 250
    }

    var colorTemperatureRange: ClosedRange<Int> {
        let minValue = metadataInt(colorTemperatureCharacteristic?.metadata?.minimumValue) ?? 140
        let maxValue = metadataInt(colorTemperatureCharacteristic?.metadata?.maximumValue) ?? 500
        return minValue...max(maxValue, minValue)
    }
    
    /// Scrive la luminosità (0-100).
    func setBrightness(_ value: Int) async throws {
        let clamped = max(0, min(100, value))
        try await homeKit.write(clamped, to: brightnessCharacteristic)
    }

    func setColor(hue: Double, saturation: Double) async throws {
        guard let hueCharacteristic, let saturationCharacteristic else { return }
        try await homeKit.write(max(0, min(360, hue)), to: hueCharacteristic)
        try await homeKit.write(max(0, min(100, saturation)), to: saturationCharacteristic)
    }

    func setColorTemperature(_ value: Int) async throws {
        guard let colorTemperatureCharacteristic else { return }
        let range = colorTemperatureRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        try await homeKit.write(clamped, to: colorTemperatureCharacteristic)
    }
    
    // MARK: - Private helpers
    
    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let u = raw as? UInt8 { return Int(u) }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let f = raw as? Float { return Double(f) }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private func metadataInt(_ value: NSNumber?) -> Int? {
        value?.intValue
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
