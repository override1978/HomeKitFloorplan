import Foundation
import HomeKit

// MARK: - ActionResolver

/// Deterministic resolver that maps [ActionIntent] → [AINextAction].
///
/// Given a list of semantic intents and a room name, the resolver:
/// 1. Finds all accessories in that room via HomeKit
/// 2. Categorizes each accessory using the same logic as AmbientalAIService.describeAccessory()
/// 3. Applies intent allow/forbidden category rules
/// 4. Skips accessories that are already active
/// 5. Sprint 6: sorts candidate accessories by historical effectiveness score (desc)
/// 6. Returns concrete AINextAction values (max 3), falling back to manual tips
@MainActor
final class ActionResolver {

    private let homeKit: HomeKitService
    /// Opzionale: se fornito, i candidati vengono ordinati per effectiveness storica (Sprint 6).
    private let tracker: ActionEffectivenessTracker?

    /// - Parameters:
    ///   - homeKit: HomeKit service for accessory lookup.
    ///   - tracker: Effectiveness tracker for ranking. Nil disables ranking (backward-compatible).
    init(homeKit: HomeKitService, tracker: ActionEffectivenessTracker? = nil) {
        self.homeKit = homeKit
        self.tracker = tracker
    }

    // MARK: - Public API

    /// Resolves a list of intents for a given room into up to 3 concrete AINextAction values.
    /// - Parameters:
    ///   - intents: Semantic intents to resolve.
    ///   - roomName: HomeKit room name used to find accessories.
    ///   - roomType: Room type for room-aware fallback tips. Defaults to `.indoor`.
    func resolve(intents: [ActionIntent], roomName: String, roomType: RoomType = .indoor) -> [AINextAction] {
        let accessories = homeKit.allAccessories.filter { $0.room?.name == roomName }
        let hour = Calendar.current.component(.hour, from: Date())
        let season = CalendarSeason.current
        let isNight = hour >= 19 || hour < 7

        var results: [AINextAction] = []
        var usedAccessoryIDs: Set<UUID> = []

        for intent in intents {
            guard results.count < 3 else { break }

            if intent.nightRestricted && isNight { continue }

            var resolved = false
            var hasEligibleCandidate = false  // true if ≥1 accessory matched category rules

            // Sprint 6: sort candidates by historical effectiveness for this intent (desc).
            // Accessories without history get a neutral prior of 0.5 — not penalised.
            let candidates: [HMAccessory]
            if let tracker {
                candidates = accessories.sorted {
                    tracker.averageEffectiveness(
                        for: intent.rawValue,
                        accessoryID: $0.uniqueIdentifier.uuidString
                    ) > tracker.averageEffectiveness(
                        for: intent.rawValue,
                        accessoryID: $1.uniqueIdentifier.uuidString
                    )
                }
            } else {
                candidates = accessories
            }

            // Phase 6 trace: build candidates list with effectiveness scores
            #if DEBUG
            let traceCandidates: [(name: String, score: Double)] = candidates.map { acc in
                let score = tracker?.averageEffectiveness(
                    for: intent.rawValue,
                    accessoryID: acc.uniqueIdentifier.uuidString
                ) ?? 0.5
                return (name: acc.name, score: score)
            }
            #endif

            var selectedAccessoryName: String? = nil

            for accessory in candidates {
                guard results.count < 3 else { break }
                guard !usedAccessoryIDs.contains(accessory.uniqueIdentifier) else { continue }

                let category = categorize(accessory)
                guard intent.allowedCategories.contains(category) else { continue }
                guard !intent.forbiddenCategories.contains(category) else { continue }

                hasEligibleCandidate = true
                if isAlreadyActive(accessory: accessory, for: intent) { continue }

                guard let action = intent.resolveAction(for: category, season: season, hour: hour)
                else { continue }

                let rawLabel = action.labelKey
                results.append(AINextAction(
                    label: rawLabel,
                    actionType: "suggest",
                    accessoryID: accessory.uniqueIdentifier.uuidString,
                    accessoryActionType: action.actionType,
                    accessoryValue: action.value,
                    accessoryValue2: action.value2,
                    accessoryName: accessory.name
                ))
                usedAccessoryIDs.insert(accessory.uniqueIdentifier)
                resolved = true
                if selectedAccessoryName == nil { selectedAccessoryName = accessory.name }
            }

            // No suitable accessory found — emit a room-type-aware manual tip (nil = suppress).
            // Exception: if eligible accessories exist but are all already active, suppress the tip
            // too — they're already doing their job, no manual advice needed.
            if !resolved && !hasEligibleCandidate && results.count < 3 {
                if let tip = intent.fallbackTip(for: roomType) {
                    results.append(tip)
                    // Phase 6 trace: fallback tip emitted
                    #if DEBUG
                    AITraceLogger.shared.logResolverIntent(
                        roomName: roomName,
                        intent: intent.rawValue,
                        candidates: traceCandidates,
                        selected: tip.label,
                        isFallback: true
                    )
                    #endif
                } else {
                    // Phase 6 trace: suppressed (nil tip for this room type)
                    #if DEBUG
                    AITraceLogger.shared.logResolverIntent(
                        roomName: roomName,
                        intent: intent.rawValue,
                        candidates: traceCandidates,
                        selected: nil,
                        isFallback: false
                    )
                    #endif
                }
            } else if resolved {
                // Phase 6 trace: accessory selected
                #if DEBUG
                AITraceLogger.shared.logResolverIntent(
                    roomName: roomName,
                    intent: intent.rawValue,
                    candidates: traceCandidates,
                    selected: selectedAccessoryName,
                    isFallback: false
                )
                #endif
            }
        }

        return results
    }

