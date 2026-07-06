import Foundation

struct OperationalIntelligencePolicy: Codable, Hashable {
    static let storageKey = "operationalIntelligencePolicy.v1"

    var isEnabled: Bool
    var lightLongOnMinutes: Double
    var loadLongActiveMinutes: Double
    var contactOpenMinutes: Double
    var contactEscalationMinutes: Double
    var escalatesAtNight: Bool
    var nightStartHour: Int
    var nightEndHour: Int
    var ignoredAccessoryIDs: [String]
    /// Stanze escluse da TUTTI i calcoli intelligence (anomalie operative, segnali
    /// ambientali, guasti sensore, incoerenze). Per stanze "tecniche" che ospitano
    /// switch virtuali o dispositivi di servizio (es. "Impostazioni").
    var ignoredRoomNames: [String]
    /// Incoerenza "luci accese con luce naturale sufficiente".
    var daylightWasteEnabled: Bool
    var daylightLuxThreshold: Double
    var daylightStartHour: Int
    var daylightEndHour: Int
    /// Soglia (°C) del trend a 90 minuti per l'incoerenza "Raffrescamento inefficace":
    /// clima in cooling ma la stanza si è scaldata di almeno questo delta.
    var coolingIneffectiveDeltaCelsius: Double
    /// Salita minima CO2 (ppm, trend a 90 min) per l'incoerenza "CO2 in salita senza
    /// ricambio". I livelli assoluti derivano dalle soglie Ambiente dell'utente.
    var co2RiseThresholdPPM: Double

