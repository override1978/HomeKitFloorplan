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

    static let `default` = OperationalIntelligencePolicy(
        isEnabled: true,
        lightLongOnMinutes: 180,
        loadLongActiveMinutes: 360,
        contactOpenMinutes: 15,
        contactEscalationMinutes: 45,
        escalatesAtNight: true,
        nightStartHour: 22,
        nightEndHour: 7,
        ignoredAccessoryIDs: []
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
        ignoredAccessoryIDs: [String]
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

    private static func clampedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }
}
