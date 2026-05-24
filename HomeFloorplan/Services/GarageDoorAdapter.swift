import HomeKit
import Observation
import SwiftUI

/// Stato corrente del garage (HAP CurrentDoorState).
enum GarageDoorCurrentState: Int {
    case open = 0
    case closed = 1
    case opening = 2
    case closing = 3
    case stopped = 4
}

/// Stato target (HAP TargetDoorState): solo open/closed.
enum GarageDoorTargetState: Int {
    case open = 0
    case closed = 1
}

/// Adapter per porte garage HomeKit (servizio GarageDoorOpener `00000041-...`).
/// Esempi: Meross, Tailwind, Garadget, Chamberlain via Homebridge.
@MainActor
@Observable
final class GarageDoorAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let currentStateCharacteristic: HMCharacteristic
    private let targetStateCharacteristic: HMCharacteristic
    private let obstructionCharacteristic: HMCharacteristic?
    private let lowBatteryCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        let currentStateUUID = "0000000E-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000032-0000-1000-8000-0026BB765291"
        let obstructionUUID = "00000024-0000-1000-8000-0026BB765291"
        let lowBatteryUUID = "00000079-0000-1000-8000-0026BB765291"
        let garageServiceUUID = "00000041-0000-1000-8000-0026BB765291"
        
        guard let current = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID),
              let target = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }
        
        guard accessory.services.contains(where: { $0.serviceType == garageServiceUUID }) else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.currentStateCharacteristic = current
        self.targetStateCharacteristic = target
        self.obstructionCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: obstructionUUID)
        self.lowBatteryCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: lowBatteryUUID)
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        if obstructionDetected { return "exclamationmark.triangle.fill" }
        switch currentState {
        case .open, .opening:   return "door.garage.open"
        case .closed, .closing: return "door.garage.closed"
        case .stopped:          return "door.garage.closed"
        }
    }
    
    /// "isOn" = aperta o in apertura (marker active)
    var isOn: Bool {
        switch currentState {
        case .open, .opening: return true
        default: return false
        }
    }
    
    /// No quick-toggle dal marker: tap apre DetailView.
    var supportsQuickToggle: Bool { false }
    
    var primaryStatusText: String? {
        if obstructionDetected { return "Ostacolo" }
        switch currentState {
        case .open:    return "Aperto"
        case .closed:  return "Chiuso"
        case .opening: return "Aprendo"
        case .closing: return "Chiudendo"
        case .stopped: return "Fermo"
        }
    }
    
    var markerStyle: MarkerStyle { .controllable }
    
    var visualUrgency: MarkerUrgency {
        if obstructionDetected { return .alarm }
        switch currentState {
        case .stopped: return .alarm        // fermo a metà = problema
        case .open:    return .warning      // aperto = arancione
        case .opening, .closing: return .active   // movimento = giallo
        case .closed:  return .normal
        }
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // No-op: tap deve aprire DetailView.
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(GarageDoorControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state
    
    var currentState: GarageDoorCurrentState {
        let raw = intValue(homeKit.value(for: currentStateCharacteristic) ?? currentStateCharacteristic.value) ?? 1
        return GarageDoorCurrentState(rawValue: raw) ?? .closed
    }
    
    var targetState: GarageDoorTargetState {
        let raw = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 1
        return GarageDoorTargetState(rawValue: raw) ?? .closed
    }
    
    var obstructionDetected: Bool {
        guard let c = obstructionCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i == 1 }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }
    
    /// True se il garage sta operando (motore in movimento o richiesta in volo).
    var isTransitioning: Bool {
        switch currentState {
        case .opening, .closing: return true
        default: return false
        }
    }
    
    var hasLowBattery: Bool {
        guard let c = lowBatteryCharacteristic else { return false }
        return intValue(homeKit.value(for: c) ?? c.value) == 1
    }
    
    // MARK: - Writes
    
    func setOpen(_ open: Bool) async throws {
        let value: Int = open ? 0 : 1  // 0=Open, 1=Closed
        try await homeKit.write(value, to: targetStateCharacteristic)
    }
    
    // MARK: - Helpers
    
    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let u = any as? UInt8 { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
