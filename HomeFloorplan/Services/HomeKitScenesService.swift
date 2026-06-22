import Foundation
import HomeKit
import Observation

extension HMAction {
    var homeFloorplanCharacteristicWrite: (characteristic: HMCharacteristic, targetValue: Any?)? {
        guard let writeAction = self as? HMCharacteristicWriteAction<NSCopying> else { return nil }
        return (writeAction.characteristic, writeAction.targetValue)
    }
}

struct SceneActionDraftBundle {
    var lightDrafts: [SceneLightActionDraft] = []
    var outletDrafts: [SceneOutletActionDraft] = []
    var switchDrafts: [SceneSwitchActionDraft] = []
    var windowCoveringDrafts: [SceneWindowCoveringActionDraft] = []
    var thermostatDrafts: [SceneThermostatActionDraft] = []
    var airPurifierDrafts: [SceneAirPurifierActionDraft] = []
    var humidifierDrafts: [SceneHumidifierActionDraft] = []
    var securitySystemDrafts: [SceneSecuritySystemActionDraft] = []
    var doorLockDrafts: [SceneDoorLockActionDraft] = []
    var garageDoorDrafts: [SceneGarageDoorActionDraft] = []

    var selectedCount: Int {
        lightDrafts.filter(\.isIncluded).count +
        outletDrafts.filter(\.isIncluded).count +
        switchDrafts.filter(\.isIncluded).count +
        windowCoveringDrafts.filter(\.isIncluded).count +
        thermostatDrafts.filter(\.isIncluded).count +
        airPurifierDrafts.filter(\.isIncluded).count +
        humidifierDrafts.filter(\.isIncluded).count +
        securitySystemDrafts.filter(\.isIncluded).count +
        doorLockDrafts.filter(\.isIncluded).count +
        garageDoorDrafts.filter(\.isIncluded).count
    }

    var isEmpty: Bool {
        selectedCount == 0
    }
}

/// Wrapper di lettura per le scene HomeKit (`HMActionSet`).
/// Separato da HomeKitService per non sovraccaricarlo: scope ridotto a scene.
/// Aggiornamento delle scene tracciato via @Observable.
@MainActor
@Observable
final class HomeKitScenesService {
    var scenes: [SceneItem] = []
    var lastRunError: Error?
    
    private let homeKit: HomeKitService

