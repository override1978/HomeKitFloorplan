import HomeKit
import Observation
import SwiftUI

/// Adapter per accessori semplici on/off: luci semplici, prese, switch, ventilatori.
/// Tap rapido = toggle dello stato.
@MainActor
@Observable
final class OnOffAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    private let powerCharacteristic: HMCharacteristic?
    
    init(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
        // Preferisce PowerState, fallback su Active
        self.powerCharacteristic =
            AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
            ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeActive)
    }
    
    var markerStyle: MarkerStyle { .controllable }

    var visualUrgency: MarkerUrgency {
        isOn ? .active : .normal
    }
    
    var iconName: String {
        // 0) Robot vacuum: spesso si dichiara come Switch/Outlet/Other,
        //    quindi rileviamo dal nome dell'accessorio.
        if isLikelyRobotVacuum {
            return isOn ? "house.fill" : "house"  // fallback se "vacuum.cleaner" non esiste
        }
        
        // 1) Service-type first: più affidabile della categoria.
        if hasService(of: HMServiceTypeLightbulb) {
            return isOn ? "lightbulb.fill" : "lightbulb"
        }
        if hasService(of: HMServiceTypeOutlet) {
            return isOn ? "powerplug.fill" : "powerplug"
        }
        if hasService(of: HMServiceTypeFan) {
            return isOn ? "fan.fill" : "fan"
        }
        if hasService(of: HMServiceTypeSwitch) {
            return isOn ? "lightswitch.on.fill" : "lightswitch.off"
        }
        
        // 2) Fallback: categoria
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeLightbulb:
            return isOn ? "lightbulb.fill" : "lightbulb"
        case HMAccessoryCategoryTypeOutlet:
            return isOn ? "powerplug.fill" : "powerplug"
        case HMAccessoryCategoryTypeSwitch:
            return isOn ? "lightswitch.on.fill" : "lightswitch.off"
        case HMAccessoryCategoryTypeFan:
            return isOn ? "fan.fill" : "fan"
        case HMAccessoryCategoryTypeAirPurifier:
            return "air.purifier.fill"
        default:
            return isOn ? "circle.fill" : "circle"
        }
    }

    private var isLikelyRobotVacuum: Bool {
        let name = accessory.name.lowercased()
        let keywords = ["vacuum", "robot", "roomba", "roborock", "aspirapolvere", "deebot"]
        return keywords.contains { name.contains($0) }
    }

    private func hasService(of type: String) -> Bool {
        accessory.services.contains { $0.serviceType == type }
    }
    
    var isOn: Bool {
        guard let c = powerCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i == 1 }
        if let i = raw as? UInt8 { return i == 1 }
        if let n = raw as? NSNumber { return n.intValue == 1 }
        return false
    }
    
    var supportsQuickToggle: Bool {
        powerCharacteristic != nil
    }
    
    var primaryStatusText: String? {
        nil
    }
    
    var supportsFloorplanPlacement: Bool { true }
    // MARK: - Control section (Apple Home style)

    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        guard powerCharacteristic != nil else { return nil }
        return AnyView(OnOffControlButton(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        guard let c = powerCharacteristic else { return }
        let currentlyOn = isOn
        let newValue: Any
        switch c.characteristicType {
        case HMCharacteristicTypePowerState:
            newValue = !currentlyOn
        case HMCharacteristicTypeActive:
            newValue = currentlyOn ? 0 : 1
        default:
            newValue = !currentlyOn
        }
        try await homeKit.write(newValue, to: c)
    }
}
