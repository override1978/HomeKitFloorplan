import HomeKit
import Observation
import SwiftUI

/// Adapter for HomeKit fans that expose a rotation speed characteristic.
@MainActor
@Observable
final class FanAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    private let powerCharacteristic: HMCharacteristic?
    private let rotationSpeedCharacteristic: HMCharacteristic

    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard let rotationSpeed = AccessoryAdapterFactory.findCharacteristic(
            in: accessory,
            type: HMCharacteristicTypeRotationSpeed
        ) else { return nil }

        guard Self.isFanLike(accessory) else { return nil }

        self.accessory = accessory
        self.homeKit = homeKit
        self.rotationSpeedCharacteristic = rotationSpeed
        self.powerCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeActive)
            ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
    }

    var iconName: String {
        isOn ? "fan.fill" : "fan"
    }

    var isOn: Bool {
        guard let powerCharacteristic else { return currentSpeed > 0 }
        let raw = homeKit.value(for: powerCharacteristic) ?? powerCharacteristic.value
        if let bool = raw as? Bool { return bool }
        if let int = raw as? Int { return int == 1 }
        if let uint = raw as? UInt8 { return uint == 1 }
        if let number = raw as? NSNumber { return number.intValue == 1 }
        return false
    }

    var supportsQuickToggle: Bool {
        homeKit.isReachable(accessory) && powerCharacteristic != nil
    }

    var primaryStatusText: String? { nil }
    var markerStyle: MarkerStyle { .controllable }
    var markerTint: Color? { isOn ? .cyan : nil }
    var visualUrgency: MarkerUrgency { isOn ? .active : .normal }
    var supportsFloorplanPlacement: Bool { true }

    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }

    var currentSpeed: Int {
        let raw = homeKit.value(for: rotationSpeedCharacteristic) ?? rotationSpeedCharacteristic.value
        return Self.intValue(raw) ?? 0
    }

    var speedRange: ClosedRange<Int> {
        let minValue = Self.intValue(rotationSpeedCharacteristic.metadata?.minimumValue) ?? 0
        let maxValue = Self.intValue(rotationSpeedCharacteristic.metadata?.maximumValue) ?? 100
        return minValue...max(maxValue, minValue)
    }

    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(FanControl(adapter: self))
    }

    func performQuickToggle(via homeKit: HomeKitService) async throws {
        guard let powerCharacteristic else { return }
        let newValue: Any
        switch powerCharacteristic.characteristicType {
        case HMCharacteristicTypeActive:
            newValue = isOn ? 0 : 1
        case HMCharacteristicTypePowerState:
            newValue = !isOn
        default:
            newValue = !isOn
        }
        try await homeKit.write(newValue, to: powerCharacteristic)
    }

    func setSpeed(_ value: Int) async throws {
        let range = speedRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        if !isOn && clamped > 0, powerCharacteristic != nil {
            try await performQuickToggle(via: homeKit)
        }
        try await homeKit.write(Double(clamped), to: rotationSpeedCharacteristic)
    }

    private static func isFanLike(_ accessory: HMAccessory) -> Bool {
        if accessory.category.categoryType == HMAccessoryCategoryTypeFan {
            return true
        }
        if accessory.services.contains(where: { $0.serviceType == HMServiceTypeFan }) {
            return true
        }

        let searchableName = ([accessory.name] + accessory.services.map(\.name))
            .joined(separator: " ")
            .lowercased()
        return searchableName.contains("fan") || searchableName.contains("ventola") || searchableName.contains("ventilatore")
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let uint = raw as? UInt8 { return Int(uint) }
        if let double = raw as? Double { return Int(double.rounded()) }
        if let float = raw as? Float { return Int(float.rounded()) }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }
}