    /// Logger attività. Iniettato dall'app dopo l'init.
    var activityLogger: ActivityLoggerService?

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }
    
    /// Carica/ricarica la lista delle scene dalla home corrente.
    func refresh() {
        guard let home = homeKit.currentHome else {
            scenes = []
            return
        }
        scenes = home.actionSets
            .map { SceneItem(actionSet: $0) }
            .sorted { $0.displayPriority < $1.displayPriority ||
                     ($0.displayPriority == $1.displayPriority &&
                      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }
    }
    
    /// Scene divise per tipo (built-in vs custom) per il pannello.
    var builtInScenes: [SceneItem] {
        scenes.filter { $0.isBuiltIn }
    }
    
    var customScenes: [SceneItem] {
        scenes.filter { !$0.isBuiltIn }
    }
    
    /// Tutte le stanze coinvolte in almeno una scena, ordinate alfabeticamente.
    /// Usato per popolare le pillole di filtro.
    var representedRooms: [(id: UUID, name: String)] {
        guard let home = homeKit.currentHome else { return [] }
        
        var roomIDs: Set<UUID> = []
        for scene in scenes {
            roomIDs.formUnion(scene.affiliatedRoomIDs)
        }
        
        let rooms = home.rooms.filter { roomIDs.contains($0.uniqueIdentifier) }
        return rooms
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (id: $0.uniqueIdentifier, name: $0.name) }
    }
    
    func run(_ scene: SceneItem) async throws {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitScenesService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(scene.actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Log esecuzione scena
        activityLogger?.logSceneExecution(sceneName: scene.name, actionCount: scene.actionCount)
    }

    func lightActionDrafts(for scene: SceneItem? = nil) -> [SceneLightActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            guard let brightness = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeBrightness) else {
                return nil
            }

            let power = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
            let hue = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeHue)
            let saturation = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeSaturation)
            let colorTemperature = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeColorTemperature)
            let isIncluded = [power, Optional(brightness), hue, saturation, colorTemperature]
                .compactMap { $0?.uniqueIdentifier }
                .contains { existingValues[$0] != nil }
            let currentBrightness = Self.intValue(homeKit.value(for: brightness) ?? brightness.value) ?? 80
            let currentPower = power.flatMap { Self.boolValue(homeKit.value(for: $0) ?? $0.value) } ?? (currentBrightness > 0)
            let existingPower = power.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.boolValue)
            let existingBrightness = existingValues[brightness.uniqueIdentifier].flatMap(Self.intValue)
            let existingHue = hue.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.doubleValue)
            let existingSaturation = saturation.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.doubleValue)
            let existingTemperature = colorTemperature.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.intValue)
            let temperatureRange = Self.colorTemperatureRange(for: colorTemperature)

            return SceneLightActionDraft(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                isIncluded: isIncluded,
                powerOn: existingPower ?? currentPower,
                brightness: existingBrightness ?? max(1, currentBrightness),
                supportsColor: hue != nil && saturation != nil,
                hue: existingHue ?? hue.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) } ?? 45,
                saturation: existingSaturation ?? saturation.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) } ?? 70,
                supportsColorTemperature: colorTemperature != nil,
                colorTemperature: existingTemperature ?? colorTemperature.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) } ?? 250,
                colorTemperatureRange: temperatureRange,
                colorMode: existingTemperature != nil ? .temperature : .color,
                powerCharacteristic: power,
                brightnessCharacteristic: brightness,
                hueCharacteristic: hue,
                saturationCharacteristic: saturation,
                colorTemperatureCharacteristic: colorTemperature
            )
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func outletActionDrafts(for scene: SceneItem? = nil) -> [SceneOutletActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.flatMap { accessory -> [SceneOutletActionDraft] in
            let outletServices = accessory.services.filter { $0.serviceType == MultiOutletAdapter.outletServiceType }
            if !outletServices.isEmpty {
                return outletServices.enumerated().compactMap { index, service in
                    guard let power = service.characteristics.first(where: { $0.characteristicType == MultiOutletAdapter.onCharType }) else {
                        return nil
                    }
                    let existingValue = existingValues[power.uniqueIdentifier].flatMap(Self.boolValue)
                    let currentValue = Self.boolValue(homeKit.value(for: power) ?? power.value) ?? false
                    return SceneOutletActionDraft(
                        id: service.uniqueIdentifier,
                        accessoryID: accessory.uniqueIdentifier,
                        accessoryName: outletDisplayName(for: service, fallbackIndex: index),
                        parentName: outletServices.count > 1 ? accessory.name : nil,
                        roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                        isIncluded: existingValue != nil,
                        powerOn: existingValue ?? currentValue,
                        powerCharacteristic: power
                    )
                }
            }

            guard accessory.services.contains(where: { $0.serviceType == HMServiceTypeOutlet }) ||
                    accessory.category.categoryType == HMAccessoryCategoryTypeOutlet,
                  let power = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
            else {
                return []
            }
            let existingValue = existingValues[power.uniqueIdentifier].flatMap(Self.boolValue)
            let currentValue = Self.boolValue(homeKit.value(for: power) ?? power.value) ?? false
            return [
                SceneOutletActionDraft(
                    id: accessory.uniqueIdentifier,
                    accessoryID: accessory.uniqueIdentifier,
                    accessoryName: accessory.name,
                    parentName: nil,
                    roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                    isIncluded: existingValue != nil,
                    powerOn: existingValue ?? currentValue,
                    powerCharacteristic: power
                )
            ]
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func switchActionDrafts(for scene: SceneItem? = nil) -> [SceneSwitchActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            guard accessory.services.contains(where: { $0.serviceType == HMServiceTypeSwitch }) ||
                    accessory.category.categoryType == HMAccessoryCategoryTypeSwitch,
                  let power = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
                    ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeActive)
            else {
                return nil
            }

            let existingValue = existingValues[power.uniqueIdentifier].flatMap(Self.boolValue)
            let currentValue = Self.boolValue(homeKit.value(for: power) ?? power.value) ?? false
            return SceneSwitchActionDraft(
                id: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                isIncluded: existingValue != nil,
                powerOn: existingValue ?? currentValue,
                powerCharacteristic: power
            )
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func windowCoveringActionDrafts(for scene: SceneItem? = nil) -> [SceneWindowCoveringActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            guard let target = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeTargetPosition),
                  accessory.services.contains(where: { $0.serviceType == HMServiceTypeWindowCovering }) ||
                    accessory.category.categoryType == HMAccessoryCategoryTypeWindowCovering ||
                    accessory.category.categoryType == HMAccessoryCategoryTypeWindow
            else {
                return nil
            }

            let current = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeCurrentPosition)
            let existingValue = existingValues[target.uniqueIdentifier]
                .flatMap(Self.intValue)
                .map {
                    WindowCoveringPositionMapper.logicalPosition(
                        fromRaw: $0,
                        accessoryID: accessory.uniqueIdentifier
                    )
                }
            let currentValueRaw = current.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) }
                ?? Self.intValue(homeKit.value(for: target) ?? target.value)
                ?? 0
            let currentValue = WindowCoveringPositionMapper.logicalPosition(
                fromRaw: currentValueRaw,
                accessoryID: accessory.uniqueIdentifier
            )
            return SceneWindowCoveringActionDraft(
                id: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                isIncluded: existingValue != nil,
                position: existingValue ?? currentValue,
                targetPositionCharacteristic: target
            )
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func thermostatActionDrafts(for scene: SceneItem? = nil) -> [SceneThermostatActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            if let modern = makeHeaterCoolerDraft(for: accessory, existingValues: existingValues) {
                return modern
            }
            return makeLegacyThermostatDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func airPurifierActionDrafts(for scene: SceneItem? = nil) -> [SceneAirPurifierActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            makeAirPurifierDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func humidifierActionDrafts(for scene: SceneItem? = nil) -> [SceneHumidifierActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            makeHumidifierDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func securitySystemActionDrafts(for scene: SceneItem? = nil) -> [SceneSecuritySystemActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            makeSecuritySystemDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func doorLockActionDrafts(for scene: SceneItem? = nil) -> [SceneDoorLockActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            makeDoorLockDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func garageDoorActionDrafts(for scene: SceneItem? = nil) -> [SceneGarageDoorActionDraft] {
        let existingValues = existingSceneValues(for: scene)

        return homeKit.allAccessories.compactMap { accessory in
            makeGarageDoorDraft(for: accessory, existingValues: existingValues)
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    func actionDraftBundle(for scene: SceneItem? = nil) -> SceneActionDraftBundle {
        SceneActionDraftBundle(
            lightDrafts: lightActionDrafts(for: scene),
            outletDrafts: outletActionDrafts(for: scene),
            switchDrafts: switchActionDrafts(for: scene),
            windowCoveringDrafts: windowCoveringActionDrafts(for: scene),
            thermostatDrafts: thermostatActionDrafts(for: scene),
            airPurifierDrafts: airPurifierActionDrafts(for: scene),
            humidifierDrafts: humidifierActionDrafts(for: scene),
            securitySystemDrafts: securitySystemActionDrafts(for: scene),
            doorLockDrafts: doorLockActionDrafts(for: scene),
            garageDoorDrafts: garageDoorActionDrafts(for: scene)
        )
    }

    func makeActions(from bundle: SceneActionDraftBundle) -> [HMAction] {
        makeActions(from: bundle.lightDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.outletDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.switchDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.windowCoveringDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.thermostatDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.airPurifierDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.humidifierDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.securitySystemDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.doorLockDrafts.filter(\.isIncluded))
        + makeActions(from: bundle.garageDoorDrafts.filter(\.isIncluded))
    }

    @discardableResult
    func saveUserScene(
        name: String,
        drafts: [SceneLightActionDraft],
        outletDrafts: [SceneOutletActionDraft] = [],
        switchDrafts: [SceneSwitchActionDraft] = [],
        windowCoveringDrafts: [SceneWindowCoveringActionDraft] = [],
        thermostatDrafts: [SceneThermostatActionDraft] = [],
        airPurifierDrafts: [SceneAirPurifierActionDraft] = [],
        humidifierDrafts: [SceneHumidifierActionDraft] = [],
        securitySystemDrafts: [SceneSecuritySystemActionDraft] = [],
        doorLockDrafts: [SceneDoorLockActionDraft] = [],
        garageDoorDrafts: [SceneGarageDoorActionDraft] = [],
        editing scene: SceneItem?
    ) async throws -> SceneItem {
        try await saveUserScene(
            name: name,
            actionBundle: SceneActionDraftBundle(
                lightDrafts: drafts,
                outletDrafts: outletDrafts,
                switchDrafts: switchDrafts,
                windowCoveringDrafts: windowCoveringDrafts,
                thermostatDrafts: thermostatDrafts,
                airPurifierDrafts: airPurifierDrafts,
                humidifierDrafts: humidifierDrafts,
                securitySystemDrafts: securitySystemDrafts,
                doorLockDrafts: doorLockDrafts,
                garageDoorDrafts: garageDoorDrafts
            ),
            editing: scene
        )
    }

    @discardableResult
    func saveUserScene(
        name: String,
        actionBundle: SceneActionDraftBundle,
        editing scene: SceneItem?
    ) async throws -> SceneItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitScenesService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitScenesService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "scene.editor.error.emptyName", defaultValue: "Scene name is required")])
        }
        let managedCharacteristicIDs = managedCharacteristicIDs(
            drafts: actionBundle.lightDrafts,
            outletDrafts: actionBundle.outletDrafts,
            switchDrafts: actionBundle.switchDrafts,
            windowCoveringDrafts: actionBundle.windowCoveringDrafts,
            thermostatDrafts: actionBundle.thermostatDrafts,
            airPurifierDrafts: actionBundle.airPurifierDrafts,
            humidifierDrafts: actionBundle.humidifierDrafts,
            securitySystemDrafts: actionBundle.securitySystemDrafts,
            doorLockDrafts: actionBundle.doorLockDrafts,
            garageDoorDrafts: actionBundle.garageDoorDrafts
        )

        let actionSet: HMActionSet
        if let scene {
            guard !scene.isBuiltIn else {
                throw NSError(domain: "HomeKitScenesService", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "scene.editor.error.builtin", defaultValue: "Built-in scenes cannot be edited here")])
            }
            actionSet = scene.actionSet
            if trimmed != scene.name {
                try await updateName(trimmed, for: actionSet)
            }
            try await removeActions(from: actionSet, matching: managedCharacteristicIDs)
        } else {
            actionSet = try await addActionSet(named: trimmed, to: home)
        }

        let actions = makeActions(from: actionBundle)
        for action in actions {
            try await add(action, to: actionSet)
        }

        refresh()
        return SceneItem(actionSet: actionSet)
    }

    func deleteUserScene(_ scene: SceneItem) async throws {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitScenesService", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }
        guard !scene.isBuiltIn else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeActionSet(scene.actionSet) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        refresh()
    }

    private func makeActions(from drafts: [SceneLightActionDraft]) -> [HMAction] {
        var actions: [HMAction] = []
        for draft in drafts {
            if let power = draft.powerCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: power, targetValue: NSNumber(value: draft.powerOn)))
            }
            guard draft.powerOn else { continue }

            actions.append(HMCharacteristicWriteAction(characteristic: draft.brightnessCharacteristic,
                                                       targetValue: NSNumber(value: max(1, min(100, draft.brightness)))))
            if draft.colorMode == .color,
               draft.supportsColor,
               let hue = draft.hueCharacteristic,
               let saturation = draft.saturationCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: hue,
                                                           targetValue: NSNumber(value: max(0, min(360, draft.hue)))))
                actions.append(HMCharacteristicWriteAction(characteristic: saturation,
                                                           targetValue: NSNumber(value: max(0, min(100, draft.saturation)))))
            } else if draft.colorMode == .temperature,
                      draft.supportsColorTemperature,
                      let colorTemperature = draft.colorTemperatureCharacteristic {
                let range = draft.colorTemperatureRange
                let value = max(range.lowerBound, min(range.upperBound, draft.colorTemperature))
                actions.append(HMCharacteristicWriteAction(characteristic: colorTemperature,
                                                           targetValue: NSNumber(value: value)))
            }
        }
        return actions
    }

    private func makeActions(from drafts: [SceneOutletActionDraft]) -> [HMAction] {
        drafts.map {
            HMCharacteristicWriteAction(characteristic: $0.powerCharacteristic,
                                        targetValue: NSNumber(value: $0.powerOn))
        }
    }

    private func makeActions(from drafts: [SceneSwitchActionDraft]) -> [HMAction] {
        drafts.map {
            let targetValue: NSNumber = $0.powerCharacteristic.characteristicType == HMCharacteristicTypeActive
                ? NSNumber(value: $0.powerOn ? 1 : 0)
                : NSNumber(value: $0.powerOn)
            return HMCharacteristicWriteAction(characteristic: $0.powerCharacteristic,
                                               targetValue: targetValue)
        }
    }

    private func makeActions(from drafts: [SceneWindowCoveringActionDraft]) -> [HMAction] {
        drafts.map {
            let rawPosition = WindowCoveringPositionMapper.rawPosition(
                forLogicalPosition: $0.position,
                accessoryID: $0.id
            )
            return HMCharacteristicWriteAction(characteristic: $0.targetPositionCharacteristic,
                                               targetValue: NSNumber(value: rawPosition))
        }
    }

    private func makeActions(from drafts: [SceneThermostatActionDraft]) -> [HMAction] {
        var actions: [HMAction] = []
        for draft in drafts {
            switch draft.kind {
            case .heaterCooler:
                if let active = draft.activeCharacteristic {
                    actions.append(HMCharacteristicWriteAction(
                        characteristic: active,
                        targetValue: NSNumber(value: draft.mode == .off ? 0 : 1)
                    ))
                }
                guard draft.mode != .off else { continue }
                if let targetState = draft.targetStateCharacteristic {
                    actions.append(HMCharacteristicWriteAction(
                        characteristic: targetState,
                        targetValue: NSNumber(value: draft.mode.rawValue)
                    ))
                }
                appendThermostatTemperatureActions(for: draft, to: &actions)
                appendThermostatFanSpeedAction(for: draft, to: &actions)

            case .legacyThermostat:
                if let targetState = draft.targetStateCharacteristic {
                    let raw: Int
                    switch draft.mode {
                    case .off: raw = 0
                    case .heat: raw = 1
                    case .cool: raw = 2
                    case .auto: raw = 3
                    }
                    actions.append(HMCharacteristicWriteAction(characteristic: targetState, targetValue: NSNumber(value: raw)))
                }
                guard draft.mode != .off else { continue }
                appendThermostatTemperatureActions(for: draft, to: &actions)
                appendThermostatFanSpeedAction(for: draft, to: &actions)
            }
        }
        return actions
    }

    private func makeActions(from drafts: [SceneAirPurifierActionDraft]) -> [HMAction] {
        var actions: [HMAction] = []
        for draft in drafts {
            actions.append(HMCharacteristicWriteAction(
                characteristic: draft.activeCharacteristic,
                targetValue: NSNumber(value: draft.powerOn ? 1 : 0)
            ))
            guard draft.powerOn else { continue }

            actions.append(HMCharacteristicWriteAction(
                characteristic: draft.targetStateCharacteristic,
                targetValue: NSNumber(value: draft.mode.rawValue)
            ))

            if draft.mode == .manual,
               let rotationSpeed = draft.rotationSpeedCharacteristic {
                actions.append(HMCharacteristicWriteAction(
                    characteristic: rotationSpeed,
                    targetValue: NSNumber(value: max(draft.fanRange.lowerBound, min(draft.fanRange.upperBound, draft.fanSpeed)))
                ))
            }
        }
        return actions
    }

    private func makeActions(from drafts: [SceneHumidifierActionDraft]) -> [HMAction] {
        var actions: [HMAction] = []
        for draft in drafts {
            actions.append(HMCharacteristicWriteAction(
                characteristic: draft.activeCharacteristic,
                targetValue: NSNumber(value: draft.powerOn ? 1 : 0)
            ))
            guard draft.powerOn else { continue }

            if let targetState = draft.targetStateCharacteristic {
                actions.append(HMCharacteristicWriteAction(
                    characteristic: targetState,
                    targetValue: NSNumber(value: draft.mode.rawValue)
                ))
            }

            if let targetHumidity = humidifierThreshold(for: draft) {
                let clamped = min(max(draft.targetHumidity, draft.targetHumidityRange.lowerBound), draft.targetHumidityRange.upperBound)
                actions.append(HMCharacteristicWriteAction(
                    characteristic: targetHumidity,
                    targetValue: NSNumber(value: clamped)
                ))
            }
        }
        return actions
    }

    private func makeActions(from drafts: [SceneSecuritySystemActionDraft]) -> [HMAction] {
        drafts.map {
            HMCharacteristicWriteAction(
                characteristic: $0.targetStateCharacteristic,
                targetValue: NSNumber(value: $0.mode.rawValue)
            )
        }
    }

    private func makeActions(from drafts: [SceneDoorLockActionDraft]) -> [HMAction] {
        drafts.map {
            HMCharacteristicWriteAction(
                characteristic: $0.targetStateCharacteristic,
                targetValue: NSNumber(value: $0.locked ? DoorLockTargetState.secured.rawValue : DoorLockTargetState.unsecured.rawValue)
            )
        }
    }

    private func makeActions(from drafts: [SceneGarageDoorActionDraft]) -> [HMAction] {
        drafts.map {
            HMCharacteristicWriteAction(
                characteristic: $0.targetStateCharacteristic,
                targetValue: NSNumber(value: $0.open ? GarageDoorTargetState.open.rawValue : GarageDoorTargetState.closed.rawValue)
            )
        }
    }

    private func appendThermostatTemperatureActions(for draft: SceneThermostatActionDraft, to actions: inout [HMAction]) {
        let value = min(max(draft.targetTemperature, draft.targetRange.lowerBound), draft.targetRange.upperBound)
        switch draft.mode {
        case .heat:
            if let heating = draft.heatingThresholdCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: heating, targetValue: NSNumber(value: value)))
            } else if let target = draft.targetTemperatureCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: target, targetValue: NSNumber(value: value)))
            }
        case .cool:
            if let cooling = draft.coolingThresholdCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: cooling, targetValue: NSNumber(value: value)))
            } else if let target = draft.targetTemperatureCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: target, targetValue: NSNumber(value: value)))
            }
        case .auto:
            if let heating = draft.heatingThresholdCharacteristic,
               let cooling = draft.coolingThresholdCharacteristic {
                actions.append(HMCharacteristicWriteAction(
                    characteristic: heating,
                    targetValue: NSNumber(value: max(draft.targetRange.lowerBound, value - ThermostatAdapter.autoBand))
                ))
                actions.append(HMCharacteristicWriteAction(
                    characteristic: cooling,
                    targetValue: NSNumber(value: min(draft.targetRange.upperBound, value + ThermostatAdapter.autoBand))
                ))
            }
            if let target = draft.targetTemperatureCharacteristic {
                actions.append(HMCharacteristicWriteAction(characteristic: target, targetValue: NSNumber(value: value)))
            }
        case .off:
            break
        }
    }

    private func appendThermostatFanSpeedAction(for draft: SceneThermostatActionDraft, to actions: inout [HMAction]) {
        guard let rotationSpeed = draft.rotationSpeedCharacteristic else { return }
        let value = max(draft.fanRange.lowerBound, min(draft.fanRange.upperBound, draft.fanSpeed))
        actions.append(HMCharacteristicWriteAction(
            characteristic: rotationSpeed,
            targetValue: NSNumber(value: value)
        ))
    }

    private func existingSceneValues(for scene: SceneItem?) -> [UUID: Any?] {
        guard let scene else { return [:] }
        var values: [UUID: Any?] = [:]
        for action in scene.actionSet.actions {
            guard let write = action.homeFloorplanCharacteristicWrite else { continue }
            values[write.characteristic.uniqueIdentifier] = write.targetValue
        }
        return values
    }

    private func managedCharacteristicIDs(
        drafts: [SceneLightActionDraft],
        outletDrafts: [SceneOutletActionDraft],
        switchDrafts: [SceneSwitchActionDraft],
        windowCoveringDrafts: [SceneWindowCoveringActionDraft],
        thermostatDrafts: [SceneThermostatActionDraft],
        airPurifierDrafts: [SceneAirPurifierActionDraft],
        humidifierDrafts: [SceneHumidifierActionDraft],
        securitySystemDrafts: [SceneSecuritySystemActionDraft],
        doorLockDrafts: [SceneDoorLockActionDraft],
        garageDoorDrafts: [SceneGarageDoorActionDraft]
    ) -> Set<UUID> {
        var ids = Set<UUID>()

        for draft in drafts {
            [
                draft.powerCharacteristic,
                Optional(draft.brightnessCharacteristic),
                draft.hueCharacteristic,
                draft.saturationCharacteristic,
                draft.colorTemperatureCharacteristic
            ]
                .compactMap { $0?.uniqueIdentifier }
                .forEach { ids.insert($0) }
        }

        outletDrafts.forEach { ids.insert($0.powerCharacteristic.uniqueIdentifier) }
        switchDrafts.forEach { ids.insert($0.powerCharacteristic.uniqueIdentifier) }
        windowCoveringDrafts.forEach { ids.insert($0.targetPositionCharacteristic.uniqueIdentifier) }

        for draft in thermostatDrafts {
            [
                draft.activeCharacteristic,
                draft.targetStateCharacteristic,
                draft.targetTemperatureCharacteristic,
                draft.heatingThresholdCharacteristic,
                draft.coolingThresholdCharacteristic,
                draft.rotationSpeedCharacteristic
            ]
                .compactMap { $0?.uniqueIdentifier }
                .forEach { ids.insert($0) }
        }

        for draft in airPurifierDrafts {
            [
                Optional(draft.activeCharacteristic),
                Optional(draft.targetStateCharacteristic),
                draft.rotationSpeedCharacteristic
            ]
                .compactMap { $0?.uniqueIdentifier }
                .forEach { ids.insert($0) }
        }

        for draft in humidifierDrafts {
            [
                Optional(draft.activeCharacteristic),
                draft.targetStateCharacteristic,
                draft.humidifierThresholdCharacteristic,
                draft.dehumidifierThresholdCharacteristic
            ]
                .compactMap { $0?.uniqueIdentifier }
                .forEach { ids.insert($0) }
        }

        securitySystemDrafts.forEach { ids.insert($0.targetStateCharacteristic.uniqueIdentifier) }
        doorLockDrafts.forEach { ids.insert($0.targetStateCharacteristic.uniqueIdentifier) }
        garageDoorDrafts.forEach { ids.insert($0.targetStateCharacteristic.uniqueIdentifier) }

        return ids
    }

    private func outletDisplayName(for service: HMService, fallbackIndex: Int) -> String {
        if let nameCh = service.characteristics.first(where: { $0.characteristicType == MultiOutletAdapter.nameCharType }),
           let value = homeKit.value(for: nameCh) as? String,
           !value.isEmpty {
            return value
        }
        return service.name.isEmpty
            ? "\(String(localized: "outlet.name.fallback", defaultValue: "Presa")) \(fallbackIndex + 1)"
            : service.name
    }

    private func makeHeaterCoolerDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneThermostatActionDraft? {
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let targetStateUUID = "000000B2-0000-1000-8000-0026BB765291"
        let currentTempUUID = "00000011-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"

        guard let active = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: activeUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID),
              AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentTempUUID) != nil
        else { return nil }

        let heating = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: heatingThresholdUUID)
        let cooling = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: coolingThresholdUUID)
        let rotationSpeed = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: rotationSpeedUUID)
        guard heating != nil || cooling != nil else { return nil }

        let isActive = Self.intValue(homeKit.value(for: active) ?? active.value) == 1
        let currentModeRaw = Self.intValue(homeKit.value(for: targetState) ?? targetState.value) ?? 0
        let mode = existingValues[active.uniqueIdentifier].flatMap(Self.intValue) == 0
            ? HeaterCoolerMode.off
            : existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue).flatMap(HeaterCoolerMode.init(rawValue:))
                ?? (isActive ? HeaterCoolerMode(rawValue: currentModeRaw) ?? .auto : .off)
        let target = existingThermostatTarget(existingValues: existingValues, heating: heating, cooling: cooling, target: nil)
            ?? currentThermostatTarget(mode: mode, heating: heating, cooling: cooling, target: nil)
        let existingFan = rotationSpeed.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.intValue)
        let currentFan = rotationSpeed.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) } ?? 50

        return SceneThermostatActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: [active, targetState, heating, cooling, rotationSpeed].compactMap { $0?.uniqueIdentifier }.contains { existingValues[$0] != nil },
            kind: .heaterCooler,
            mode: mode,
            supportedModes: heaterCoolerSupportedModes(targetState: targetState, heating: heating, cooling: cooling),
            targetTemperature: target,
            targetRange: thermostatRange(source: heating ?? cooling),
            temperatureStep: thermostatStep(source: heating ?? cooling),
            fanSpeed: existingFan ?? currentFan,
            fanRange: airPurifierFanRange(source: rotationSpeed),
            fanStep: airPurifierFanStep(source: rotationSpeed),
            activeCharacteristic: active,
            targetStateCharacteristic: targetState,
            targetTemperatureCharacteristic: nil,
            heatingThresholdCharacteristic: heating,
            coolingThresholdCharacteristic: cooling,
            rotationSpeedCharacteristic: rotationSpeed
        )
    }

    private func makeLegacyThermostatDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneThermostatActionDraft? {
        let currentTempUUID = "00000011-0000-1000-8000-0026BB765291"
        let targetTempUUID = "00000035-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000033-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"

        guard AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentTempUUID) != nil,
              let target = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetTempUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }

        let heating = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: heatingThresholdUUID)
        let cooling = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: coolingThresholdUUID)
        let rotationSpeed = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: rotationSpeedUUID)
        let modeRaw = existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue)
            ?? Self.intValue(homeKit.value(for: targetState) ?? targetState.value)
            ?? 0
        let mode: HeaterCoolerMode = {
            switch modeRaw {
            case 1: return .heat
            case 2: return .cool
            case 3: return .auto
            default: return .off
            }
        }()
        let targetValue = existingThermostatTarget(existingValues: existingValues, heating: heating, cooling: cooling, target: target)
            ?? currentThermostatTarget(mode: mode, heating: heating, cooling: cooling, target: target)
        let existingFan = rotationSpeed.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.intValue)
        let currentFan = rotationSpeed.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) } ?? 50

        return SceneThermostatActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: [targetState, Optional(target), heating, cooling, rotationSpeed].compactMap { $0?.uniqueIdentifier }.contains { existingValues[$0] != nil },
            kind: .legacyThermostat,
            mode: mode,
            supportedModes: legacyThermostatSupportedModes(targetState: targetState),
            targetTemperature: targetValue,
            targetRange: thermostatRange(source: target),
            temperatureStep: thermostatStep(source: target),
            fanSpeed: existingFan ?? currentFan,
            fanRange: airPurifierFanRange(source: rotationSpeed),
            fanStep: airPurifierFanStep(source: rotationSpeed),
            activeCharacteristic: nil,
            targetStateCharacteristic: targetState,
            targetTemperatureCharacteristic: target,
            heatingThresholdCharacteristic: heating,
            coolingThresholdCharacteristic: cooling,
            rotationSpeedCharacteristic: rotationSpeed
        )
    }

    private func makeAirPurifierDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneAirPurifierActionDraft? {
        let purifierServiceUUID = "000000BB-0000-1000-8000-0026BB765291"
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let targetStateUUID = "000000A8-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"

        guard accessory.services.contains(where: { $0.serviceType == purifierServiceUUID }),
              let active = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: activeUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }

        let rotationSpeed = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: rotationSpeedUUID)
        let existingActive = existingValues[active.uniqueIdentifier].flatMap(Self.intValue)
        let currentActive = Self.intValue(homeKit.value(for: active) ?? active.value) ?? 0
        let existingModeRaw = existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue)
        let currentModeRaw = Self.intValue(homeKit.value(for: targetState) ?? targetState.value) ?? AirPurifierMode.manual.rawValue
        let existingFan = rotationSpeed.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.intValue)
        let currentFan = rotationSpeed.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) } ?? 50
        let fanRange = airPurifierFanRange(source: rotationSpeed)
        let includedIDs = [active, targetState, rotationSpeed].compactMap { $0?.uniqueIdentifier }

        return SceneAirPurifierActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: includedIDs.contains { existingValues[$0] != nil },
            powerOn: (existingActive ?? currentActive) == 1,
            mode: AirPurifierMode(rawValue: existingModeRaw ?? currentModeRaw) ?? .manual,
            supportedModes: airPurifierSupportedModes(targetState: targetState),
            fanSpeed: min(max(existingFan ?? currentFan, fanRange.lowerBound), fanRange.upperBound),
            fanRange: fanRange,
            fanStep: airPurifierFanStep(source: rotationSpeed),
            activeCharacteristic: active,
            targetStateCharacteristic: targetState,
            rotationSpeedCharacteristic: rotationSpeed
        )
    }

    private func makeHumidifierDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneHumidifierActionDraft? {
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let targetStateUUID = "000000B4-0000-1000-8000-0026BB765291"
        let humidifierThresholdUUID = "000000CA-0000-1000-8000-0026BB765291"
        let dehumidifierThresholdUUID = "000000C9-0000-1000-8000-0026BB765291"

        guard let service = accessory.services.first(where: { $0.serviceType == HumidifierAdapter.serviceType }),
              let active = service.characteristics.first(where: { $0.characteristicType == activeUUID })
        else { return nil }

        let targetState = service.characteristics.first(where: { $0.characteristicType == targetStateUUID })
        let humidifierThresholdCharacteristic = service.characteristics.first(where: { $0.characteristicType == humidifierThresholdUUID })
        let dehumidifierThresholdCharacteristic = service.characteristics.first(where: { $0.characteristicType == dehumidifierThresholdUUID })
        let existingActive = existingValues[active.uniqueIdentifier].flatMap(Self.intValue)
        let currentActive = Self.intValue(homeKit.value(for: active) ?? active.value) ?? 0
        let existingModeRaw = targetState.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.intValue)
        let currentModeRaw = targetState.flatMap { Self.intValue(homeKit.value(for: $0) ?? $0.value) } ?? HumidifierMode.humidify.rawValue
        let mode = HumidifierMode(rawValue: existingModeRaw ?? currentModeRaw) ?? .humidify
        let threshold = humidifierThreshold(
            for: mode,
            humidifier: humidifierThresholdCharacteristic,
            dehumidifier: dehumidifierThresholdCharacteristic
        )
        let fallbackThreshold = humidifierThresholdCharacteristic ?? dehumidifierThresholdCharacteristic
        let targetHumidity = threshold.flatMap { existingValues[$0.uniqueIdentifier] }.flatMap(Self.doubleValue)
            ?? threshold.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) }
            ?? 50
        let range = humidityRange(source: threshold ?? fallbackThreshold)
        let includedIDs = [active, targetState, humidifierThresholdCharacteristic, dehumidifierThresholdCharacteristic].compactMap { $0?.uniqueIdentifier }

        return SceneHumidifierActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: includedIDs.contains { existingValues[$0] != nil },
            powerOn: (existingActive ?? currentActive) == 1,
            mode: mode,
            supportedModes: humidifierSupportedModes(
                targetState: targetState,
                hasHumidifierThreshold: humidifierThresholdCharacteristic != nil,
                hasDehumidifierThreshold: dehumidifierThresholdCharacteristic != nil
            ),
            targetHumidity: min(max(targetHumidity, range.lowerBound), range.upperBound),
            targetHumidityRange: range,
            targetHumidityStep: humidityStep(source: threshold ?? fallbackThreshold),
            activeCharacteristic: active,
            targetStateCharacteristic: targetState,
            humidifierThresholdCharacteristic: humidifierThresholdCharacteristic,
            dehumidifierThresholdCharacteristic: dehumidifierThresholdCharacteristic
        )
    }

    private func makeSecuritySystemDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneSecuritySystemActionDraft? {
        let serviceType = "0000007E-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000067-0000-1000-8000-0026BB765291"

        guard let service = accessory.services.first(where: { $0.serviceType == serviceType }),
              let targetState = service.characteristics.first(where: { $0.characteristicType == targetStateUUID })
                ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }

        let existingModeRaw = existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue)
        let currentModeRaw = Self.intValue(homeKit.value(for: targetState) ?? targetState.value) ?? SecurityMode.disarm.rawValue
        return SceneSecuritySystemActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: existingModeRaw != nil,
            mode: SecurityMode(rawValue: existingModeRaw ?? currentModeRaw) ?? .disarm,
            supportedModes: securitySupportedModes(targetState: targetState),
            targetStateCharacteristic: targetState
        )
    }

    private func makeDoorLockDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneDoorLockActionDraft? {
        let serviceType = "00000045-0000-1000-8000-0026BB765291"
        let targetStateUUID = "0000001E-0000-1000-8000-0026BB765291"

        guard let service = accessory.services.first(where: { $0.serviceType == serviceType }),
              let targetState = service.characteristics.first(where: { $0.characteristicType == targetStateUUID })
                ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }

        let existingRaw = existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue)
        let currentRaw = Self.intValue(homeKit.value(for: targetState) ?? targetState.value) ?? DoorLockTargetState.secured.rawValue
        return SceneDoorLockActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: existingRaw != nil,
            locked: (existingRaw ?? currentRaw) == DoorLockTargetState.secured.rawValue,
            targetStateCharacteristic: targetState
        )
    }

    private func makeGarageDoorDraft(for accessory: HMAccessory, existingValues: [UUID: Any?]) -> SceneGarageDoorActionDraft? {
        let serviceType = "00000041-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000032-0000-1000-8000-0026BB765291"

        guard let service = accessory.services.first(where: { $0.serviceType == serviceType }),
              let targetState = service.characteristics.first(where: { $0.characteristicType == targetStateUUID })
                ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }

        let existingRaw = existingValues[targetState.uniqueIdentifier].flatMap(Self.intValue)
        let currentRaw = Self.intValue(homeKit.value(for: targetState) ?? targetState.value) ?? GarageDoorTargetState.closed.rawValue
        return SceneGarageDoorActionDraft(
            id: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
            isIncluded: existingRaw != nil,
            open: (existingRaw ?? currentRaw) == GarageDoorTargetState.open.rawValue,
            targetStateCharacteristic: targetState
        )
    }

    private func existingThermostatTarget(existingValues: [UUID: Any?], heating: HMCharacteristic?, cooling: HMCharacteristic?, target: HMCharacteristic?) -> Double? {
        if let h = heating, let c = cooling,
           let hv = existingValues[h.uniqueIdentifier].flatMap(Self.doubleValue),
           let cv = existingValues[c.uniqueIdentifier].flatMap(Self.doubleValue) {
            return (hv + cv) / 2
        }
        if let target {
            return existingValues[target.uniqueIdentifier].flatMap(Self.doubleValue)
        }
        if let h = heating {
            return existingValues[h.uniqueIdentifier].flatMap(Self.doubleValue)
        }
        if let c = cooling {
            return existingValues[c.uniqueIdentifier].flatMap(Self.doubleValue)
        }
        return nil
    }

    private func currentThermostatTarget(mode: HeaterCoolerMode, heating: HMCharacteristic?, cooling: HMCharacteristic?, target: HMCharacteristic?) -> Double {
        switch mode {
        case .heat:
            return heating.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) }
                ?? target.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) }
                ?? 21
        case .cool:
            return cooling.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) }
                ?? target.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) }
                ?? 24
        default:
            if let h = heating, let c = cooling,
               let hv = Self.doubleValue(homeKit.value(for: h) ?? h.value),
               let cv = Self.doubleValue(homeKit.value(for: c) ?? c.value) {
                return (hv + cv) / 2
            }
            return target.flatMap { Self.doubleValue(homeKit.value(for: $0) ?? $0.value) } ?? 22
        }
    }

    private func heaterCoolerSupportedModes(targetState: HMCharacteristic, heating: HMCharacteristic?, cooling: HMCharacteristic?) -> [HeaterCoolerMode] {
        let validRaw = targetState.metadata?.validValues as? [NSNumber] ?? []
        var modes: [HeaterCoolerMode] = []
        if validRaw.contains(0) || validRaw.isEmpty { modes.append(.auto) }
        if (validRaw.contains(1) || validRaw.isEmpty), heating != nil { modes.append(.heat) }
        if (validRaw.contains(2) || validRaw.isEmpty), cooling != nil { modes.append(.cool) }
        modes.append(.off)
        return modes
    }

    private func legacyThermostatSupportedModes(targetState: HMCharacteristic) -> [HeaterCoolerMode] {
        let validRaw = targetState.metadata?.validValues as? [NSNumber] ?? []
        var modes: [HeaterCoolerMode] = []
        if validRaw.contains(3) || validRaw.isEmpty { modes.append(.auto) }
        if validRaw.contains(1) || validRaw.isEmpty { modes.append(.heat) }
        if validRaw.contains(2) || validRaw.isEmpty { modes.append(.cool) }
        modes.append(.off)
        return modes
    }

    private func thermostatRange(source: HMCharacteristic?) -> ClosedRange<Double> {
        let min = source?.metadata?.minimumValue?.doubleValue ?? 10
        let max = source?.metadata?.maximumValue?.doubleValue ?? 38
        return min...max
    }

    private func thermostatStep(source: HMCharacteristic?) -> Double {
        let step = source?.metadata?.stepValue?.doubleValue ?? 0.5
        return max(step, 0.5)
    }

    private func airPurifierSupportedModes(targetState: HMCharacteristic) -> [AirPurifierMode] {
        let validRaw = targetState.metadata?.validValues as? [NSNumber] ?? []
        var modes: [AirPurifierMode] = []
        if validRaw.contains(0) || validRaw.isEmpty { modes.append(.manual) }
        if validRaw.contains(1) || validRaw.isEmpty { modes.append(.auto) }
        return modes.isEmpty ? [.manual] : modes
    }

    private func airPurifierFanRange(source: HMCharacteristic?) -> ClosedRange<Int> {
        let min = source?.metadata?.minimumValue?.intValue ?? 0
        let max = source?.metadata?.maximumValue?.intValue ?? 100
        return min...Swift.max(max, min)
    }

    private func airPurifierFanStep(source: HMCharacteristic?) -> Int {
        max(source?.metadata?.stepValue?.intValue ?? 10, 1)
    }

    private func humidifierSupportedModes(targetState: HMCharacteristic?, hasHumidifierThreshold: Bool, hasDehumidifierThreshold: Bool) -> [HumidifierMode] {
        guard let targetState else {
            return hasDehumidifierThreshold && !hasHumidifierThreshold ? [.dehumidify] : [.humidify]
        }

        let validRaw = targetState.metadata?.validValues as? [NSNumber] ?? []
        let modes = HumidifierMode.allCases.filter { mode in
            if !validRaw.isEmpty {
                return validRaw.contains(NSNumber(value: mode.rawValue))
            }
            return true
        }
        return modes.isEmpty ? [.humidify] : modes
    }

    private func humidifierThreshold(for draft: SceneHumidifierActionDraft) -> HMCharacteristic? {
        humidifierThreshold(
            for: draft.mode,
            humidifier: draft.humidifierThresholdCharacteristic,
            dehumidifier: draft.dehumidifierThresholdCharacteristic
        )
    }

    private func humidifierThreshold(for mode: HumidifierMode, humidifier: HMCharacteristic?, dehumidifier: HMCharacteristic?) -> HMCharacteristic? {
        switch mode {
        case .dehumidify:
            return dehumidifier ?? humidifier
        case .auto, .humidify:
            return humidifier ?? dehumidifier
        }
    }

    private func humidityRange(source: HMCharacteristic?) -> ClosedRange<Double> {
        let min = source?.metadata?.minimumValue?.doubleValue ?? 0
        let max = source?.metadata?.maximumValue?.doubleValue ?? 100
        return min...Swift.max(max, min)
    }

    private func humidityStep(source: HMCharacteristic?) -> Double {
        max(source?.metadata?.stepValue?.doubleValue ?? 1, 1)
    }

    private func securitySupportedModes(targetState: HMCharacteristic) -> [SecurityMode] {
        let validRaw = targetState.metadata?.validValues as? [NSNumber] ?? []
        let modes = SecurityMode.allCases.filter { mode in
            validRaw.isEmpty || validRaw.contains(NSNumber(value: mode.rawValue))
        }
        return modes.isEmpty ? [.stay, .away, .night, .disarm] : modes
    }

    private func addActionSet(named name: String, to home: HMHome) async throws -> HMActionSet {
        try await withCheckedThrowingContinuation { continuation in
            home.addActionSet(withName: name) { actionSet, error in
                if let error { continuation.resume(throwing: error) }
                else if let actionSet { continuation.resume(returning: actionSet) }
                else {
                    continuation.resume(throwing: NSError(domain: "HomeKitScenesService", code: 6,
                                                          userInfo: [NSLocalizedDescriptionKey: "HomeKit did not return a scene"]))
                }
            }
        }
    }

    private func add(_ action: HMAction, to actionSet: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.addAction(action) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func removeActions(from actionSet: HMActionSet, matching characteristicIDs: Set<UUID>) async throws {
        guard !characteristicIDs.isEmpty else { return }
        for action in Array(actionSet.actions) {
            guard let write = action.homeFloorplanCharacteristicWrite,
                  characteristicIDs.contains(write.characteristic.uniqueIdentifier)
            else { continue }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                actionSet.removeAction(action) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    private func updateName(_ name: String, for actionSet: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.updateName(name) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let u = raw as? UInt8 { return Int(u) }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let f = raw as? Float { return Double(f) }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let i = raw as? Int { return i != 0 }
        return nil
    }

    private static func colorTemperatureRange(for characteristic: HMCharacteristic?) -> ClosedRange<Int> {
        let minValue = characteristic?.metadata?.minimumValue?.intValue ?? 140
        let maxValue = characteristic?.metadata?.maximumValue?.intValue ?? 500
        return minValue...max(maxValue, minValue)
    }
}

enum SceneLightColorMode: String, CaseIterable, Identifiable {
    case color
    case temperature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return String(localized: "scene.editor.colorMode.color", defaultValue: "Color")
        case .temperature: return String(localized: "scene.editor.colorMode.temperature", defaultValue: "Temperature")
        }
    }
}

