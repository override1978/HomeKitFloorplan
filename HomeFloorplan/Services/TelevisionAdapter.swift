import HomeKit
import Observation
import SwiftUI

// MARK: - TVInputSource

struct TVInputSource: Identifiable {
    let id: Int
    let name: String
    let inputType: Int
    let isVisible: Bool

    var symbolName: String {
        switch inputType {
        case 1:  return "house.fill"
        case 2:  return "antenna.radiowaves.left.and.right"
        case 3:  return "cable.connector"
        case 8:  return "airplayvideo"
        case 9:  return "externaldrive"
        case 10: return "app.fill"
        default: return "display"
        }
    }
}

// MARK: - TelevisionAdapter

/// Adapter per televisori HomeKit (servizio Television `000000D8-...`).
/// Gestisce: accensione/spegnimento, selezione ingresso, controllo volume e muto.
@MainActor
@Observable
final class TelevisionAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService

    private let activeCharacteristic: HMCharacteristic
    private let activeIdentifierCharacteristic: HMCharacteristic?
    private let muteCharacteristic: HMCharacteristic?
    private let volumeSelectorCharacteristic: HMCharacteristic?
    private let inputSourceServices: [HMService]

    // MARK: - UUIDs HAP

    static let televisionServiceUUID  = "000000D8-0000-1000-8000-0026BB765291"
    static let inputSourceServiceUUID = "000000D9-0000-1000-8000-0026BB765291"
    private static let speakerServiceUUID    = "00000113-0000-1000-8000-0026BB765291"

    private static let activeUUID            = "000000B0-0000-1000-8000-0026BB765291"
    private static let activeIdentifierUUID  = "000000E7-0000-1000-8000-0026BB765291"
    private static let muteUUID              = "0000011A-0000-1000-8000-0026BB765291"
    private static let volumeSelectorUUID    = "000000EA-0000-1000-8000-0026BB765291"
    private static let identifierUUID        = "000000E6-0000-1000-8000-0026BB765291"
    private static let configuredNameUUID    = "000000E3-0000-1000-8000-0026BB765291"
    private static let nameUUID              = "00000023-0000-1000-8000-0026BB765291"
    private static let inputSourceTypeUUID   = "000000DB-0000-1000-8000-0026BB765291"
    private static let currentVisibilityUUID = "00000135-0000-1000-8000-0026BB765291"

    // MARK: - Init

    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard accessory.services.contains(where: { $0.serviceType == Self.televisionServiceUUID }) else {
            return nil
        }
        let tvService = accessory.services.first { $0.serviceType == Self.televisionServiceUUID }
        guard let active = tvService?.characteristics.first(where: { $0.characteristicType == Self.activeUUID })
                ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: Self.activeUUID)
        else { return nil }

        self.accessory = accessory
        self.homeKit = homeKit
        self.activeCharacteristic = active
        self.activeIdentifierCharacteristic = tvService?.characteristics.first {
            $0.characteristicType == Self.activeIdentifierUUID
        }

        let speakerService = accessory.services.first { $0.serviceType == Self.speakerServiceUUID }
        self.muteCharacteristic = speakerService?.characteristics.first {
            $0.characteristicType == Self.muteUUID
        }
        self.volumeSelectorCharacteristic = speakerService?.characteristics.first {
            $0.characteristicType == Self.volumeSelectorUUID
        }

        self.inputSourceServices = accessory.services.filter {
            $0.serviceType == Self.inputSourceServiceUUID
        }
    }

    // MARK: - AccessoryAdapter

    var iconName: String { isOn ? "tv.fill" : "tv" }

    var isOn: Bool {
        intValue(homeKit.value(for: activeCharacteristic) ?? activeCharacteristic.value) == 1
    }

    var supportsQuickToggle: Bool { true }
    var markerStyle: MarkerStyle { .controllable }
    var markerTint: Color? { isOn ? .purple : nil }
    var visualUrgency: MarkerUrgency { isOn ? .active : .normal }
    var supportsFloorplanPlacement: Bool { true }
    var batteryInfo: BatteryInfo? { nil }

    var primaryStatusText: String? {
        guard isOn else { return nil }
        return activeInputSource?.name
    }

    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await homeKit.write(isOn ? 0 : 1, to: activeCharacteristic)
    }

    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(TelevisionControl(adapter: self))
    }

    // MARK: - Public computed state

    var activeIdentifier: Int {
        guard let c = activeIdentifierCharacteristic else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }

    var inputSources: [TVInputSource] {
        inputSourceServices.compactMap { service in
            let chars = service.characteristics
            guard let idChar = chars.first(where: { $0.characteristicType == Self.identifierUUID }),
                  let identifier = intValue(homeKit.value(for: idChar) ?? idChar.value)
            else { return nil }

            return TVInputSource(
                id: identifier,
                name: resolvedName(from: chars),
                inputType: typeValue(from: chars),
                isVisible: visibilityValue(from: chars)
            )
        }
        .filter { $0.isVisible }
        .sorted { $0.id < $1.id }
    }

    var activeInputSource: TVInputSource? {
        let id = activeIdentifier
        return inputSources.first { $0.id == id }
    }

    var hasSpeaker: Bool { muteCharacteristic != nil || volumeSelectorCharacteristic != nil }
    var supportsMute: Bool { muteCharacteristic != nil }
    var supportsVolumeSelector: Bool { volumeSelectorCharacteristic != nil }

    var isMuted: Bool {
        guard let c = muteCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    // MARK: - Writes

    func setActive(_ on: Bool) async throws {
        try await homeKit.write(on ? 1 : 0, to: activeCharacteristic)
    }

    func setInputSource(_ source: TVInputSource) async throws {
        guard let c = activeIdentifierCharacteristic else { return }
        try await homeKit.write(source.id, to: c)
    }

    func setMute(_ muted: Bool) async throws {
        guard let c = muteCharacteristic else { return }
        try await homeKit.write(muted, to: c)
    }

    /// VolumeSelector: 0 = volume su, 1 = volume giù
    func sendVolumeUp() async throws {
        guard let c = volumeSelectorCharacteristic else { return }
        try await homeKit.write(0, to: c)
    }

    func sendVolumeDown() async throws {
        guard let c = volumeSelectorCharacteristic else { return }
        try await homeKit.write(1, to: c)
    }

    // MARK: - Helpers

    private func resolvedName(from chars: [HMCharacteristic]) -> String {
        if let cn = chars.first(where: { $0.characteristicType == Self.configuredNameUUID }),
           let v = (homeKit.value(for: cn) ?? cn.value) as? String, !v.isEmpty {
            return v
        }
        if let fn = chars.first(where: { $0.characteristicType == Self.nameUUID }),
           let v = (homeKit.value(for: fn) ?? fn.value) as? String, !v.isEmpty {
            return v
        }
        return "Input"
    }

    private func typeValue(from chars: [HMCharacteristic]) -> Int {
        guard let c = chars.first(where: { $0.characteristicType == Self.inputSourceTypeUUID }) else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }

    private func visibilityValue(from chars: [HMCharacteristic]) -> Bool {
        guard let c = chars.first(where: { $0.characteristicType == Self.currentVisibilityUUID }) else { return true }
        return intValue(homeKit.value(for: c) ?? c.value) == 0
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int      { return i }
        if let u = any as? UInt8    { return Int(u) }
        if let u = any as? UInt32   { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
