import Foundation
import HomeKit

// MARK: - TemperatureUnit

/// Unità di misura della temperatura scelta dall'utente in Impostazioni.
/// Il valore grezzo proveniente da HomeKit è sempre in °C; la conversione
/// avviene solo lato display.
enum TemperatureUnit: String, CaseIterable {
    case celsius    = "celsius"
    case fahrenheit = "fahrenheit"

    static let appStorageKey = "temperatureUnit"

    var symbol: String {
        switch self {
        case .celsius:    return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Converte un valore da °C all'unità corrente (solo display).
    func convert(_ celsius: Double) -> Double {
        switch self {
        case .celsius:    return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        }
    }

    /// Formatta un valore °C secondo l'unità corrente.
    func format(_ celsius: Double) -> String {
        String(format: "%.1f\(symbol)", convert(celsius))
    }
}

// MARK: - SensorServiceType

/// Tipologie di sensore ambientale supportate dalla Dashboard Ambientale.
/// Ogni caso mappa direttamente a un tipo di caratteristica HomeKit e
/// definisce le soglie di default per warning/danger.
enum SensorServiceType: String, CaseIterable, Identifiable, Codable {
    case temperature
    case humidity
    case airQuality
    case carbonMonoxide
    case carbonDioxide
    case smoke
    case vocDensity

    var id: String { rawValue }

    // MARK: Mappatura HomeKit

    /// Tipo caratteristica HomeKit corrispondente.
    var hmCharacteristicType: String {
        switch self {
        case .temperature:    return HMCharacteristicTypeCurrentTemperature
        case .humidity:       return HMCharacteristicTypeCurrentRelativeHumidity
        case .airQuality:     return HMCharacteristicTypeAirQuality
        case .carbonMonoxide: return HMCharacteristicTypeCarbonMonoxideLevel
        case .carbonDioxide:  return HMCharacteristicTypeCarbonDioxideLevel
        case .smoke:          return HMCharacteristicTypeSmokeDetected
        case .vocDensity:     return HMCharacteristicTypeVolatileOrganicCompoundDensity
        }
    }

    /// Tipo servizio HomeKit principale per questo sensore.
    var hmServiceType: String {
        switch self {
        case .temperature:    return HMServiceTypeTemperatureSensor
        case .humidity:       return HMServiceTypeHumiditySensor
        case .airQuality:     return HMServiceTypeAirQualitySensor
        case .carbonMonoxide: return HMServiceTypeCarbonMonoxideSensor
        case .carbonDioxide:  return HMServiceTypeCarbonDioxideSensor
        case .smoke:          return HMServiceTypeSmokeSensor
        case .vocDensity:     return HMServiceTypeAirQualitySensor
        }
    }

    // MARK: Metadati display

    /// Unità di misura mostrata in UI.
    var unit: String {
        switch self {
        case .temperature:    return "°C"
        case .humidity:       return "%"
        case .airQuality:     return ""
        case .carbonMonoxide: return "ppm"
        case .carbonDioxide:  return "ppm"
        case .smoke:          return ""
        case .vocDensity:     return "µg/m³"
        }
    }

    /// Label leggibile del tipo di sensore.
    var displayName: String {
        switch self {
        case .temperature:    return String(localized: "sensor.temperature",    defaultValue: "Temperature")
        case .humidity:       return String(localized: "sensor.humidity",       defaultValue: "Humidity")
        case .airQuality:     return String(localized: "sensor.airQuality",     defaultValue: "Air Quality")
        case .carbonMonoxide: return String(localized: "sensor.carbonMonoxide", defaultValue: "Carbon Monoxide")
        case .carbonDioxide:  return String(localized: "sensor.carbonDioxide",  defaultValue: "Carbon Dioxide")
        case .smoke:          return String(localized: "sensor.smoke",          defaultValue: "Smoke")
        case .vocDensity:     return String(localized: "sensor.vocDensity",     defaultValue: "VOC")
        }
    }

    /// Icona SF Symbol associata.
    var sfSymbol: String {
        switch self {
        case .temperature:    return "thermometer.medium"
        case .humidity:       return "humidity.fill"
        case .airQuality:     return "aqi.medium"
        case .carbonMonoxide: return "carbon.monoxide.cloud.fill"
        case .carbonDioxide:  return "carbon.dioxide.cloud.fill"
        case .smoke:          return "smoke.fill"
        case .vocDensity:     return "flask.fill"
        }
    }

    // MARK: Alert booleano

    /// True se il sensore restituisce un valore booleano (rilevato/non rilevato).
    var isBooleanAlert: Bool {
        switch self {
        case .smoke: return true
        default:     return false
        }
    }

    // MARK: Categoria notifica

    /// Categoria di urgenza per la notifica:
    /// - safety: pericolo di vita (fumo, CO) → suono forte
    /// - health:  impatto sulla salute (CO₂, VOC, aria) → suono normale
    /// - comfort: comfort (temperatura, umidità) → silenzioso
    enum NotificationCategory {
        case safety, health, comfort
    }

    var notificationCategory: NotificationCategory {
        switch self {
        case .smoke, .carbonMonoxide:            return .safety
        case .carbonDioxide, .vocDensity, .airQuality: return .health
        case .temperature, .humidity:            return .comfort
        }
    }

    // MARK: Peso qualità ambientale

    /// Peso del sensore nel calcolo del Global Quality Score.
    /// Riflette l'impatto sulla sicurezza/salute:
    ///   3.0 → pericolo di vita (fumo, CO)
    ///   2.0 → impatto sulla salute (qualità aria, VOC)
    ///   1.0 → comfort (temperatura, umidità)
    var qualityWeight: Double {
        switch self {
        case .smoke:          return 3.0
        case .carbonMonoxide: return 3.0
        case .carbonDioxide:  return 2.0   // impatto salute (valori > 1000 ppm riducono concentrazione)
        case .airQuality:     return 2.0
        case .vocDensity:     return 2.0
        case .temperature:    return 1.0
        case .humidity:       return 1.0
        }
    }

    // MARK: Soglie di default

    /// Soglia warning di default.
    var defaultWarning: Double {
        switch self {
        case .temperature:    return 28.0
        case .humidity:       return 65.0
        case .airQuality:     return 3.0
        case .carbonMonoxide: return 10.0
        case .carbonDioxide:  return 1000.0  // OMS: >1000 ppm riduce concentrazione
        case .smoke:          return 1.0
        case .vocDensity:     return 500.0
        }
    }

    /// Soglia danger di default.
    var defaultDanger: Double {
        switch self {
        case .temperature:    return 32.0
        case .humidity:       return 75.0
        case .airQuality:     return 4.0
        case .carbonMonoxide: return 25.0
        case .carbonDioxide:  return 2000.0  // >2000 ppm: sintomi evidenti, aria malsana
        case .smoke:          return 1.0
        case .vocDensity:     return 1000.0
        }
    }

    // MARK: Soglie basse (comfort minimo)

    /// Soglia bassa di default: valori SOTTO questa soglia indicano un problema.
    /// Nil se il tipo non ha un range minimo di comfort (es. CO, fumo, VOC — più basso è sempre meglio).
    var defaultLowWarning: Double? {
        switch self {
        case .humidity:     return 40.0  // WHO/ASHRAE: sotto 40% aria troppo secca
        case .temperature:  return 18.0  // sotto 18°C discomfort freddo
        default:            return nil   // CO, fumo, VOC, CO₂, qualità aria: no soglia bassa
        }
    }

    /// Soglia bassa danger di default: valori SOTTO questa soglia sono critici.
    /// Nil se il tipo non ha soglia bassa.
    var defaultLowDanger: Double? {
        switch self {
        case .humidity:     return 30.0  // sotto 30% problemi di salute (mucose, statica)
        case .temperature:  return 14.0  // sotto 14°C ipotermia rischio per anziani/bambini
        default:            return nil
        }
    }
}
