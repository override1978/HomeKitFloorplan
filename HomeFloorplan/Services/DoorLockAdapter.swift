import HomeKit
import Observation
import SwiftUI

/// Stato corrente della serratura (HAP LockCurrentState).
enum DoorLockCurrentState: Int {
    case unsecured = 0
    case secured = 1
    case jammed = 2
    case unknown = 3
}

/// Stato target (HAP LockTargetState): solo unsecured/secured.
enum DoorLockTargetState: Int {
    case unsecured = 0
    case secured = 1
}

/// Adapter per serrature HomeKit (servizio LockMechanism `00000045-...`).
/// Esempi: Yale, Nuki, August, Aqara Lock, Bticino via Homebridge.
@MainActor
@Observable
final class DoorLockAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let currentStateCharacteristic: HMCharacteristic
    private let targetStateCharacteristic: HMCharacteristic
    private let lowBatteryCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        let currentStateUUID = "0000001D-0000-1000-8000-0026BB765291"
        let targetStateUUID = "0000001E-0000-1000-8000-0026BB765291"
        let lowBatteryUUID = "00000079-0000-1000-8000-0026BB765291"
        let lockServiceUUID = "00000045-0000-1000-8000-0026BB765291"
        
        guard let current = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID),
              let target = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }
        
        // Verifica servizio LockMechanism presente
        guard accessory.services.contains(where: { $0.serviceType == lockServiceUUID }) else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.currentStateCharacteristic = current
        self.targetStateCharacteristic = target
        self.lowBatteryCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: lowBatteryUUID)
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        switch currentState {
        case .jammed:    return "lock.trianglebadge.exclamationmark.fill"
        case .unsecured: return "lock.open.fill"
        case .secured:   return "lock.fill"
        case .unknown:   return "lock.fill"
        }
    }
    
    /// "isOn" = aperta (visualizza il marker come active/giallo)
    var isOn: Bool {
        currentState == .unsecured
    }
    
    /// No quick-toggle dal marker: tap = apre DetailView, scelta esplicita lì.
    var supportsQuickToggle: Bool { false }
    
    var primaryStatusText: String? {
        switch currentState {
        case .jammed:    return "Bloccata"
        case .unsecured: return "Aperta"
        case .secured:   return "Chiusa"
        case .unknown:   return nil
        }
    }
    
    var markerStyle: MarkerStyle { .controllable }
    
    var visualUrgency: MarkerUrgency {
        switch currentState {
        case .jammed:    return .alarm
        case .unsecured: return .warning
        default:         return .normal
        }
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // No-op: tap deve aprire DetailView.
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(DoorLockControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state
    
    var currentState: DoorLockCurrentState {
        let raw = intValue(homeKit.value(for: currentStateCharacteristic) ?? currentStateCharacteristic.value) ?? 3
        return DoorLockCurrentState(rawValue: raw) ?? .unknown
    }
    
    var targetState: DoorLockTargetState {
        let raw = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 1
        return DoorLockTargetState(rawValue: raw) ?? .secured
    }
    
    /// True quando l'utente ha richiesto un cambio e il sistema non ha ancora confermato.
    /// La serratura sta operando fisicamente (motore in movimento).
    var isTransitioning: Bool {
        switch (currentState, targetState) {
        case (.unsecured, .secured): return true  // sta chiudendo
        case (.secured, .unsecured): return true  // sta aprendo
        default: return false
        }
    }
    
    var hasLowBattery: Bool {
        guard let c = lowBatteryCharacteristic else { return false }
        return intValue(homeKit.value(for: c) ?? c.value) == 1
    }
    
    // MARK: - Writes
    
    func setLocked(_ locked: Bool) async throws {
        let value: Int = locked ? 1 : 0
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
