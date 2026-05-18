import HomeKit

/// Rappresenta cosa può fare il "tap rapido" su un dato accessorio.
enum AccessoryQuickAction {
    case toggle(HMCharacteristic)
    case none
}

enum AccessoryStateClassifier {
    
    /// Determina che azione rapida è possibile per un accessorio.
    /// Strategia: ignoriamo la categoria HomeKit (spesso "Other" per accessori
    /// di terze parti) e guardiamo le caratteristiche effettive.
    ///
    /// Toggleabile se:
    ///  - ha PowerState (luci, prese, switch)
    ///  - ha Active (ventilatori, purificatori) → ma evitiamo categorie pericolose
    ///
    /// NON toggleabile (rinviamo al pannello):
    ///  - serrature, garage, irrigatori (richiedono conferma esplicita)
    ///  - termostati, coperture (richiedono valore non-binario)
    ///  - sensori (sono read-only)
    static func quickAction(for accessory: HMAccessory) -> AccessoryQuickAction {
        guard accessory.isReachable else { return .none }
        
        // Categorie esplicitamente escluse dal tap rapido per sicurezza
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeDoorLock,
             HMAccessoryCategoryTypeGarageDoorOpener,
             HMAccessoryCategoryTypeSprinkler,
             HMAccessoryCategoryTypeFaucet,
             HMAccessoryCategoryTypeThermostat,
             HMAccessoryCategoryTypeWindow,
             HMAccessoryCategoryTypeWindowCovering,
             HMAccessoryCategoryTypeIPCamera,
             HMAccessoryCategoryTypeVideoDoorbell,
             HMAccessoryCategoryTypeSensor:
            return .none
        default:
            break
        }
        
        // Strategia "characteristic-first": ignoriamo la categoria e
        // guardiamo cosa l'accessorio espone davvero.
        if let c = findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState) {
            return .toggle(c)
        }
        if let c = findCharacteristic(in: accessory, type: HMCharacteristicTypeActive) {
            return .toggle(c)
        }
        return .none
    }
    
    /// Caratteristica primaria per la UI dello "stato acceso/spento".
    static func primaryStateCharacteristic(for accessory: HMAccessory) -> HMCharacteristic? {
        if let c = findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState) {
            return c
        }
        if let c = findCharacteristic(in: accessory, type: HMCharacteristicTypeActive) {
            return c
        }
        if let c = findCharacteristic(in: accessory, type: HMCharacteristicTypeCurrentLockMechanismState) {
            return c
        }
        return nil
    }
    
    /// Interpreta un valore generico come "on/true" in modo robusto.
    static func isOn(value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i == 1 }
        if let i = value as? UInt8 { return i == 1 }
        if let n = value as? NSNumber { return n.intValue == 1 }
        return false
    }
    
    /// Valore "toggle" appropriato per il tipo della caratteristica.
    static func toggledValue(for characteristic: HMCharacteristic, current: Any?) -> Any {
        let currentlyOn = isOn(value: current)
        switch characteristic.characteristicType {
        case HMCharacteristicTypePowerState:
            return !currentlyOn
        case HMCharacteristicTypeActive:
            return currentlyOn ? 0 : 1
        default:
            return !currentlyOn
        }
    }
    
    private static func findCharacteristic(in accessory: HMAccessory,
                                           type: String) -> HMCharacteristic? {
        for service in accessory.services {
            for c in service.characteristics where c.characteristicType == type {
                return c
            }
        }
        return nil
    }
}
