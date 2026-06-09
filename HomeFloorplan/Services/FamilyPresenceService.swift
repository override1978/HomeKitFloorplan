import Foundation
import HomeKit
import Observation

// MARK: - FamilyPresenceService

/// Manages the list of household member profiles and tracks who is currently active.
///
/// When an active profile is set, AccessoryEvents are tagged with that profile's ID
/// and BehavioralAnalysisService filters its pattern detection to that profile's
/// event history — enabling distinct behavioral models per family member.
@Observable
@MainActor
final class FamilyPresenceService {

    // MARK: - State

    var profiles:        [FamilyProfile] = []

    /// UUID of the currently active profile, or nil for global (no profile) mode.
    private(set) var activeProfileID: UUID? {
        didSet {
            UserDefaults.standard.set(activeProfileID?.uuidString, forKey: Self.activeKey)
        }
    }

    // MARK: - UserDefaults keys

    static let activeKey   = "family.activeProfileID"
    static let profilesKey = "family.profiles.v1"

    // MARK: - Computed

    var activeProfile: FamilyProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    // MARK: - Init

    init() { loadPersisted() }

    // MARK: - Profile management

    @discardableResult
    func addProfile(name: String, colorToken: String = "blue") -> FamilyProfile {
        let profile = FamilyProfile(id: UUID(), name: name, colorToken: colorToken)
        profiles.append(profile)
        persistProfiles()
        return profile
    }

    func updateProfile(_ profile: FamilyProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        persistProfiles()
    }

    func removeProfile(_ profile: FamilyProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { setActive(nil) }
        persistProfiles()
    }

    /// Sets (or clears) the active profile.
    /// Callers should trigger `BehavioralAnalysisService.switchProfile(to:)` after this.
    func setActive(_ profile: FamilyProfile?) {
        activeProfileID = profile?.id
    }

    // MARK: - Auto-detection

    /// Activates the profile that matches the home owner's HomeKit identity.
    ///
    /// Match priority:
    ///  1. Profile whose `homeKitUserID` equals `home.currentUser.uniqueIdentifier`
    ///  2. Profile whose name matches (case-insensitive) — opportunistically links the HM ID
    ///  3. No profiles exist yet → creates one from the HMUser and activates it
    ///
    /// If profiles exist but none match, nothing is changed (user manages manually).
    func autoActivateForCurrentUser(home: HMHome) {
        let hmUser  = home.currentUser
        let hmIDStr = hmUser.uniqueIdentifier.uuidString
        let hmName  = hmUser.name

        // 1. Exact match via stored HomeKit user ID
        if let match = profiles.first(where: { $0.homeKitUserID == hmIDStr }) {
            if activeProfileID != match.id { setActive(match) }
            return
        }

        // 2. Name match — link the ID for future runs, then activate
        if let idx = profiles.firstIndex(where: {
            $0.name.caseInsensitiveCompare(hmName) == .orderedSame
        }) {
            profiles[idx].homeKitUserID = hmIDStr
            persistProfiles()
            setActive(profiles[idx])
            return
        }

        // 3. No profiles yet — create one for the home owner automatically
        if profiles.isEmpty {
            var newProfile = FamilyProfile(id: UUID(), name: hmName, colorToken: "blue")
            newProfile.homeKitUserID = hmIDStr
            profiles.append(newProfile)
            persistProfiles()
            setActive(newProfile)
        }
    }

    // MARK: - Persistence

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)
    }

    private func loadPersisted() {
        if let data   = UserDefaults.standard.data(forKey: Self.profilesKey),
           let loaded = try? JSONDecoder().decode([FamilyProfile].self, from: data) {
            profiles = loaded
        }
        if let idStr = UserDefaults.standard.string(forKey: Self.activeKey),
           let id    = UUID(uuidString: idStr) {
            activeProfileID = id
        }
    }
}
