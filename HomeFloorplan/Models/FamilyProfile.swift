import Foundation

// MARK: - FamilyProfile

/// A named behavioral profile representing a household member.
/// Profiles let the AI learn separate habit sets for each person.
/// Persisted in UserDefaults — no SwiftData schema migration needed.
struct FamilyProfile: Codable, Identifiable, Hashable {

    var id:             UUID
    var name:           String
    /// One of: "blue", "green", "orange", "purple", "red", "teal".
    var colorToken:     String
    /// UUID string of the linked HMUser, if the user chose to link a HomeKit identity.
    var homeKitUserID:  String?

    init(id: UUID = UUID(), name: String, colorToken: String = "blue", homeKitUserID: String? = nil) {
        self.id            = id
        self.name          = name
        self.colorToken    = colorToken
        self.homeKitUserID = homeKitUserID
    }
}