struct SceneLightActionDraft: Identifiable {
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var powerOn: Bool
    var brightness: Int
    let supportsColor: Bool
    var hue: Double
    var saturation: Double
    let supportsColorTemperature: Bool
    var colorTemperature: Int
    let colorTemperatureRange: ClosedRange<Int>
    var colorMode: SceneLightColorMode
    let powerCharacteristic: HMCharacteristic?
    let brightnessCharacteristic: HMCharacteristic
    let hueCharacteristic: HMCharacteristic?
    let saturationCharacteristic: HMCharacteristic?
    let colorTemperatureCharacteristic: HMCharacteristic?

    var id: UUID { accessoryID }
}

struct SceneOutletActionDraft: Identifiable {
    let id: UUID
    let accessoryID: UUID
    let accessoryName: String
    let parentName: String?
    let roomName: String
    var isIncluded: Bool
    var powerOn: Bool
    let powerCharacteristic: HMCharacteristic
}

struct SceneSwitchActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var powerOn: Bool
    let powerCharacteristic: HMCharacteristic
}

struct SceneWindowCoveringActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var position: Int
    let targetPositionCharacteristic: HMCharacteristic
}

enum SceneThermostatKind {
    case heaterCooler
    case legacyThermostat
}

struct SceneThermostatActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    let kind: SceneThermostatKind
    var mode: HeaterCoolerMode
    let supportedModes: [HeaterCoolerMode]
    var targetTemperature: Double
    let targetRange: ClosedRange<Double>
    let temperatureStep: Double
    var fanSpeed: Int
    let fanRange: ClosedRange<Int>
    let fanStep: Int
    let activeCharacteristic: HMCharacteristic?
    let targetStateCharacteristic: HMCharacteristic?
    let targetTemperatureCharacteristic: HMCharacteristic?
    let heatingThresholdCharacteristic: HMCharacteristic?
    let coolingThresholdCharacteristic: HMCharacteristic?
    let rotationSpeedCharacteristic: HMCharacteristic?
}

