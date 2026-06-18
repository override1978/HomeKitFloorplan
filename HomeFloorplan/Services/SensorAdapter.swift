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
final class SensorAdapter: AccessoryAdapter, EnvironmentReadable {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    /// Il sensor "primary" che decide cosa mostrare sul marker.
    private let primaryKind: SensorKind
    private let primaryCharacteristic: HMCharacteristic
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
        
        guard Self.shouldUseSensorAdapter(for: accessory) else {
            return nil
        }
        
        // Cerca in ordine di priorità il primo sensore noto
        guard let (kind, characteristic) = Self.findPrimarySensor(in: accessory) else {
            return nil
        }
        self.primaryKind = kind
        self.primaryCharacteristic = characteristic
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(SensorEnvironmentSection(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - AccessoryAdapter
    
    var supportsFloorplanPlacement: Bool { true }

    /// Espone il tipo di sensore primario per uso esterno (es. filtri nelle impostazioni).
    var primarySensorKind: SensorKind { primaryKind }
    
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
        return primaryKind.formattedValue(raw)
    }
    
    // QUESTE qui dentro la classe
    var markerStyle: MarkerStyle {
        primaryKind.isBoolean ? .sensorBoolean : .sensorNumeric
    }
    
    // MARK: - Environment readings (per la sezione "Ambiente" della DetailView)

    // MARK: - Environment readings (per la sezione "Ambiente" della DetailView)

    var environmentTemperature: Double? {
        findDouble(byUUID: "00000011-0000-1000-8000-0026BB765291")
    }

    var environmentHumidity: Double? {
        findDouble(byUUID: "00000010-0000-1000-8000-0026BB765291")
    }

    var environmentLightLevel: Int? {
        findDouble(byUUID: "0000006B-0000-1000-8000-0026BB765291").map { Int($0) }
    }

    var environmentAirQuality: String? {
        let airQualityUUID = "00000095-0000-1000-8000-0026BB765291"
        guard let level = findInt(byUUID: airQualityUUID), level > 0 else { return nil }
        switch level {
        case 1: return String(localized: "sensor.airQuality.excellent", defaultValue: "Excellent")
        case 2: return String(localized: "sensor.airQuality.good",      defaultValue: "Good")
        case 3: return String(localized: "sensor.airQuality.fair",      defaultValue: "Fair")
        case 4: return String(localized: "sensor.airQuality.inferior",  defaultValue: "Inferior")
        case 5: return String(localized: "sensor.airQuality.poor",      defaultValue: "Poor")
        default: return nil
        }
    }

    var environmentPM25: Double? {
        findDouble(byUUID: "000000C6-0000-1000-8000-0026BB765291")
    }

    var environmentPM10: Double? {
        findDouble(byUUID: "000000C7-0000-1000-8000-0026BB765291")
    }

    var environmentCO2: Double? {
        findDouble(byUUID: "00000093-0000-1000-8000-0026BB765291")
    }

    var environmentVOC: Double? {
        findDouble(byUUID: "000000C8-0000-1000-8000-0026BB765291")
    }

    // MARK: - Boolean sensor states (per SensorEnvironmentSection)

    /// True se rilevato, false se non rilevato, nil se non espone smoke detector.
    var smokeDetected: Bool? {
        findIntByUUID("00000076-0000-1000-8000-0026BB765291").map { $0 == 1 }
    }

    /// 0=normal, 1=abnormal
    var carbonMonoxideDetected: Bool? {
        findIntByUUID("00000069-0000-1000-8000-0026BB765291").map { $0 == 1 }
    }

    /// 0=no leak, 1=leak detected
    var leakDetected: Bool? {
        findIntByUUID("00000070-0000-1000-8000-0026BB765291").map { $0 == 1 }
    }

    /// 0=closed, 1=open
    var contactDetected: Bool? {
        findIntByUUID("0000006A-0000-1000-8000-0026BB765291").map { $0 == 1 }
    }

    /// Bool direttamente
    var motionDetected: Bool? {
        findBoolByUUID("00000022-0000-1000-8000-0026BB765291")
    }

    /// 0=not occupied, 1=occupied
    var occupancyDetected: Bool? {
        findIntByUUID("00000071-0000-1000-8000-0026BB765291").map { $0 == 1 }
    }

    private func findIntByUUID(_ uuid: String) -> Int? {
        for service in accessory.services {
            for ch in service.characteristics where ch.characteristicType == uuid {
                let raw = homeKit.value(for: ch) ?? ch.value
                if let i = raw as? Int { return i }
                if let u = raw as? UInt8 { return Int(u) }
                if let n = raw as? NSNumber { return n.intValue }
            }
        }
        return nil
    }

    private func findBoolByUUID(_ uuid: String) -> Bool? {
        for service in accessory.services {
            for ch in service.characteristics where ch.characteristicType == uuid {
                let raw = homeKit.value(for: ch) ?? ch.value
                if let b = raw as? Bool { return b }
                if let i = raw as? Int { return i == 1 }
                if let n = raw as? NSNumber { return n.boolValue }
            }
        }
        return nil
    }
    // MARK: - Helpers per lookup characteristic per UUID (in qualunque servizio)

    private func findDouble(byUUID uuid: String) -> Double? {
        for service in accessory.services {
            for ch in service.characteristics where ch.characteristicType == uuid {
                let raw = homeKit.value(for: ch) ?? ch.value
                if let d = raw as? Double { return d }
                if let f = raw as? Float { return Double(f) }
                if let i = raw as? Int { return Double(i) }
                if let n = raw as? NSNumber { return n.doubleValue }
            }
        }
        return nil
    }

    private func findInt(byUUID uuid: String) -> Int? {
        for service in accessory.services {
            for ch in service.characteristics where ch.characteristicType == uuid {
                let raw = homeKit.value(for: ch) ?? ch.value
                if let i = raw as? Int { return i }
                if let u = raw as? UInt8 { return Int(u) }
                if let n = raw as? NSNumber { return n.intValue }
            }
        }
        return nil
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
                    // Legge la preferenza utente da UserDefaults (stessa chiave di SettingsView)
                    let saved = UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
                    let usesF = TemperatureUnit(rawValue: saved) == .fahrenheit
                    let displayValue = usesF ? v * 9.0 / 5.0 + 32.0 : v
                    let symbol = usesF ? "°F" : "°C"
                    return "\(Int(displayValue.rounded()))\(symbol)"
                }
            case .humidity:
                if let v = Self.doubleValueStatic(raw) {
                    return "\(Int(v.rounded()))%"
                }
            case .airQuality:
                if let v = Self.intValueStatic(raw) {
                    // 0=unknown, 1=excellent, 2=good, 3=fair, 4=inferior, 5=poor
                    switch v {
                    case 1: return String(localized: "sensor.airQuality.excellent", defaultValue: "Excellent")
                    case 2: return String(localized: "sensor.airQuality.good",      defaultValue: "Good")
                    case 3: return String(localized: "sensor.airQuality.fair",      defaultValue: "Fair")
                    case 4: return String(localized: "sensor.airQuality.inferior",  defaultValue: "Inferior")
                    case 5: return String(localized: "sensor.airQuality.poor",      defaultValue: "Poor")
                    default: return nil
                    }
                }
            case .lightLevel:
                if let v = Self.doubleValueStatic(raw) {
                    if v < 10   { return String(localized: "sensor.lightLevel.dark",   defaultValue: "dark") }
                    if v > 5000 { return String(localized: "sensor.lightLevel.bright", defaultValue: "bright") }
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
    
    private static func shouldUseSensorAdapter(for accessory: HMAccessory) -> Bool {
        let serviceTypes = Set(accessory.services.map { $0.serviceType.uppercased() })
        let controllableServiceTypes: Set<String> = [
            "00000043-0000-1000-8000-0026BB765291", // Lightbulb
            "00000047-0000-1000-8000-0026BB765291", // Outlet
            "00000049-0000-1000-8000-0026BB765291", // Switch
            "00000040-0000-1000-8000-0026BB765291", // Fan
            "000000B7-0000-1000-8000-0026BB765291", // Fan v2
            "0000008C-0000-1000-8000-0026BB765291", // Window Covering
            "000000BC-0000-1000-8000-0026BB765291", // Heater Cooler
            "000000BD-0000-1000-8000-0026BB765291", // Humidifier Dehumidifier
            "0000004A-0000-1000-8000-0026BB765291", // Thermostat
            "000000BB-0000-1000-8000-0026BB765291", // Air Purifier
            "000000D8-0000-1000-8000-0026BB765291", // Television
            "00000045-0000-1000-8000-0026BB765291", // Lock Mechanism
            "00000041-0000-1000-8000-0026BB765291", // Garage Door Opener
            "0000007E-0000-1000-8000-0026BB765291"  // Security System
        ]
        
        guard serviceTypes.isDisjoint(with: controllableServiceTypes) else {
            return false
        }
        
        if accessory.category.categoryType == HMAccessoryCategoryTypeSensor {
            return true
        }
        
        let sensorServiceTypes: Set<String> = [
            "0000007F-0000-1000-8000-0026BB765291", // Carbon Monoxide Sensor
            "00000080-0000-1000-8000-0026BB765291", // Contact Sensor
            "00000082-0000-1000-8000-0026BB765291", // Humidity Sensor
            "00000083-0000-1000-8000-0026BB765291", // Leak Sensor
            "00000084-0000-1000-8000-0026BB765291", // Light Sensor
            "00000085-0000-1000-8000-0026BB765291", // Motion Sensor
            "00000086-0000-1000-8000-0026BB765291", // Occupancy Sensor
            "00000087-0000-1000-8000-0026BB765291", // Smoke Sensor
            "0000008A-0000-1000-8000-0026BB765291", // Temperature Sensor
            "0000008D-0000-1000-8000-0026BB765291"  // Air Quality Sensor
        ]
        return !serviceTypes.isDisjoint(with: sensorServiceTypes)
    }
}
