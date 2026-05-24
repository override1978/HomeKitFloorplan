import Foundation
import SwiftUI

/// Informazioni di batteria di un accessorio.
struct BatteryInfo {
    /// Livello 0-100 se l'accessorio espone BatteryLevel, nil altrimenti.
    let level: Int?
    /// True se l'accessorio dichiara batteria bassa (via StatusLowBattery)
    /// o se il livello è ≤ 20.
    let isLow: Bool
    /// True se è in carica.
    let isCharging: Bool
    /// True se ha una batteria ricaricabile (esposto via ChargingState).
    let isRechargeable: Bool
    
    // MARK: - UI helpers
    
    /// SF Symbol da usare in base al livello (e ricarica).
    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        guard let level else {
            // Solo low/high noto
            return isLow ? "battery.25percent" : "battery.100percent"
        }
        switch level {
        case ..<10:   return "battery.0percent"
        case 10..<35: return "battery.25percent"
        case 35..<60: return "battery.50percent"
        case 60..<85: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }
    
    /// Colore semantico.
    var tintColor: Color {
        if isCharging { return .green }
        if isLow { return .red }
        if let level {
            switch level {
            case ..<25:   return .red
            case 25..<50: return .orange
            default:      return .green
            }
        }
        // Senza percentuale ma con isLow=false → batteria OK = verde
        return .green
    }
    
    /// Testo numerico (se livello disponibile).
    var displayText: String {
        if let level { return "\(level)%" }
        return isLow ? "Bassa" : "OK"
    }
}
