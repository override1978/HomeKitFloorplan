import HomeKit

/// Helper centralizzato per leggere le caratteristiche di batteria
/// da un qualsiasi accessorio HomeKit. Cerca StatusLowBattery, BatteryLevel
/// e ChargingState in tutti i servizi dell'accessorio.
enum BatteryReader {
    
    private static let statusLowBatteryUUID = "00000079-0000-1000-8000-0026BB765291"
    private static let batteryLevelUUID = "00000068-0000-1000-8000-0026BB765291"
    private static let chargingStateUUID = "0000008F-0000-1000-8000-0026BB765291"
    
    /// Restituisce BatteryInfo se l'accessorio espone almeno UNA delle 3
    /// caratteristiche di batteria standard. Altrimenti nil.
    @MainActor
    static func read(from accessory: HMAccessory, via homeKit: HomeKitService) -> BatteryInfo? {
        let lowBatteryChar = findCharacteristic(in: accessory, type: statusLowBatteryUUID)
        let levelChar = findCharacteristic(in: accessory, type: batteryLevelUUID)
        let chargingChar = findCharacteristic(in: accessory, type: chargingStateUUID)
        
        // Nessuna caratteristica batteria → accessorio cablato/senza info
        guard lowBatteryChar != nil || levelChar != nil || chargingChar != nil else {
            return nil
        }
        
        // Livello
        let level: Int? = {
            guard let c = levelChar else { return nil }
            let raw = homeKit.value(for: c) ?? c.value
            return intValue(raw)
        }()
        
        // Low (priorità a StatusLowBattery; fallback a level ≤ 20)
        let isLow: Bool = {
            if let c = lowBatteryChar {
                let raw = homeKit.value(for: c) ?? c.value
                return intValue(raw) == 1
            }
            if let level { return level <= 20 }
            return false
        }()
        
        // Charging state
        let (isCharging, isRechargeable): (Bool, Bool) = {
            guard let c = chargingChar else { return (false, false) }
            let raw = intValue(homeKit.value(for: c) ?? c.value) ?? 2
            // 0=Not Charging, 1=Charging, 2=Not Chargeable
            return (raw == 1, raw != 2)
        }()
        
        return BatteryInfo(level: level, isLow: isLow,
                           isCharging: isCharging, isRechargeable: isRechargeable)
    }
    
    // MARK: - Helpers
    
    private static func findCharacteristic(in accessory: HMAccessory, type: String) -> HMCharacteristic? {
        for service in accessory.services {
            for ch in service.characteristics where ch.characteristicType == type {
                return ch
            }
        }
        return nil
    }
    
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let u = any as? UInt8 { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
