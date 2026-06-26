import HomeKit
import Observation
import SwiftUI

enum ValveType: Int {
    case generic = 0
    case irrigation = 1
    case showerHead = 2
    case waterFaucet = 3

    var localizedLabel: String {
        switch self {
        case .generic:
            return String(localized: "valve.type.generic", defaultValue: "Generic")
        case .irrigation:
            return String(localized: "valve.type.irrigation", defaultValue: "Irrigation")
        case .showerHead:
            return String(localized: "valve.type.showerHead", defaultValue: "Shower")
        case .waterFaucet:
            return String(localized: "valve.type.waterFaucet", defaultValue: "Faucet")
        }
    }

    var iconName: String {
        switch self {
        case .generic: return "spigot.fill"
        case .irrigation: return "drop.fill"
        case .showerHead: return "shower.fill"
        case .waterFaucet: return "spigot.fill"
        }
    }
}

/// Adapter for HomeKit Valve service (`000000D0`): irrigation, faucets, showers and generic valves.
@MainActor
@Observable
final class ValveAdapter: AccessoryAdapter {
    static let serviceType = "000000D0-0000-1000-8000-0026BB765291"

    private static let activeType = "000000B0-0000-1000-8000-0026BB765291"
    private static let inUseType = "000000D2-0000-1000-8000-0026BB765291"
    private static let setDurationType = "000000D3-0000-1000-8000-0026BB765291"
    private static let remainingDurationType = "000000D4-0000-1000-8000-0026BB765291"
    private static let valveTypeType = "000000D5-0000-1000-8000-0026BB765291"

    let accessory: HMAccessory
    private let homeKit: HomeKitService
    private let activeCharacteristic: HMCharacteristic
    private let inUseCharacteristic: HMCharacteristic?
    private let valveTypeCharacteristic: HMCharacteristic?
    private let setDurationCharacteristic: HMCharacteristic?
    private let remainingDurationCharacteristic: HMCharacteristic?

    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard accessory.services.contains(where: { $0.serviceType == Self.serviceType }),
              let active = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.activeType) else {
            return nil
        }

        self.accessory = accessory
        self.homeKit = homeKit
        self.activeCharacteristic = active
        self.inUseCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.inUseType)
        self.valveTypeCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.valveTypeType)
        self.setDurationCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.setDurationType)
        self.remainingDurationCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.remainingDurationType)
    }

    var iconName: String {
        valveType.iconName
    }

    var isOn: Bool {
        intValue(homeKit.value(for: activeCharacteristic) ?? activeCharacteristic.value) == 1
    }

    var supportsQuickToggle: Bool {
        homeKit.isReachable(accessory)
    }

    var primaryStatusText: String? {
        if isInUse { return String(localized: "valve.status.inUse", defaultValue: "In use") }
        return isOn
            ? String(localized: "valve.status.open", defaultValue: "Open")
            : String(localized: "valve.status.closed", defaultValue: "Closed")
    }

    var markerStyle: MarkerStyle { .controllable }
    var visualUrgency: MarkerUrgency { isOn || isInUse ? .active : .normal }
    var markerTint: Color? { isOn || isInUse ? .blue : nil }
    var supportsFloorplanPlacement: Bool { true }

    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }

    var isInUse: Bool {
        guard let inUseCharacteristic else { return false }
        return intValue(homeKit.value(for: inUseCharacteristic) ?? inUseCharacteristic.value) == 1
    }

    var valveType: ValveType {
        guard let valveTypeCharacteristic,
              let raw = intValue(homeKit.value(for: valveTypeCharacteristic) ?? valveTypeCharacteristic.value) else {
            return .generic
        }
        return ValveType(rawValue: raw) ?? .generic
    }

    var setDurationSeconds: Int? {
        guard let setDurationCharacteristic else { return nil }
        return intValue(homeKit.value(for: setDurationCharacteristic) ?? setDurationCharacteristic.value)
    }

    var remainingDurationSeconds: Int? {
        guard let remainingDurationCharacteristic else { return nil }
        return intValue(homeKit.value(for: remainingDurationCharacteristic) ?? remainingDurationCharacteristic.value)
    }

    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(ValveControl(adapter: self))
    }

    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await setActive(!isOn)
    }

    func setActive(_ active: Bool) async throws {
        try await homeKit.write(active ? 1 : 0, to: activeCharacteristic)
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let uint = raw as? UInt8 { return Int(uint) }
        if let uint32 = raw as? UInt32 { return Int(uint32) }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }
}
