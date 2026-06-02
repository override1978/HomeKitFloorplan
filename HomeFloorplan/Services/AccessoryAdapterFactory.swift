import HomeKit

/// Factory che genera l'adapter giusto per ogni HMAccessory.
///
/// Strategia: characteristic-first (come già facevamo per AccessoryStateClassifier).
/// La categoria HomeKit è inaffidabile per accessori di terze parti, quindi
/// guardiamo le caratteristiche effettive per decidere.
@MainActor
enum AccessoryAdapterFactory {
    
    static func adapter(for accessory: HMAccessory,
                        homeKit: HomeKitService) -> any AccessoryAdapter {
        
       
        // 0. Matter device "opachi" (robot vacuum, ecc.) - PRIMA di tutto
            if let matter = MatterDeviceAdapter(accessory: accessory) {
                return matter
            }
        
        // 0.5 Sistema di sicurezza (DEVE precedere sensori e on/off,
        //     perché alcuni hub espongono anche altri servizi che potrebbero "rubarlo")
        if let security = SecuritySystemAdapter(accessory: accessory, homeKit: homeKit) {
            return security
        }
        
        // 0.7 Serratura
        if let lock = DoorLockAdapter(accessory: accessory, homeKit: homeKit) {
            return lock
        }
        
        // 0.7 Garage
        if let garage = GarageDoorAdapter(accessory: accessory, homeKit: homeKit) {
            return garage
        }
        
        // 0.8 Purificatori d'aria (PRIMA dei sensori per evitare cattura via AirQualitySensor)
        if let purifier = AirPurifierAdapter(accessory: accessory, homeKit: homeKit) {
            return purifier
        }
        
        // 4. Termostati / Valvole TRV (DEVE precedere OnOffAdapter)
        if let thermo = ThermostatAdapter(accessory: accessory, homeKit: homeKit) {
            return thermo
        }
        
        // 1.5 Termostati legacy (Thermostat classico)
        if let thermoLegacy = LegacyThermostatAdapter(accessory: accessory, homeKit: homeKit) {
            return thermoLegacy
        }
        
        if accessory.services.contains(where: { $0.serviceType == ProgrammableSwitchAdapter.serviceType }) {
            return ProgrammableSwitchAdapter(accessory: accessory, homeKit: homeKit)
        }
        
        // 1) Sensori: read-only
        if let sensorAdapter = SensorAdapter(accessory: accessory, homeKit: homeKit) {
            return sensorAdapter
        }
        
        // 2) Tende / coperture finestre: hanno TargetPosition/CurrentPosition
        if let windowAdapter = WindowCoveringAdapter(accessory: accessory, homeKit: homeKit) {
            return windowAdapter
        }
        
        // 3. Luci dimmerabili (DEVE precedere OnOffAdapter)
        if let dimmer = DimmableLightAdapter(accessory: accessory, homeKit: homeKit) {
            return dimmer
        }
        
        // PRIMA di OnOffAdapter
        let outletServices = accessory.services.filter { $0.serviceType == MultiOutletAdapter.outletServiceType }
        if outletServices.count >= 2 {
            return MultiOutletAdapter(accessory: accessory, homeKit: homeKit)
        }
        
        // 3) On/off generico: PowerState o Active
        if hasCharacteristic(accessory, type: HMCharacteristicTypePowerState) {
            return OnOffAdapter(accessory: accessory, homeKit: homeKit)
        }
        if hasCharacteristic(accessory, type: HMCharacteristicTypeActive) {
            return OnOffAdapter(accessory: accessory, homeKit: homeKit)
        }
        
        // 4) Fallback
        return UnsupportedAdapter(accessory: accessory)
    }
    
    private static func hasCharacteristic(_ accessory: HMAccessory,
                                          type: String) -> Bool {
        for service in accessory.services { 
            for c in service.characteristics where c.characteristicType == type {
                return true
            }
        }
        return false
    }
    
    static func findCharacteristic(in accessory: HMAccessory,
                                   type: String) -> HMCharacteristic? {
        for service in accessory.services {
            for c in service.characteristics where c.characteristicType == type {
                return c
            }
        }
        return nil
    }
}