struct SceneAirPurifierActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var powerOn: Bool
    var mode: AirPurifierMode
    let supportedModes: [AirPurifierMode]
    var fanSpeed: Int
    let fanRange: ClosedRange<Int>
    let fanStep: Int
    let activeCharacteristic: HMCharacteristic
    let targetStateCharacteristic: HMCharacteristic
    let rotationSpeedCharacteristic: HMCharacteristic?
}

struct SceneHumidifierActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var powerOn: Bool
    var mode: HumidifierMode
    let supportedModes: [HumidifierMode]
    var targetHumidity: Double
    let targetHumidityRange: ClosedRange<Double>
    let targetHumidityStep: Double
    let activeCharacteristic: HMCharacteristic
    let targetStateCharacteristic: HMCharacteristic?
    let humidifierThresholdCharacteristic: HMCharacteristic?
    let dehumidifierThresholdCharacteristic: HMCharacteristic?
}

struct SceneSecuritySystemActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var mode: SecurityMode
    let supportedModes: [SecurityMode]
    let targetStateCharacteristic: HMCharacteristic
}

struct SceneDoorLockActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var locked: Bool
    let targetStateCharacteristic: HMCharacteristic
}

struct SceneGarageDoorActionDraft: Identifiable {
    let id: UUID
    let accessoryName: String
    let roomName: String
    var isIncluded: Bool
    var open: Bool
    let targetStateCharacteristic: HMCharacteristic
}

