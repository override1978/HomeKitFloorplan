import Foundation

// MARK: - LightingContextAnalyzer

/// Correlates time-of-day with appropriate lighting intents and brightness targets.
///
/// Used by LightingChipsStrip in AccessoryRoomDetailView to surface contextually
/// relevant quick-action chips (e.g. "Luce Serale" at 19:00, "Illumina" at 09:00).
enum LightingContextAnalyzer {

    // MARK: - LightingProfile

    struct LightingProfile {
        /// The time slot this profile applies to.
        let timeSlot: TimeOfDay
        /// Target brightness (0.0–1.0) appropriate for this time of day.
        let recommendedBrightness: Double
        /// Ordered list of lighting intents to surface as quick-action chips.
        let preferredIntents: [ActionIntent]
        /// Short human-readable description shown in the strip header.
        let description: String
    }

    // MARK: - Public API

    /// Returns the lighting profile best suited for the given hour (0–23).
    static func profile(for hour: Int) -> LightingProfile {
        let slot = TimeOfDay(hour: hour)
        switch slot {
        case .earlyMorning:
            return LightingProfile(
                timeSlot:              slot,
                recommendedBrightness: 0.55,
                preferredIntents:      [.brightenRoom],
                description:           String(localized: "lighting.profile.earlyMorning",
                                              defaultValue: "Moderate morning light")
            )
        case .morning:
            return LightingProfile(
                timeSlot:              slot,
                recommendedBrightness: 0.85,
                preferredIntents:      [.brightenRoom],
                description:           String(localized: "lighting.profile.morning",
                                              defaultValue: "Full daytime brightness")
            )
        case .afternoon:
            return LightingProfile(
                timeSlot:              slot,
                recommendedBrightness: 0.75,
                preferredIntents:      [.brightenRoom],
                description:           String(localized: "lighting.profile.afternoon",
                                              defaultValue: "Afternoon light")
            )
        case .evening:
            return LightingProfile(
                timeSlot:              slot,
                recommendedBrightness: 0.35,
                preferredIntents:      [.setCircadianLight, .dimRoom],
                description:           String(localized: "lighting.profile.evening",
                                              defaultValue: "Warm and dim evening light")
            )
        case .night:
            return LightingProfile(
                timeSlot:              slot,
                recommendedBrightness: 0.12,
                preferredIntents:      [.dimRoom],
                description:           String(localized: "lighting.profile.night",
                                              defaultValue: "Dim night light")
            )
        }
    }
}