    // MARK: - Private: Accessory Categorization

    private func categorize(_ accessory: HMAccessory) -> String {
        AccessoryCategorizer.categorize(accessory)
    }

    // MARK: - Private: Already-Active Check

    /// Returns true if the accessory is already in the state the intent would set it to,
    /// so we avoid suggesting a no-op action.
    private func isAlreadyActive(accessory: HMAccessory, for intent: ActionIntent) -> Bool {
        let allChars = accessory.services.flatMap(\.characteristics)

        func typedValue<T>(_ uuidLower: String) -> T? {
            allChars.first { $0.characteristicType.lowercased() == uuidLower }?.value as? T
        }

        let activeUUID         = HMCharacteristicTypeActive.lowercased()
        let onUUID             = HMCharacteristicTypePowerState.lowercased()
        let targetPositionUUID = HMCharacteristicTypeTargetPosition.lowercased()
        let brightnessUUID     = HMCharacteristicTypeBrightness.lowercased()

        switch intent {
        case .coolRoom:
            let isBlind = categorize(accessory) == "windowCovering"
            if isBlind {
                // For blinds, only TargetPosition == 0 means "already closed".
                // Active/PowerState on blind controllers means "device powered", not "blind closed".
                if let pos: Int = typedValue(targetPositionUUID), pos == 0 { return true }
                if let pos: Double = typedValue(targetPositionUUID), pos == 0 { return true }
                return false
            }
            if let active: Int = typedValue(activeUUID), active == 1 { return true }
            if let on: Bool = typedValue(onUUID), on { return true }
            return false

        case .heatRoom, .reduceHumidity, .increaseHumidity,
             .improveAirQuality, .ventilateRoom, .reduceCO2:
            if let active: Int = typedValue(activeUUID), active == 1 { return true }
            if let on: Bool = typedValue(onUUID), on { return true }
            return false

        case .respondToSmoke, .respondToCO:
            return false

        case .brightenRoom:
            // Skip if brightness is already ≥ 70%
            if let bVal: Int = typedValue(brightnessUUID), bVal >= 70 { return true }
            if let bVal: Double = typedValue(brightnessUUID), bVal >= 70 { return true }
            return false

        case .dimRoom, .setCircadianLight:
            // Skip if brightness is already ≤ 35%
            if let bVal: Int = typedValue(brightnessUUID), bVal <= 35 { return true }
            if let bVal: Double = typedValue(brightnessUUID), bVal <= 35 { return true }
            return false

        case .setScene:
            return false

        case .prepareForArrival:
            return false  // always suggest — arriving home benefits from preparation

        case .secureForDeparture:
            let secCategory = categorize(accessory)
            if secCategory == "doorLock" {
                let lockTargetUUID = "0000001e-0000-1000-8000-0026bb765291"
                if let v: Int = typedValue(lockTargetUUID), v == 1 { return true }
            }
            if secCategory == "garageDoor" {
                let garageDoorTargetUUID = "00000032-0000-1000-8000-0026bb765291"
                if let v: Int = typedValue(garageDoorTargetUUID), v == 1 { return true }
            }
            if let active: Int = typedValue(activeUUID), active == 0 { return true }
            if let on: Bool = typedValue(onUUID), !on { return true }
            if let bVal: Int = typedValue(brightnessUUID), bVal == 0 { return true }
            return false

        case .reduceConsumption:
            // Skip if device is already off
            if let active: Int = typedValue(activeUUID), active == 0 { return true }
            if let on: Bool = typedValue(onUUID), !on { return true }
            if let bVal: Int = typedValue(brightnessUUID), bVal == 0 { return true }
            return false

        case .enableEcoMode:
            return false  // always offer eco mode — setpoint may differ

        case .schedulePeakHours:
            return false  // tip-only

        case .lockAll:
            let lockTargetUUID   = "0000001e-0000-1000-8000-0026bb765291"
            let lockCurrentUUID  = "0000001d-0000-1000-8000-0026bb765291"
            if let v: Int = typedValue(lockTargetUUID),  v == 1 { return true }
            if let v: Int = typedValue(lockCurrentUUID), v == 1 { return true }
            return false

        case .closeGarage:
            let garageTargetUUID  = "00000032-0000-1000-8000-0026bb765291"
            let garageCurrentUUID = "0000000e-0000-1000-8000-0026bb765291"
            if let v: Int = typedValue(garageTargetUUID),  v == 1 { return true }
            if let v: Int = typedValue(garageCurrentUUID), v == 1 { return true }
            return false

        case .armNightSecurity, .armAwaySecurity:
            let armCategory = categorize(accessory)
            if armCategory == "doorLock" {
                let lockTargetUUID = "0000001e-0000-1000-8000-0026bb765291"
                if let v: Int = typedValue(lockTargetUUID), v == 1 { return true }
            }
            if armCategory == "garageDoor" {
                let garageTargetUUID = "00000032-0000-1000-8000-0026bb765291"
                if let v: Int = typedValue(garageTargetUUID), v == 1 { return true }
            }
            return false
        }
    }
}