/// Modello UI per una scena HomeKit.
struct SceneItem: Identifiable {
    let actionSet: HMActionSet
    var displayNameOverride: String?
    
    var id: UUID { actionSet.uniqueIdentifier }
    var name: String {
        if let displayNameOverride,
           !displayNameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayNameOverride
        }

        let trimmed = actionSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }

        switch actionSet.actionSetType {
        case HMActionSetTypeHomeArrival:
            return String(localized: "scene.builtin.homeArrival", defaultValue: "Arrive Home")
        case HMActionSetTypeHomeDeparture:
            return String(localized: "scene.builtin.homeDeparture", defaultValue: "Leave Home")
        case HMActionSetTypeSleep:
            return String(localized: "scene.builtin.sleep", defaultValue: "Good Night")
        case HMActionSetTypeWakeUp:
            return String(localized: "scene.builtin.wakeUp", defaultValue: "Wake Up")
        default:
            return String(localized: "scene.linked", defaultValue: "Linked Scene")
        }
    }
    var hasGenericDisplayName: Bool {
        let trimmed = actionSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty && actionSet.actionSetType == HMActionSetTypeUserDefined
    }
    var isBuiltIn: Bool { actionSet.actionSetType != HMActionSetTypeUserDefined }
    
    /// Numero di azioni dentro la scena (per badge informativi).
    var actionCount: Int { actionSet.actions.count }
    
    /// SF Symbol per la scena. Per scene built-in usa il simbolo del tipo;
    /// per scene custom usa l'inferenza dal nome.
    var symbolName: String {
        switch actionSet.actionSetType {
        case HMActionSetTypeHomeArrival:    return "house.fill"
        case HMActionSetTypeHomeDeparture:  return "figure.walk.departure"
        case HMActionSetTypeSleep:          return "bed.double.fill"
        case HMActionSetTypeWakeUp:         return "sunrise.fill"
        default:                            return Self.inferIcon(from: name)
        }
    }

    /// Inferenza icona dal nome della scena. Riconosce keyword IT+EN comuni.
    static func inferIcon(from name: String) -> String {
        let n = name.lowercased()
        
        // Categoria sicurezza/casa
        if n.contains("allarme") || n.contains("alarm") { return "exclamationmark.shield.fill" }
        if n.contains("sicurezza") || n.contains("security") { return "shield.fill" }
        if n.contains("benvenuto") || n.contains("welcome") || n.contains("arrivo") || n.contains("arrival") {
            return "house.fill"
        }
        if n.contains("uscita") || n.contains("leave") || n.contains("departure") || n.contains("away") {
            return "figure.walk.departure"
        }
        
        // Categoria notte/giorno
        if n.contains("notte") || n.contains("night") || n.contains("dormi") || n.contains("sleep") || n.contains("buonanotte") {
            return "moon.fill"
        }
        if n.contains("buongiorno") || n.contains("morning") || n.contains("sveglia") || n.contains("wake") {
            return "sunrise.fill"
        }
        if n.contains("alba") { return "sunrise.fill" }
        if n.contains("tramonto") || n.contains("sunset") { return "sunset.fill" }
        
        // Attività
        if n.contains("cinema") || n.contains("film") || n.contains("movie") || n.contains("tv") {
            return "tv.fill"
        }
        if n.contains("cena") || n.contains("dinner") || n.contains("pranzo") || n.contains("lunch") || n.contains("cuc") {
            return "fork.knife"
        }
        if n.contains("relax") || n.contains("rilass") { return "leaf.fill" }
        if n.contains("lavor") || n.contains("studi") || n.contains("work") || n.contains("study") {
            return "laptopcomputer"
        }
        if n.contains("lettura") || n.contains("read") { return "book.fill" }
        if n.contains("party") || n.contains("festa") { return "party.popper.fill" }
        if n.contains("musica") || n.contains("music") { return "music.note" }
        if n.contains("yoga") || n.contains("meditazione") || n.contains("medita") { return "figure.mind.and.body" }
        if n.contains("doccia") || n.contains("bagno") || n.contains("shower") { return "shower.fill" }
        
        // Climatizzazione
        if n.contains("caldo") || n.contains("riscalda") || n.contains("heat") { return "flame.fill" }
        if n.contains("fresco") || n.contains("freddo") || n.contains("cool") { return "snowflake" }
        if n.contains("aria") || n.contains("air") { return "wind" }
        
        // Default scena custom
        return "wand.and.sparkles"
    }
    
    /// Priorità di ordinamento: built-in prima (in ordine tematico),
    /// poi custom in ordine alfabetico.
    var displayPriority: Int {
        switch actionSet.actionSetType {
        case HMActionSetTypeWakeUp:         return 0
        case HMActionSetTypeHomeArrival:    return 1
        case HMActionSetTypeHomeDeparture:  return 2
        case HMActionSetTypeSleep:          return 3
        default:                            return 99
        }
    }
    
    /// UUID delle stanze i cui accessori sono target di almeno una azione della scena.
    /// Una scena "Buonanotte" che spegne luci in Living + Camera ritorna entrambi gli UUID.
    var affiliatedRoomIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for action in actionSet.actions {
            if let write = action.homeFloorplanCharacteristicWrite,
               let room = write.characteristic.service?.accessory?.room {
                ids.insert(room.uniqueIdentifier)
            }
        }
        return ids
    }
    
    /// Riepilogo leggibile delle azioni di una scena, raggruppate per accessorio.
    /// Più HMCharacteristicWriteAction sullo stesso accessorio vengono combinate
    /// in un'unica entry con descrizione concatenata.
    @MainActor
    var actionSummaries: [SceneActionSummary] {
        // Step 1: raccogli (accessory, characteristic, value) per ogni write action
        var rawActions: [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any?)] = []
        
        for action in actionSet.actions {
            guard let write = action.homeFloorplanCharacteristicWrite,
                  let accessory = write.characteristic.service?.accessory else { continue }
            rawActions.append((accessory, write.characteristic, write.targetValue))
        }
        
        // Step 2: raggruppa per accessorio
        let grouped = Dictionary(grouping: rawActions, by: { $0.accessory.uniqueIdentifier })
        
        // Step 3: costruisci SceneActionSummary per ogni accessorio
        let summaries = grouped.compactMap { (uuid, items) -> SceneActionSummary? in
            guard let first = items.first else { return nil }
            let accessory = first.accessory
            let description = SceneActionSummary.describe(
                characteristics: items.map { (ch: $0.characteristic, value: $0.value) }
            )
            return SceneActionSummary(
                accessoryID: uuid,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                roomID: accessory.room?.uniqueIdentifier ?? UUID(),
                description: description
            )
        }
        
        return summaries.sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }
}

