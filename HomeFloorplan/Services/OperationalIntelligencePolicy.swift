import Foundation

struct OperationalIntelligencePolicy: Codable, Hashable {
    static let storageKey = "operationalIntelligencePolicy.v1"

    var isEnabled: Bool
    var lightLongOnMinutes: Double
    var loadLongActiveMinutes: Double
    var contactOpenMinutes: Double
    var contactEscalationMinutes: Double
    var escalatesAtNight: Bool
    var ignoredAccessoryIDs: [String]

    static let `default` = OperationalIntelligencePolicy(
        isEnabled: true,
        lightLongOnMinutes: 180,
        loadLongActiveMinutes: 360,
        contactOpenMinutes: 15,
        contactEscalationMinutes: 45,
        escalatesAtNight: true,
        ignoredAccessoryIDs: []
    )

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
}
