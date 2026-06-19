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
    case lightSensor        // HomeKit HMServiceTypeLightSensor / CurrentAmbientLightLevel
    case outdoorTemperature // WeatherKit source — persisted by SensorLogger.sampleOutdoor
    case outdoorHumidity    // WeatherKit source — persisted by SensorLogger.sampleOutdoor

    var id: String { rawValue }

    // MARK: Mappatura HomeKit

    /// True for types whose readings come from WeatherKit rather than HomeKit.
    /// SensorLogger.sampleAllSensors skips these; use sampleOutdoor instead.
    var isWeatherKitSource: Bool {
        switch self {
        case .outdoorTemperature, .outdoorHumidity: return true
        default: return false
        }
    }

    /// False for types that should not generate SensorAlertThreshold entries.
    /// Outdoor weather types and light sensors are read-only / display-only — not user-alertable.
    var hasAlertThreshold: Bool {
        switch self {
        case .outdoorTemperature, .outdoorHumidity, .lightSensor: return false
        default: return true
        }
    }

    /// Tipo caratteristica HomeKit corrispondente.
    var hmCharacteristicType: String {
        switch self {
        case .temperature:        return HMCharacteristicTypeCurrentTemperature
        case .humidity:           return HMCharacteristicTypeCurrentRelativeHumidity
        case .airQuality:         return HMCharacteristicTypeAirQuality
        case .carbonMonoxide:     return HMCharacteristicTypeCarbonMonoxideLevel
        case .carbonDioxide:      return HMCharacteristicTypeCarbonDioxideLevel
        case .smoke:              return HMCharacteristicTypeSmokeDetected
        case .vocDensity:         return HMCharacteristicTypeVolatileOrganicCompoundDensity
        case .lightSensor:        return HMCharacteristicTypeCurrentLightLevel
        case .outdoorTemperature, .outdoorHumidity: return "" // WeatherKit — not read from HM
        }
    }

    /// Tipo servizio HomeKit principale per questo sensore.
    var hmServiceType: String {
        switch self {
        case .temperature:        return HMServiceTypeTemperatureSensor
        case .humidity:           return HMServiceTypeHumiditySensor
        case .airQuality:         return HMServiceTypeAirQualitySensor
        case .carbonMonoxide:     return HMServiceTypeCarbonMonoxideSensor
        case .carbonDioxide:      return HMServiceTypeCarbonDioxideSensor
        case .smoke:              return HMServiceTypeSmokeSensor
        case .vocDensity:         return HMServiceTypeAirQualitySensor
        case .lightSensor:        return HMServiceTypeLightSensor
        case .outdoorTemperature, .outdoorHumidity: return "" // WeatherKit — not read from HM
        }
    }

    // MARK: Metadati display

    /// Unità di misura mostrata in UI.
    var unit: String {
        switch self {
        case .temperature:        return "°C"
        case .humidity:           return "%"
        case .airQuality:         return ""
        case .carbonMonoxide:     return "ppm"
        case .carbonDioxide:      return "ppm"
        case .smoke:              return ""
        case .vocDensity:         return "µg/m³"
        case .lightSensor:        return "lux"
        case .outdoorTemperature: return "°C"
        case .outdoorHumidity:    return "%"
        }
    }

    /// Label leggibile del tipo di sensore.
    var displayName: String {
        switch self {
        case .temperature:        return String(localized: "sensor.temperature",        defaultValue: "Temperature")
        case .humidity:           return String(localized: "sensor.humidity",           defaultValue: "Humidity")
        case .airQuality:         return String(localized: "sensor.airQuality",         defaultValue: "Air quality")
        case .carbonMonoxide:     return String(localized: "sensor.carbonMonoxide",     defaultValue: "Carbon monoxide")
        case .carbonDioxide:      return String(localized: "sensor.carbonDioxide",      defaultValue: "Carbon dioxide")
        case .smoke:              return String(localized: "sensor.smoke",              defaultValue: "Smoke")
        case .vocDensity:         return String(localized: "sensor.vocDensity",         defaultValue: "VOC")
        case .lightSensor:        return String(localized: "sensor.lightSensor",        defaultValue: "Light")
        case .outdoorTemperature: return String(localized: "sensor.outdoorTemperature", defaultValue: "Outdoor temperature")
        case .outdoorHumidity:    return String(localized: "sensor.outdoorHumidity",    defaultValue: "Outdoor humidity")
        }
    }

    /// Icona SF Symbol associata.
    var sfSymbol: String {
        switch self {
        case .temperature:        return "thermometer.medium"
        case .humidity:           return "humidity.fill"
        case .airQuality:         return "aqi.medium"
        case .carbonMonoxide:     return "carbon.monoxide.cloud.fill"
        case .carbonDioxide:      return "carbon.dioxide.cloud.fill"
        case .smoke:              return "smoke.fill"
        case .vocDensity:         return "flask.fill"
        case .lightSensor:        return "sun.max.fill"
        case .outdoorTemperature: return "thermometer.sun.fill"
        case .outdoorHumidity:    return "cloud.rain.fill"
        }
    }

    // MARK: Alert booleano

    /// True se il sensore restituisce un valore booleano (rilevato/non rilevato).
    var isBooleanAlert: Bool {
        self == .smoke
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
        case .smoke, .carbonMonoxide:                        return .safety
        case .carbonDioxide, .vocDensity, .airQuality:       return .health
        case .temperature, .humidity,
             .lightSensor, .outdoorTemperature, .outdoorHumidity: return .comfort
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
        case .carbonDioxide:  return 2.0
        case .airQuality:     return 2.0
        case .vocDensity:     return 2.0
        case .temperature:    return 1.0
        case .humidity:       return 1.0
        case .lightSensor, .outdoorTemperature, .outdoorHumidity: return 0.0
        }
    }

    // MARK: Soglie di default

    /// Soglia warning di default.
    var defaultWarning: Double {
        switch self {
        case .temperature:        return 28.0
        case .humidity:           return 65.0
        case .airQuality:         return 3.0
        case .carbonMonoxide:     return 10.0
        case .carbonDioxide:      return 1000.0
        case .smoke:              return 1.0
        case .vocDensity:         return 500.0
        case .lightSensor:        return Double.greatestFiniteMagnitude  // display-only — never alert
        case .outdoorTemperature: return 100.0     // sentinel — outdoor types have no user alert
        case .outdoorHumidity:    return 100.0
        }
    }

    /// Soglia danger di default.
    var defaultDanger: Double {
        switch self {
        case .temperature:        return 32.0
        case .humidity:           return 75.0
        case .airQuality:         return 4.0
        case .carbonMonoxide:     return 25.0
        case .carbonDioxide:      return 2000.0
        case .smoke:              return 1.0
        case .vocDensity:         return 1000.0
        case .lightSensor:        return Double.greatestFiniteMagnitude
        case .outdoorTemperature: return 200.0     // sentinel — outdoor types have no user alert
        case .outdoorHumidity:    return 200.0
        }
    }

    // MARK: Soglie basse (comfort minimo)

    /// Soglia bassa di default: valori SOTTO questa soglia indicano un problema.
    /// Nil se il tipo non ha un range minimo di comfort (es. CO, fumo, VOC — più basso è sempre meglio).
    var defaultLowWarning: Double? {
        switch self {
        case .humidity:     return 40.0  // WHO/ASHRAE: sotto 40% aria troppo secca
        case .temperature:  return 18.0  // sotto 18°C discomfort freddo
        default:            return nil
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
