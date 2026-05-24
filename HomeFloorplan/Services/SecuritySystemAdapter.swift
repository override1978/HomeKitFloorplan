import HomeKit
import Observation
import SwiftUI

/// Modalità del sistema di sicurezza (HAP TargetSecuritySystemState).
enum SecurityMode: Int, CaseIterable, Identifiable {
    case stay = 0    // Inserito Casa (parziale, perimetrale)
    case away = 1    // Inserito Fuori (totale)
    case night = 2   // Inserito Notte (perimetrale + zone notte)
    case disarm = 3  // Disinserito
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .stay:   return "Casa"
        case .away:   return "Fuori"
        case .night:  return "Notte"
        case .disarm: return "Disinserito"
        }
    }
    
    var symbolName: String {
        switch self {
        case .stay:   return "house.fill"
        case .away:   return "figure.walk.departure"
        case .night:  return "moon.fill"
        case .disarm: return "lock.open.fill"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .stay:   return .orange
        case .away:   return .red
        case .night:  return .purple
        case .disarm: return .green
        }
    }
}

/// Stato corrente del sistema (HAP CurrentSecuritySystemState).
/// Include il valore aggiuntivo `triggered` (= allarme in corso).
enum SecurityCurrentState: Int {
    case stayArmed = 0
    case awayArmed = 1
    case nightArmed = 2
    case disarmed = 3
    case triggered = 4
}

/// Adapter per sistemi di sicurezza HomeKit (servizio SecuritySystem `0000007E-...`).
/// Esempi: Aqara Hub, Verisure, Bticino HomeKit-enabled, Yale, antifurti via Homebridge.
@MainActor
@Observable
final class SecuritySystemAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let currentStateCharacteristic: HMCharacteristic
    private let targetStateCharacteristic: HMCharacteristic
    private let nameCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        let currentStateUUID = "00000066-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000067-0000-1000-8000-0026BB765291"
        let nameUUID = "00000023-0000-1000-8000-0026BB765291"
        
        guard let current = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID),
              let target = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }
        
        // Verifica che ci sia un servizio SecuritySystem (non basta avere le characteristic)
        let securitySystemServiceType = "0000007E-0000-1000-8000-0026BB765291"
        let hasSecurityService = accessory.services.contains { $0.serviceType == securitySystemServiceType }
        guard hasSecurityService else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.currentStateCharacteristic = current
        self.targetStateCharacteristic = target
        // Il nome del servizio (se presente) sarà usato per il display
        let securityService = accessory.services.first { $0.serviceType == securitySystemServiceType }
        self.nameCharacteristic = securityService?.characteristics.first { $0.characteristicType == nameUUID }
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        if isTriggered { return "exclamationmark.shield.fill" }
        switch currentMode {
        case .stay:   return "shield.lefthalf.filled"
        case .away:   return "shield.fill"
        case .night:  return "shield.lefthalf.filled"
        case .disarm: return "shield.slash"
        }
    }
    
    /// Per il marker, "isOn" indica un sistema armato (qualsiasi modalità tranne Disarm).
    var isOn: Bool {
        currentMode != .disarm
    }
    
    /// Per la sicurezza disabilitiamo il quick-toggle: l'utente DEVE aprire DetailView.
    var supportsQuickToggle: Bool { false }
    
    var primaryStatusText: String? {
        if isTriggered { return "ALLARME" }
        return currentMode.displayName
    }
    
    var markerStyle: MarkerStyle { .controllable }
    
    var visualUrgency: MarkerUrgency {
        if isTriggered { return .alarm }
        if currentMode != .disarm { return .ok }
        return .normal
    }
    
    /// No-op: la sicurezza non è quick-toggleabile. Il tap apre la DetailView.
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // Volutamente vuoto.
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(SecuritySystemControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state
    
    /// Modalità che l'utente ha richiesto (TargetState).
    /// Se è 3 (Disarm), corrisponde a "Disinserito".
    var currentMode: SecurityMode {
        let raw = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 3
        return SecurityMode(rawValue: raw) ?? .disarm
    }
    
    /// Stato effettivo del sistema (CurrentState), include `triggered`.
    var currentState: SecurityCurrentState {
        let raw = intValue(homeKit.value(for: currentStateCharacteristic) ?? currentStateCharacteristic.value) ?? 3
        return SecurityCurrentState(rawValue: raw) ?? .disarmed
    }
    
    var isTriggered: Bool {
        currentState == .triggered
    }
    
    /// True quando l'utente ha richiesto un cambio modalità ma il sistema non
    /// l'ha ancora confermato (es. armamento con countdown 30s).
    var isTransitioning: Bool {
        let target = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 3
        let current = intValue(homeKit.value(for: currentStateCharacteristic) ?? currentStateCharacteristic.value) ?? 3
        // Disarm corrisponde a current=3, gli altri 0/1/2 sono "armed" del target equivalente
        let normalizedCurrent = (current == 4) ? -1 : current  // triggered è "speciale"
        return target != normalizedCurrent && current != 4
    }
    
    /// Modalità supportate dall'accessorio (in base a validValues di TargetState).
    /// Ordine: Casa / Fuori / Notte / Disinserito.
    var supportedModes: [SecurityMode] {
        let validRaw = targetStateCharacteristic.metadata?.validValues as? [NSNumber] ?? []
        var modes: [SecurityMode] = []
        if validRaw.contains(0) { modes.append(.stay) }
        if validRaw.contains(1) { modes.append(.away) }
        if validRaw.contains(2) { modes.append(.night) }
        if validRaw.contains(3) { modes.append(.disarm) }
        // Fallback: se validValues è vuoto, mostriamo tutte le 4
        if modes.isEmpty {
            modes = [.stay, .away, .night, .disarm]
        }
        return modes
    }
    
    // MARK: - Writes
    
    func setMode(_ mode: SecurityMode) async throws {
        try await homeKit.write(mode.rawValue, to: targetStateCharacteristic)
    }
    
    // MARK: - Helpers
    
    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let u = any as? UInt8 { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