    static let `default` = OperationalIntelligencePolicy(
        isEnabled: true,
        lightLongOnMinutes: 180,
        loadLongActiveMinutes: 360,
        contactOpenMinutes: 15,
        contactEscalationMinutes: 45,
        escalatesAtNight: true,
        nightStartHour: 22,
        nightEndHour: 7,
        ignoredAccessoryIDs: [],
        ignoredRoomNames: [],
        daylightWasteEnabled: true,
        daylightLuxThreshold: 500,
        daylightStartHour: 8,
        daylightEndHour: 18,
        coolingIneffectiveDeltaCelsius: 0.5,
        co2RiseThresholdPPM: 180
    )

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case lightLongOnMinutes
        case loadLongActiveMinutes
        case contactOpenMinutes
        case contactEscalationMinutes
        case escalatesAtNight
        case nightStartHour
        case nightEndHour
        case ignoredAccessoryIDs
        case ignoredRoomNames
        case daylightWasteEnabled
        case daylightLuxThreshold
        case daylightStartHour
        case daylightEndHour
        case coolingIneffectiveDeltaCelsius
        case co2RiseThresholdPPM
    }

    init(
        isEnabled: Bool,
        lightLongOnMinutes: Double,
        loadLongActiveMinutes: Double,
        contactOpenMinutes: Double,
        contactEscalationMinutes: Double,
        escalatesAtNight: Bool,
        nightStartHour: Int,
        nightEndHour: Int,
        ignoredAccessoryIDs: [String],
        ignoredRoomNames: [String] = [],
        daylightWasteEnabled: Bool = true,
        daylightLuxThreshold: Double = 500,
        daylightStartHour: Int = 8,
        daylightEndHour: Int = 18,
        coolingIneffectiveDeltaCelsius: Double = 0.5,
        co2RiseThresholdPPM: Double = 180
    ) {
        self.isEnabled = isEnabled
        self.lightLongOnMinutes = lightLongOnMinutes
        self.loadLongActiveMinutes = loadLongActiveMinutes
        self.contactOpenMinutes = contactOpenMinutes
        self.contactEscalationMinutes = contactEscalationMinutes
        self.escalatesAtNight = escalatesAtNight
        self.nightStartHour = Self.clampedHour(nightStartHour)
        self.nightEndHour = Self.clampedHour(nightEndHour)
        self.ignoredAccessoryIDs = ignoredAccessoryIDs
        self.ignoredRoomNames = ignoredRoomNames
        self.daylightWasteEnabled = daylightWasteEnabled
        self.daylightLuxThreshold = daylightLuxThreshold
        self.daylightStartHour = Self.clampedHour(daylightStartHour)
        self.daylightEndHour = Self.clampedHour(daylightEndHour)
        self.coolingIneffectiveDeltaCelsius = coolingIneffectiveDeltaCelsius
        self.co2RiseThresholdPPM = co2RiseThresholdPPM
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        lightLongOnMinutes = try container.decodeIfPresent(Double.self, forKey: .lightLongOnMinutes) ?? defaults.lightLongOnMinutes
        loadLongActiveMinutes = try container.decodeIfPresent(Double.self, forKey: .loadLongActiveMinutes) ?? defaults.loadLongActiveMinutes
        contactOpenMinutes = try container.decodeIfPresent(Double.self, forKey: .contactOpenMinutes) ?? defaults.contactOpenMinutes
        contactEscalationMinutes = try container.decodeIfPresent(Double.self, forKey: .contactEscalationMinutes) ?? defaults.contactEscalationMinutes
        escalatesAtNight = try container.decodeIfPresent(Bool.self, forKey: .escalatesAtNight) ?? defaults.escalatesAtNight
        nightStartHour = Self.clampedHour(try container.decodeIfPresent(Int.self, forKey: .nightStartHour) ?? defaults.nightStartHour)
        nightEndHour = Self.clampedHour(try container.decodeIfPresent(Int.self, forKey: .nightEndHour) ?? defaults.nightEndHour)
        ignoredAccessoryIDs = try container.decodeIfPresent([String].self, forKey: .ignoredAccessoryIDs) ?? defaults.ignoredAccessoryIDs
        ignoredRoomNames = try container.decodeIfPresent([String].self, forKey: .ignoredRoomNames) ?? defaults.ignoredRoomNames
        daylightWasteEnabled = try container.decodeIfPresent(Bool.self, forKey: .daylightWasteEnabled) ?? defaults.daylightWasteEnabled
        daylightLuxThreshold = try container.decodeIfPresent(Double.self, forKey: .daylightLuxThreshold) ?? defaults.daylightLuxThreshold
        daylightStartHour = Self.clampedHour(try container.decodeIfPresent(Int.self, forKey: .daylightStartHour) ?? defaults.daylightStartHour)
        daylightEndHour = Self.clampedHour(try container.decodeIfPresent(Int.self, forKey: .daylightEndHour) ?? defaults.daylightEndHour)
        coolingIneffectiveDeltaCelsius = try container.decodeIfPresent(Double.self, forKey: .coolingIneffectiveDeltaCelsius) ?? defaults.coolingIneffectiveDeltaCelsius
        co2RiseThresholdPPM = try container.decodeIfPresent(Double.self, forKey: .co2RiseThresholdPPM) ?? defaults.co2RiseThresholdPPM
    }

    static func load() -> OperationalIntelligencePolicy {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let policy = try? JSONDecoder().decode(OperationalIntelligencePolicy.self, from: data) else {
            return .default
        }
        return policy
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var minimumPowerDuration: TimeInterval {
        min(lightLongOnMinutes, loadLongActiveMinutes) * 60
    }

    var minimumContactDuration: TimeInterval {
        contactOpenMinutes * 60
    }

    var elevatedContactDuration: TimeInterval {
        max(contactEscalationMinutes, contactOpenMinutes) * 60
    }

    /// Confronto stanza normalizzato (case/diacritici-insensitive): "impostazioni"
    /// matcha "Impostazioni". Nil = nessuna stanza → mai ignorata.
    func isRoomIgnored(_ roomName: String?) -> Bool {
        guard let roomName, !ignoredRoomNames.isEmpty else { return false }
        let normalized = Self.normalizedRoomName(roomName)
        return ignoredRoomNames.contains { Self.normalizedRoomName($0) == normalized }
    }

    private static func normalizedRoomName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }
}