/// Riepilogo di una singola azione (o gruppo di azioni sullo stesso accessorio)
/// dentro una scena. Pensato per la visualizzazione read-only.
struct SceneActionSummary: Identifiable {
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String
    let roomID: UUID
    let description: String
    
    var id: UUID { accessoryID }
    
    /// Converte un set di (characteristic, value) per uno STESSO accessorio
    /// in una stringa human-readable concatenata.
    static func describe(characteristics: [(ch: HMCharacteristic, value: Any?)]) -> String {
        var parts: [String] = []
        
        // UUID HAP comuni
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let onUUID = "00000025-0000-1000-8000-0026BB765291"
        let brightnessUUID = "00000008-0000-1000-8000-0026BB765291"
        let targetPositionUUID = "0000007C-0000-1000-8000-0026BB765291"
        let targetTempUUID = "00000035-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let targetHeaterCoolerStateUUID = "000000B2-0000-1000-8000-0026BB765291"
        let lockTargetStateUUID = "0000001E-0000-1000-8000-0026BB765291"
        let targetDoorStateUUID = "00000032-0000-1000-8000-0026BB765291"
        let securityTargetStateUUID = "00000067-0000-1000-8000-0026BB765291"
        let targetAirPurifierStateUUID = "000000A8-0000-1000-8000-0026BB765291"
        let targetHumidifierStateUUID = "000000B4-0000-1000-8000-0026BB765291"
        let humidifierThresholdUUID = "000000CA-0000-1000-8000-0026BB765291"
        let dehumidifierThresholdUUID = "000000C9-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"
        let colorTemperatureUUID = "000000CE-0000-1000-8000-0026BB765291"
        let hueUUID = "00000013-0000-1000-8000-0026BB765291"
        let saturationUUID = "0000002F-0000-1000-8000-0026BB765291"
        
        // Helper per estrarre int/double
        func intVal(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let u = any as? UInt8 { return Int(u) }
            if let n = any as? NSNumber { return n.intValue }
            return nil
        }
        func doubleVal(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let f = any as? Float { return Double(f) }
            if let i = any as? Int { return Double(i) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }
        
        for (ch, value) in characteristics {
            switch ch.characteristicType {
            case onUUID, activeUUID:
                if intVal(value) == 1 {
                    parts.append(String(localized: "accessory.state.on", defaultValue: "On"))
                } else if intVal(value) == 0 {
                    parts.append(String(localized: "accessory.state.off", defaultValue: "Off"))
                }
            case brightnessUUID:
                if let v = intVal(value) { parts.append("\(v)%") }
            case targetPositionUUID:
                if let v = intVal(value) {
                    let logicalPosition = ch.service?.accessory.map {
                        WindowCoveringPositionMapper.logicalPosition(
                            fromRaw: v,
                            accessoryID: $0.uniqueIdentifier
                        )
                    } ?? v
                    parts.append(logicalPosition == 0
                        ? String(localized: "accessory.position.closed", defaultValue: "Closed")
                        : (logicalPosition == 100 ? String(localized: "accessory.position.open", defaultValue: "Open") : "\(logicalPosition)%"))
                }
            case targetTempUUID, heatingThresholdUUID, coolingThresholdUUID:
                if let t = doubleVal(value) {
                    parts.append(String(format: "%.1f°", t))
                }
            case humidifierThresholdUUID, dehumidifierThresholdUUID:
                if let h = doubleVal(value) {
                    parts.append("\(Int(h.rounded()))%")
                }
            case targetHeaterCoolerStateUUID:
                switch intVal(value) ?? -1 {
                case 0: parts.append(String(localized: "thermostat.mode.auto", defaultValue: "Auto"))
                case 1: parts.append(String(localized: "thermostat.mode.heat", defaultValue: "Heat"))
                case 2: parts.append(String(localized: "thermostat.mode.cool", defaultValue: "Cool"))
                default: break
                }
            case rotationSpeedUUID:
                if let v = intVal(value) {
                    let fanStr = String(localized: "accessory.fan.speed", defaultValue: "Fan")
                    parts.append("\(fanStr) \(v)%")
                }
            case lockTargetStateUUID:
                if intVal(value) == 1 { parts.append(String(localized: "accessory.lock.lock", defaultValue: "Lock")) }
                else if intVal(value) == 0 { parts.append(String(localized: "accessory.lock.unlock", defaultValue: "Unlock")) }
            case targetDoorStateUUID:
                if intVal(value) == 0 { parts.append(String(localized: "accessory.door.open", defaultValue: "Open")) }
                else if intVal(value) == 1 { parts.append(String(localized: "accessory.door.close", defaultValue: "Close")) }
            case securityTargetStateUUID:
                switch intVal(value) ?? -1 {
                case 0: parts.append(String(localized: "security.mode.home", defaultValue: "Home"))
                case 1: parts.append(String(localized: "security.mode.away", defaultValue: "Away"))
                case 2: parts.append(String(localized: "security.mode.night", defaultValue: "Night"))
                case 3: parts.append(String(localized: "security.mode.disarm", defaultValue: "Disarm"))
                default: break
                }
            case targetAirPurifierStateUUID:
                if intVal(value) == 0 { parts.append(String(localized: "airpurifier.mode.manual", defaultValue: "Manual Mode")) }
                else if intVal(value) == 1 { parts.append(String(localized: "airpurifier.mode.auto", defaultValue: "Auto Mode")) }
            case targetHumidifierStateUUID:
                switch intVal(value) ?? -1 {
                case 0: parts.append(String(localized: "humidifier.mode.auto", defaultValue: "Auto"))
                case 1: parts.append(String(localized: "humidifier.mode.humidify", defaultValue: "Humidify"))
                case 2: parts.append(String(localized: "humidifier.mode.dehumidify", defaultValue: "Dehumidify"))
                default: break
                }
            case colorTemperatureUUID:
                // Mired → Kelvin per visualizzazione leggibile
                if let mired = intVal(value), mired > 0 {
                    let kelvin = 1_000_000 / mired
                    parts.append("\(kelvin)K")
                }
            case hueUUID:
                if let v = doubleVal(value) {
                    let hueStr = String(localized: "light.hue", defaultValue: "Hue")
                    parts.append("\(hueStr) \(Int(v))°")
                }
            case saturationUUID:
                if let v = doubleVal(value) {
                    let satStr = String(localized: "light.saturation", defaultValue: "Saturation")
                    parts.append("\(satStr) \(Int(v))%")
                }
            default:
                // Fallback: mostra valore raw
                if let intV = intVal(value) {
                    parts.append("\(intV)")
                } else if let doubleV = doubleVal(value) {
                    parts.append(String(format: "%.1f", doubleV))
                }
            }
        }

        return parts.isEmpty
            ? String(localized: "scene.action.custom", defaultValue: "Custom Action")
            : parts.joined(separator: " • ")
    }
}
