import HomeKit
import Observation
import SwiftUI

/// Adapter per sensori HomeKit (read-only).
/// Supporta sia sensori booleani (contatto, movimento, fumo, CO, perdita acqua, occupazione)
/// sia sensori numerici (temperatura, umidità, luminosità, qualità aria).
///
/// Il sensore "primario" è scelto in base a un ordine di priorità: prima quelli
/// di sicurezza (fumo, CO, acqua), poi presenza, poi numerici comuni.
@MainActor
@Observable
final class SensorAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    /// Il sensor "primary" che decide cosa mostrare sul marker.
    private let primaryKind: SensorKind
    private let primaryCharacteristic: HMCharacteristic
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
        
        // Cerca in ordine di priorità il primo sensore noto
        guard let (kind, characteristic) = Self.findPrimarySensor(in: accessory) else {
            return nil
        }
        self.primaryKind = kind
        self.primaryCharacteristic = characteristic
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? { nil }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        let triggered = isTriggered
        return primaryKind.iconName(triggered: triggered)
    }
    
    /// I sensori non sono "on" in senso tradizionale; usiamo isOn per indicare
    /// uno stato "attivo/da notare" (rilevazione, allarme).
    var isOn: Bool {
        primaryKind.isBoolean && isTriggered
    }
    
    var supportsQuickToggle: Bool { false }
    
    var primaryStatusText: String? {
        let raw = homeKit.value(for: primaryCharacteristic) ?? primaryCharacteristic.value
        let result = primaryKind.formattedValue(raw)
        print("📊 [\(accessory.name)] kind=\(primaryKind), raw=\(String(describing: raw)) (\(type(of: raw))), formatted=\(String(describing: result))")
        return result
    }
    
    // QUESTE qui dentro la classe
    var markerStyle: MarkerStyle {
        primaryKind.isBoolean ? .sensorBoolean : .sensorNumeric
    }
    
    var visualUrgency: MarkerUrgency {
        // Sensori booleani in trigger: warning o alarm in base al tipo
        if primaryKind.isBoolean && isTriggered {
            switch primaryKind {
            case .smoke, .carbonMonoxide, .leak:
                return .alarm
            case .contact, .motion, .occupancy:
                return .warning
            default:
                return .normal
            }
        }
        
        // Qualità aria: warning o alarm in base al livello
        if primaryKind == .airQuality {
            let raw = homeKit.value(for: primaryCharacteristic) ?? primaryCharacteristic.value
            if let v = SensorKind.intValueStatic(raw) {
                switch v {
                case 4: return .warning   // Inferior
                case 5: return .alarm     // Poor
                default: return .normal
                }
            }
        }
        
        return .normal
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // Sensori read-only, noop
    }
    
    // MARK: - Stato interno
    
    private var isTriggered: Bool {
        let raw = homeKit.value(for: primaryCharacteristic) ?? primaryCharacteristic.value
        return primaryKind.interpretAsTriggered(raw)
    }
    
    // MARK: - Tipi
    
    /// Le tipologie di sensore HomeKit supportate, in ordine di priorità decrescente.
    /// Quando un accessorio espone più caratteristiche, scegliamo la più importante
    /// (es. fumo prevale su temperatura).
    enum SensorKind: CaseIterable {
        case smoke              // Rilevatore fumo
        case carbonMonoxide     // Rilevatore CO
        case leak               // Rilevatore perdita acqua
        case contact            // Contatto porta/finestra
        case motion             // Movimento
        case occupancy          // Presenza
        case temperature        // Temperatura
        case humidity           // Umidità
        case airQuality         // Qualità aria
        case lightLevel         // Luminosità ambiente
        
        var characteristicType: String {
            switch self {
            case .smoke: return HMCharacteristicTypeSmokeDetected
            case .carbonMonoxide: return HMCharacteristicTypeCarbonMonoxideDetected
            case .leak: return HMCharacteristicTypeLeakDetected
            case .contact: return HMCharacteristicTypeContactState
            case .motion: return HMCharacteristicTypeMotionDetected
            case .occupancy: return HMCharacteristicTypeOccupancyDetected
            case .temperature: return HMCharacteristicTypeCurrentTemperature
            case .humidity: return HMCharacteristicTypeCurrentRelativeHumidity
            case .airQuality: return HMCharacteristicTypeAirQuality
            case .lightLevel: return HMCharacteristicTypeCurrentLightLevel
            }
        }
        
        var isBoolean: Bool {
            switch self {
            case .smoke, .carbonMonoxide, .leak, .contact, .motion, .occupancy:
                return true
            case .temperature, .humidity, .airQuality, .lightLevel:
                return false
            }
        }
        
        func iconName(triggered: Bool) -> String {
            switch self {
            case .smoke: return triggered ? "smoke.fill" : "smoke"
            case .carbonMonoxide: return triggered ? "aqi.high" : "aqi.medium"
            case .leak: return triggered ? "drop.fill" : "drop"
            case .contact: return triggered ? "door.left.hand.open" : "door.left.hand.closed"
            case .motion: return triggered ? "figure.walk.motion" : "figure.stand"
            case .occupancy: return triggered ? "person.fill" : "person"
            case .temperature: return "thermometer.medium"
            case .humidity: return "humidity"
            case .airQuality: return "aqi.medium"
            case .lightLevel: return "sun.max"
            }
        }
        
        /// Per sensori booleani, decide se lo stato è "trigger" (es. porta aperta, movimento rilevato).
        /// Per quelli numerici, restituisce sempre false (non hanno un "trigger" semplice).
        func interpretAsTriggered(_ raw: Any?) -> Bool {
            guard isBoolean else { return false }
            var intValue = 0
            if let b = raw as? Bool { intValue = b ? 1 : 0 }
            else if let i = raw as? Int { intValue = i }
            else if let u = raw as? UInt8 { intValue = Int(u) }
            else if let n = raw as? NSNumber { intValue = n.intValue }
            
            // Tutti i sensori booleani HomeKit usano la stessa logica:
            // valore != 0 = "qualcosa è rilevato/aperto/in allarme"
            return intValue != 0
        }
        
        /// Formatta il valore per mostrarlo sul marker.
        func formattedValue(_ raw: Any?) -> String? {
            switch self {
            case .temperature:
                if let v = Self.doubleValueStatic(raw) {
                    return "\(Int(v.rounded()))°"
                }
            case .humidity:
                if let v = Self.doubleValueStatic(raw) {
                    return "\(Int(v.rounded()))%"
                }
            case .airQuality:
                if let v = Self.intValueStatic(raw) {
                    // 0=unknown, 1=excellent, 2=good, 3=fair, 4=inferior, 5=poor
                    switch v {
                    case 1: return "Ottima"
                            case 2: return "Buona"
                            case 3: return "Media"
                            case 4: return "Scarsa"
                            case 5: return "Pessima."
                    default: return nil
                    }
                }
            case .lightLevel:
                if let v = Self.doubleValueStatic(raw) {
                    // Mostra solo se sensato: lux > 1000 = "↑", < 10 = "↓", altrimenti il valore
                    if v < 10 { return "buio" }
                    if v > 5000 { return "sole" }
                    return "\(Int(v.rounded()))lx"
                }
            case .smoke, .carbonMonoxide, .leak, .contact, .motion, .occupancy:
                return nil  // Mostrano solo icona, no testo
            }
            return nil
        }
        
        static func doubleValueStatic(_ raw: Any?) -> Double? {
            if let d = raw as? Double { return d }
            if let f = raw as? Float { return Double(f) }
            if let n = raw as? NSNumber { return n.doubleValue }
            if let i = raw as? Int { return Double(i) }
            if let i8 = raw as? Int8 { return Double(i8) }
            if let u8 = raw as? UInt8 { return Double(u8) }
            if let i16 = raw as? Int16 { return Double(i16) }
            if let u16 = raw as? UInt16 { return Double(u16) }
            if let s = raw as? String, let parsed = Double(s) { return parsed }
            return nil
        }
        
         static func intValueStatic(_ raw: Any?) -> Int? {
            if let i = raw as? Int { return i }
            if let u = raw as? UInt8 { return Int(u) }
            if let i8 = raw as? Int8 { return Int(i8) }
            if let n = raw as? NSNumber { return n.intValue }
            if let d = raw as? Double { return Int(d) }
            if let s = raw as? String, let parsed = Int(s) { return parsed }
            return nil
        }
    }
    
    // MARK: - Discovery
    
    /// Cerca dentro l'accessorio una caratteristica sensore in ordine di priorità.
    static func findPrimarySensor(in accessory: HMAccessory) -> (SensorKind, HMCharacteristic)? {
        // 1) Service-based detection: se l'accessorio ha un service di tipo
        //    AirQualitySensor, privilegiamo la caratteristica airQuality
        //    (anche se ha anche temperatura/umidità).
        for service in accessory.services {
            if service.serviceType == HMServiceTypeAirQualitySensor,
               let c = service.characteristics.first(where: {
                   $0.characteristicType == HMCharacteristicTypeAirQuality
               }) {
                return (.airQuality, c)
            }
        }
        
        // 2) Fallback: ordine di priorità classico
        //    (sicurezza > presenza > numerici)
        for kind in SensorKind.allCases {
            if let c = AccessoryAdapterFactory.findCharacteristic(in: accessory,
                                                                   type: kind.characteristicType) {
                return (kind, c)
            }
        }
        return nil
    }
}
