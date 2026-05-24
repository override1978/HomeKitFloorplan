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
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard let brightness = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeBrightness
        ) else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.brightnessCharacteristic = brightness
        self.powerCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypePowerState
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
        (powerCharacteristic != nil) && accessory.isReachable
    }
    
    var primaryStatusText: String? { nil }
    var markerStyle: MarkerStyle { .controllable }
    var visualUrgency: MarkerUrgency { isOn ? .active : .normal }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        guard let power = powerCharacteristic else { return }
        try await homeKit.write(!isOn, to: power)
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
    
    /// Luminosità corrente in percentuale (0-100).
    var currentBrightness: Int {
        let raw = homeKit.value(for: brightnessCharacteristic) ?? brightnessCharacteristic.value
        return Self.intValue(raw) ?? 0
    }
    
    /// Scrive la luminosità (0-100).
    func setBrightness(_ value: Int) async throws {
        let clamped = max(0, min(100, value))
        try await homeKit.write(clamped, to: brightnessCharacteristic)
    }
    
    // MARK: - Private helpers
    
    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let u = raw as? UInt8 { return Int(u) }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        return nil
    }
}
