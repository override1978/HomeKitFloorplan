import Foundation
import HomeKit

private let programmableSwitchEventCharacteristicType = "00000073-0000-1000-8000-0026BB765291"

// MARK: - Automation Characteristic Capabilities

/// Describes how a readable HomeKit characteristic can participate in an automation.
///
/// This is intentionally a discovery/model layer only: it does not create triggers,
/// predicates, or UI. Higher-level automation editors can consume these capabilities
/// without knowing the HomeKit quirks behind each accessory type.
struct AutomationCharacteristicCapability: Identifiable {
    let id: String
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String
    let characteristic: HMCharacteristic
    let title: String
    let iconName: String
    let valueKind: AutomationCapabilityValueKind
    let supportedRoles: Set<AutomationCapabilityRole>
    let defaultOperator: AutomationCapabilityOperator
}

enum AutomationCapabilityRole: Hashable {
    case trigger
    case condition
}

enum AutomationConditionJoinMode: String, CaseIterable, Identifiable {
    case all
    case any

    var id: String { rawValue }
}

enum AutomationCapabilityOperator: Hashable {
    case becomesActive
    case becomesInactive
    case equals
    case greaterThan
    case lessThan
}

enum AutomationCapabilityValueKind {
    case boolean(activeLabel: String, inactiveLabel: String)
    case numeric(unit: String, range: ClosedRange<Double>?, step: Double?)
    case state(options: [AutomationCapabilityStateOption])
}

struct AutomationCapabilityStateOption: Identifiable, Hashable {
    let rawValue: Int
    let title: String
    let iconName: String?

    var id: Int { rawValue }
}

struct AutomationCapabilitySelection {
    let capability: AutomationCharacteristicCapability
    var comparisonOperator: AutomationCapabilityOperator
    var targetValue: AutomationCapabilityTargetValue

    init(
        capability: AutomationCharacteristicCapability,
        comparisonOperator: AutomationCapabilityOperator? = nil,
        targetValue: AutomationCapabilityTargetValue? = nil
    ) {
        self.capability = capability
        self.comparisonOperator = comparisonOperator ?? capability.defaultOperator
        self.targetValue = targetValue ?? AutomationCapabilityTargetValue.defaultValue(
            for: capability.valueKind,
            operator: comparisonOperator ?? capability.defaultOperator
        )
    }

    var characteristicEvent: HMEvent {
        HMCharacteristicEvent<NSNumber>(
            characteristic: capability.characteristic,
            triggerValue: usesEventTriggerValue ? targetValue.numberValue : nil
        )
    }

    var predicate: NSPredicate {
        HMEventTrigger.predicateForEvaluatingTrigger(
            capability.characteristic,
            relatedBy: comparisonOperator.predicateOperator,
            toValue: targetValue.numberValue
        )
    }

    var triggerPredicate: NSPredicate? {
        if case .any = targetValue { return nil }
        return usesEventTriggerValue ? nil : predicate
    }

    var usesEventTriggerValue: Bool {
        capability.characteristic.characteristicType.caseInsensitiveCompare(programmableSwitchEventCharacteristicType) == .orderedSame
    }
}

enum AutomationCapabilityTargetValue: Hashable {
    case bool(Bool)
    case number(Double)
    case state(Int)
    /// Represents a trigger that fires on any value change (triggerValue = nil in HomeKit).
    case any

    var numberValue: NSNumber {
        switch self {
        case .bool(let value):
            return NSNumber(value: value)
        case .number(let value):
            return NSNumber(value: value)
        case .state(let rawValue):
            return NSNumber(value: rawValue)
        case .any:
            return NSNumber(value: 0)
        }
    }

    static func defaultValue(
        for valueKind: AutomationCapabilityValueKind,
        operator comparisonOperator: AutomationCapabilityOperator
    ) -> AutomationCapabilityTargetValue {
        switch valueKind {
        case .boolean:
            return .bool(comparisonOperator != .becomesInactive)
        case .numeric(_, let range, _):
            if let range {
                return .number((range.lowerBound + range.upperBound) / 2)
            }
            return .number(0)
        case .state(let options):
            return .state(options.first?.rawValue ?? 0)
        }
    }
}

private extension AutomationCapabilityOperator {
    var predicateOperator: NSComparisonPredicate.Operator {
        switch self {
        case .becomesActive, .equals:
            return .equalTo
        case .becomesInactive:
            return .equalTo
        case .greaterThan:
            return .greaterThan
        case .lessThan:
            return .lessThan
        }
    }
}

@MainActor
enum AutomationCapabilityCatalog {
    private static let targetSecuritySystemStateType = "00000067-0000-1000-8000-0026BB765291"
    private static let currentHeatingCoolingStateType = "0000000F-0000-1000-8000-0026BB765291"
    private static let targetHeatingCoolingStateType = "00000033-0000-1000-8000-0026BB765291"
    private static let targetTemperatureType = "00000035-0000-1000-8000-0026BB765291"
    private static let heatingThresholdTemperatureType = "00000012-0000-1000-8000-0026BB765291"
    private static let coolingThresholdTemperatureType = "0000000D-0000-1000-8000-0026BB765291"
    private static let currentHeaterCoolerStateType = "000000B1-0000-1000-8000-0026BB765291"
    private static let targetHeaterCoolerStateType = "000000B2-0000-1000-8000-0026BB765291"
    private static let currentHumidifierStateType = "000000B3-0000-1000-8000-0026BB765291"
    private static let targetHumidifierStateType = "000000B4-0000-1000-8000-0026BB765291"
    private static let waterLevelType = "000000B5-0000-1000-8000-0026BB765291"
    private static let relativeHumidityDehumidifierThresholdType = "000000C9-0000-1000-8000-0026BB765291"
    private static let relativeHumidityHumidifierThresholdType = "000000CA-0000-1000-8000-0026BB765291"
    private static let currentAirPurifierStateType = "000000A9-0000-1000-8000-0026BB765291"
    private static let targetAirPurifierStateType = "000000A8-0000-1000-8000-0026BB765291"
    private static let rotationSpeedType = "00000029-0000-1000-8000-0026BB765291"
    private static let filterLifeLevelType = "000000AB-0000-1000-8000-0026BB765291"

    static func capabilities(in home: HMHome) -> [AutomationCharacteristicCapability] {
        home.accessories
            .flatMap(capabilities(for:))
            .sorted {
                if $0.roomName != $1.roomName {
                    return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
                }
                if $0.accessoryName != $1.accessoryName {
                    return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    static func triggerCapabilities(in home: HMHome) -> [AutomationCharacteristicCapability] {
        capabilities(in: home).filter { $0.supportedRoles.contains(.trigger) }
    }

    static func conditionCapabilities(in home: HMHome) -> [AutomationCharacteristicCapability] {
        capabilities(in: home).filter { $0.supportedRoles.contains(.condition) }
    }

    static func capabilities(for accessory: HMAccessory) -> [AutomationCharacteristicCapability] {
        var result: [AutomationCharacteristicCapability] = []
        var seenCharacteristicIDs = Set<UUID>()

        func append(_ capability: AutomationCharacteristicCapability?) {
            guard let capability else { return }
            guard seenCharacteristicIDs.insert(capability.characteristic.uniqueIdentifier).inserted else { return }
            result.append(capability)
        }

        for kind in SensorAdapter.SensorKind.allCases {
            append(sensorCapability(for: kind, in: accessory))
        }

        for capability in programmableSwitchCapabilities(in: accessory) {
            append(capability)
        }

        append(booleanControlCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypePowerState,
            title: String(localized: "automation.capability.power", defaultValue: "Power"),
            iconName: "power",
            activeLabel: String(localized: "automation.capability.power.on", defaultValue: "On"),
            inactiveLabel: String(localized: "automation.capability.power.off", defaultValue: "Off")
        ))
        append(booleanControlCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeActive,
            title: String(localized: "automation.capability.active", defaultValue: "Active"),
            iconName: "power.circle.fill",
            activeLabel: String(localized: "automation.capability.active.yes", defaultValue: "Active"),
            inactiveLabel: String(localized: "automation.capability.active.no", defaultValue: "Inactive")
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeBrightness,
            title: String(localized: "automation.capability.brightness", defaultValue: "Brightness"),
            iconName: "sun.max.fill",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeCurrentPosition,
            title: String(localized: "automation.capability.position", defaultValue: "Position"),
            iconName: "blinds.horizontal.open",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeCurrentLockMechanismState,
            title: String(localized: "automation.capability.lockState", defaultValue: "Lock state"),
            iconName: "lock.fill",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "accessory.lock.unsecured", defaultValue: "Unlocked"), iconName: "lock.open.fill"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "accessory.lock.secured", defaultValue: "Locked"), iconName: "lock.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "accessory.lock.jammed", defaultValue: "Jammed"), iconName: "exclamationmark.lock.fill"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "accessory.lock.unknown", defaultValue: "Unknown"), iconName: "questionmark.circle")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeCurrentDoorState,
            title: String(localized: "automation.capability.doorState", defaultValue: "Door state"),
            iconName: "door.garage.closed",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "accessory.garage.open", defaultValue: "Open"), iconName: "door.garage.open"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "accessory.garage.closed", defaultValue: "Closed"), iconName: "door.garage.closed"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "accessory.garage.opening", defaultValue: "Opening"), iconName: "arrow.up"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "accessory.garage.closing", defaultValue: "Closing"), iconName: "arrow.down"),
                AutomationCapabilityStateOption(rawValue: 4, title: String(localized: "accessory.garage.stopped", defaultValue: "Stopped"), iconName: "pause.fill")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: HMCharacteristicTypeCurrentSecuritySystemState,
            title: String(localized: "automation.capability.securityState", defaultValue: "Security state"),
            iconName: "shield.lefthalf.filled",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "security.state.stayArm", defaultValue: "Stay arm"), iconName: "house.fill"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "security.state.awayArm", defaultValue: "Away arm"), iconName: "figure.walk.departure"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "security.state.nightArm", defaultValue: "Night arm"), iconName: "moon.fill"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "security.state.disarmed", defaultValue: "Disarmed"), iconName: "shield.slash"),
                AutomationCapabilityStateOption(rawValue: 4, title: String(localized: "security.state.triggered", defaultValue: "Triggered"), iconName: "exclamationmark.shield.fill")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.targetSecuritySystemStateType,
            title: String(localized: "automation.capability.securityMode", defaultValue: "Security mode"),
            iconName: "shield.fill",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "security.state.stayArm", defaultValue: "Stay arm"), iconName: "house.fill"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "security.state.awayArm", defaultValue: "Away arm"), iconName: "figure.walk.departure"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "security.state.nightArm", defaultValue: "Night arm"), iconName: "moon.fill"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "security.state.disarmed", defaultValue: "Disarmed"), iconName: "shield.slash")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.currentHeatingCoolingStateType,
            title: String(localized: "automation.capability.climateState", defaultValue: "Climate state"),
            iconName: "thermometer.variable",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "thermostat.state.off", defaultValue: "Off"), iconName: "power"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "thermostat.mode.heat", defaultValue: "Heat"), iconName: "flame.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "thermostat.mode.cool", defaultValue: "Cool"), iconName: "snowflake")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.targetHeatingCoolingStateType,
            title: String(localized: "automation.capability.climateMode", defaultValue: "Climate mode"),
            iconName: "thermometer.medium",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "thermostat.mode.off", defaultValue: "Off"), iconName: "power"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "thermostat.mode.heat", defaultValue: "Heat"), iconName: "flame.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "thermostat.mode.cool", defaultValue: "Cool"), iconName: "snowflake"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "thermostat.mode.auto", defaultValue: "Auto"), iconName: "a.circle")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.currentHeaterCoolerStateType,
            title: String(localized: "automation.capability.heaterCoolerState", defaultValue: "Heater cooler state"),
            iconName: "thermometer.variable",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "climate.state.inactive", defaultValue: "Inactive"), iconName: "power"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "climate.state.idle", defaultValue: "Idle"), iconName: "pause.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "thermostat.mode.heat", defaultValue: "Heat"), iconName: "flame.fill"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "thermostat.mode.cool", defaultValue: "Cool"), iconName: "snowflake")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.targetHeaterCoolerStateType,
            title: String(localized: "automation.capability.heaterCoolerMode", defaultValue: "Heater cooler mode"),
            iconName: "thermometer.medium",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "thermostat.mode.auto", defaultValue: "Auto"), iconName: "a.circle"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "thermostat.mode.heat", defaultValue: "Heat"), iconName: "flame.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "thermostat.mode.cool", defaultValue: "Cool"), iconName: "snowflake")
            ]
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.targetTemperatureType,
            title: String(localized: "automation.capability.targetTemperature", defaultValue: "Target temperature"),
            iconName: "thermometer.medium",
            unit: "°C",
            fallbackRange: 10...30,
            fallbackStep: 0.5
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.heatingThresholdTemperatureType,
            title: String(localized: "automation.capability.heatingThreshold", defaultValue: "Heating threshold"),
            iconName: "flame.fill",
            unit: "°C",
            fallbackRange: 10...30,
            fallbackStep: 0.5
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.coolingThresholdTemperatureType,
            title: String(localized: "automation.capability.coolingThreshold", defaultValue: "Cooling threshold"),
            iconName: "snowflake",
            unit: "°C",
            fallbackRange: 16...32,
            fallbackStep: 0.5
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.currentHumidifierStateType,
            title: String(localized: "automation.capability.humidifierState", defaultValue: "Humidifier state"),
            iconName: "humidifier.fill",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "humidifier.state.inactive", defaultValue: "Inactive"), iconName: "power"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "humidifier.state.idle", defaultValue: "Idle"), iconName: "pause.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "humidifier.state.humidifying", defaultValue: "Humidifying"), iconName: "humidity.fill"),
                AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "humidifier.state.dehumidifying", defaultValue: "Dehumidifying"), iconName: "drop.triangle.fill")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.targetHumidifierStateType,
            title: String(localized: "automation.capability.humidifierMode", defaultValue: "Humidifier mode"),
            iconName: "humidifier",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "humidifier.mode.auto", defaultValue: "Auto"), iconName: "a.circle"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "humidifier.mode.humidify", defaultValue: "Humidify"), iconName: "humidity.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "humidifier.mode.dehumidify", defaultValue: "Dehumidify"), iconName: "drop.triangle.fill")
            ]
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.relativeHumidityHumidifierThresholdType,
            title: String(localized: "automation.capability.humidifierThreshold", defaultValue: "Humidifier threshold"),
            iconName: "humidity.fill",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.relativeHumidityDehumidifierThresholdType,
            title: String(localized: "automation.capability.dehumidifierThreshold", defaultValue: "Dehumidifier threshold"),
            iconName: "drop.triangle.fill",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.waterLevelType,
            title: String(localized: "automation.capability.waterLevel", defaultValue: "Water level"),
            iconName: "drop.fill",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.currentAirPurifierStateType,
            title: String(localized: "automation.capability.airPurifierState", defaultValue: "Air purifier state"),
            iconName: "air.purifier.fill",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "airpurifier.state.inactive", defaultValue: "Inactive"), iconName: "power"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "airpurifier.state.idle", defaultValue: "Idle"), iconName: "pause.fill"),
                AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "airpurifier.state.purifying", defaultValue: "Purifying"), iconName: "wind")
            ]
        ))
        append(stateCapability(
            in: accessory,
            characteristicType: Self.targetAirPurifierStateType,
            title: String(localized: "automation.capability.airPurifierMode", defaultValue: "Air purifier mode"),
            iconName: "air.purifier",
            options: [
                AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "airpurifier.mode.manual", defaultValue: "Manual"), iconName: "hand.tap.fill"),
                AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "airpurifier.mode.auto", defaultValue: "Auto"), iconName: "a.circle")
            ]
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.rotationSpeedType,
            title: String(localized: "automation.capability.fanSpeed", defaultValue: "Fan speed"),
            iconName: "fan.fill",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))
        append(numericControlCapability(
            in: accessory,
            characteristicType: Self.filterLifeLevelType,
            title: String(localized: "automation.capability.filterLife", defaultValue: "Filter life"),
            iconName: "line.3.horizontal.decrease.circle",
            unit: "%",
            fallbackRange: 0...100,
            fallbackStep: 1
        ))

        return result
    }

    private static func programmableSwitchCapabilities(in accessory: HMAccessory) -> [AutomationCharacteristicCapability] {
        accessory.services.compactMap { service in
            guard let characteristic = service.characteristics.first(where: {
                $0.characteristicType.caseInsensitiveCompare(programmableSwitchEventCharacteristicType) == .orderedSame
            }) else {
                return nil
            }

            let options = programmableSwitchEventOptions(for: characteristic)
            guard !options.isEmpty else { return nil }

            return AutomationCharacteristicCapability(
                id: "\(accessory.uniqueIdentifier.uuidString)-\(characteristic.uniqueIdentifier.uuidString)",
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room"),
                characteristic: characteristic,
                title: programmableSwitchTitle(for: service),
                iconName: "button.programmable",
                valueKind: .state(options: options),
                supportedRoles: [.trigger],
                defaultOperator: .equals
            )
        }
    }

    private static func programmableSwitchTitle(for service: HMService) -> String {
        let serviceName = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serviceName.isEmpty {
            return serviceName
        }

        if let nameCharacteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeName }),
           let name = nameCharacteristic.value as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        return String(localized: "automation.capability.programmableSwitch", defaultValue: "Programmable button")
    }

    private static func programmableSwitchEventOptions(for characteristic: HMCharacteristic) -> [AutomationCapabilityStateOption] {
        let defaultOptions = [
            AutomationCapabilityStateOption(rawValue: 0, title: String(localized: "automation.programmableSwitch.singlePress", defaultValue: "Single Press"), iconName: "hand.tap.fill"),
            AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "automation.programmableSwitch.doublePress", defaultValue: "Double Press"), iconName: "hand.tap.fill"),
            AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "automation.programmableSwitch.longPress", defaultValue: "Long Press"), iconName: "hand.raised.fill")
        ]

        if let validValues = characteristic.metadata?.validValues as? [NSNumber], !validValues.isEmpty {
            let valid = Set(validValues.map(\.intValue))
            return defaultOptions.filter { valid.contains($0.rawValue) }
        }

        if let min = characteristic.metadata?.minimumValue as? NSNumber,
           let max = characteristic.metadata?.maximumValue as? NSNumber,
           min.intValue <= max.intValue {
            let valid = Set(min.intValue...max.intValue)
            return defaultOptions.filter { valid.contains($0.rawValue) }
        }

        return defaultOptions
    }

    private static func sensorCapability(
        for kind: SensorAdapter.SensorKind,
        in accessory: HMAccessory
    ) -> AutomationCharacteristicCapability? {
        guard let characteristic = findCharacteristic(in: accessory, type: kind.characteristicType),
              characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            return nil
        }

        let title = sensorTitle(for: kind)
        let valueKind: AutomationCapabilityValueKind
        let defaultOperator: AutomationCapabilityOperator

        if kind.isBoolean {
            valueKind = .boolean(
                activeLabel: activeSensorLabel(for: kind),
                inactiveLabel: inactiveSensorLabel(for: kind)
            )
            defaultOperator = .becomesActive
        } else if kind == .airQuality {
            valueKind = .state(options: airQualityOptions)
            defaultOperator = .greaterThan
        } else {
            valueKind = .numeric(
                unit: sensorUnit(for: kind),
                range: numericRange(for: characteristic),
                step: numericStep(for: characteristic)
            )
            defaultOperator = .greaterThan
        }

        return makeCapability(
            accessory: accessory,
            characteristic: characteristic,
            title: title,
            iconName: kind.iconName(triggered: false),
            valueKind: valueKind,
            defaultOperator: defaultOperator
        )
    }

    private static func booleanControlCapability(
        in accessory: HMAccessory,
        characteristicType: String,
        title: String,
        iconName: String,
        activeLabel: String,
        inactiveLabel: String
    ) -> AutomationCharacteristicCapability? {
        guard let characteristic = findCharacteristic(in: accessory, type: characteristicType),
              characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            return nil
        }

        return makeCapability(
            accessory: accessory,
            characteristic: characteristic,
            title: title,
            iconName: iconName,
            valueKind: .boolean(activeLabel: activeLabel, inactiveLabel: inactiveLabel),
            defaultOperator: .equals
        )
    }

    private static func numericControlCapability(
        in accessory: HMAccessory,
        characteristicType: String,
        title: String,
        iconName: String,
        unit: String,
        fallbackRange: ClosedRange<Double>,
        fallbackStep: Double
    ) -> AutomationCharacteristicCapability? {
        guard let characteristic = findCharacteristic(in: accessory, type: characteristicType),
              characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            return nil
        }

        return makeCapability(
            accessory: accessory,
            characteristic: characteristic,
            title: title,
            iconName: iconName,
            valueKind: .numeric(
                unit: unit,
                range: numericRange(for: characteristic) ?? fallbackRange,
                step: numericStep(for: characteristic) ?? fallbackStep
            ),
            defaultOperator: .greaterThan
        )
    }

    private static func stateCapability(
        in accessory: HMAccessory,
        characteristicType: String,
        title: String,
        iconName: String,
        options: [AutomationCapabilityStateOption]
    ) -> AutomationCharacteristicCapability? {
        guard let characteristic = findCharacteristic(in: accessory, type: characteristicType),
              characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            return nil
        }

        let validValues = characteristic.metadata?.validValues as? [NSNumber]
        let filteredOptions: [AutomationCapabilityStateOption]
        if let validValues, !validValues.isEmpty {
            let valid = Set(validValues.map(\.intValue))
            filteredOptions = options.filter { valid.contains($0.rawValue) }
        } else {
            filteredOptions = options
        }

        guard !filteredOptions.isEmpty else { return nil }

        return makeCapability(
            accessory: accessory,
            characteristic: characteristic,
            title: title,
            iconName: iconName,
            valueKind: .state(options: filteredOptions),
            defaultOperator: .equals
        )
    }

    private static func makeCapability(
        accessory: HMAccessory,
        characteristic: HMCharacteristic,
        title: String,
        iconName: String,
        valueKind: AutomationCapabilityValueKind,
        defaultOperator: AutomationCapabilityOperator
    ) -> AutomationCharacteristicCapability {
        let supportedRoles: Set<AutomationCapabilityRole> = characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
            ? [.trigger, .condition]
            : [.condition]

        return AutomationCharacteristicCapability(
            id: "\(accessory.uniqueIdentifier.uuidString)-\(characteristic.uniqueIdentifier.uuidString)",
            accessoryID: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room"),
            characteristic: characteristic,
            title: title,
            iconName: iconName,
            valueKind: valueKind,
            supportedRoles: supportedRoles,
            defaultOperator: defaultOperator
        )
    }

    private static func findCharacteristic(in accessory: HMAccessory, type: String) -> HMCharacteristic? {
        accessory.services
            .flatMap(\.characteristics)
            .first { $0.characteristicType.caseInsensitiveCompare(type) == .orderedSame }
    }

    private static func numericRange(for characteristic: HMCharacteristic) -> ClosedRange<Double>? {
        guard let min = characteristic.metadata?.minimumValue?.doubleValue,
              let max = characteristic.metadata?.maximumValue?.doubleValue,
              min <= max else {
            return nil
        }
        return min...max
    }

    private static func numericStep(for characteristic: HMCharacteristic) -> Double? {
        guard let step = characteristic.metadata?.stepValue?.doubleValue, step > 0 else {
            return nil
        }
        return step
    }

    private static func sensorTitle(for kind: SensorAdapter.SensorKind) -> String {
        switch kind {
        case .smoke:
            return String(localized: "sensor.smoke", defaultValue: "Smoke")
        case .carbonMonoxide:
            return String(localized: "sensor.carbonMonoxide", defaultValue: "Carbon monoxide")
        case .leak:
            return String(localized: "sensor.leak", defaultValue: "Leak")
        case .contact:
            return String(localized: "sensor.contact", defaultValue: "Contact")
        case .motion:
            return String(localized: "sensor.motion", defaultValue: "Motion")
        case .occupancy:
            return String(localized: "sensor.occupancy", defaultValue: "Occupancy")
        case .temperature:
            return String(localized: "sensor.temperature", defaultValue: "Temperature")
        case .humidity:
            return String(localized: "sensor.humidity", defaultValue: "Humidity")
        case .airQuality:
            return String(localized: "sensor.airQuality", defaultValue: "Air quality")
        case .carbonDioxide:
            return String(localized: "sensor.carbonDioxide", defaultValue: "Carbon dioxide")
        case .vocDensity:
            return String(localized: "sensor.vocDensity", defaultValue: "VOC")
        case .pm25:
            return String(localized: "sensor.pm25", defaultValue: "PM2.5")
        case .pm10:
            return String(localized: "sensor.pm10", defaultValue: "PM10")
        case .lightLevel:
            return String(localized: "sensor.lightSensor", defaultValue: "Light")
        }
    }

    private static func activeSensorLabel(for kind: SensorAdapter.SensorKind) -> String {
        switch kind {
        case .smoke:
            return String(localized: "smoke.detected", defaultValue: "Detected")
        case .carbonMonoxide:
            return String(localized: "sensor.carbonMonoxide.detected", defaultValue: "Detected")
        case .leak:
            return String(localized: "sensor.leak.detected", defaultValue: "Leak detected")
        case .contact:
            return String(localized: "sensor.contact.open", defaultValue: "Open")
        case .motion:
            return String(localized: "sensor.motion.detected", defaultValue: "Motion detected")
        case .occupancy:
            return String(localized: "sensor.occupancy.detected", defaultValue: "Occupied")
        case .temperature, .humidity, .airQuality, .carbonDioxide, .vocDensity, .pm25, .pm10, .lightLevel:
            return String(localized: "sensor.state.active", defaultValue: "Active")
        }
    }

    private static func inactiveSensorLabel(for kind: SensorAdapter.SensorKind) -> String {
        switch kind {
        case .smoke:
            return String(localized: "smoke.notDetected", defaultValue: "Clear")
        case .carbonMonoxide:
            return String(localized: "sensor.carbonMonoxide.clear", defaultValue: "Clear")
        case .leak:
            return String(localized: "sensor.leak.clear", defaultValue: "No leak")
        case .contact:
            return String(localized: "sensor.contact.closed", defaultValue: "Closed")
        case .motion:
            return String(localized: "sensor.motion.clear", defaultValue: "No motion")
        case .occupancy:
            return String(localized: "sensor.occupancy.clear", defaultValue: "Not occupied")
        case .temperature, .humidity, .airQuality, .carbonDioxide, .vocDensity, .pm25, .pm10, .lightLevel:
            return String(localized: "sensor.state.inactive", defaultValue: "Inactive")
        }
    }

    private static func sensorUnit(for kind: SensorAdapter.SensorKind) -> String {
        switch kind {
        case .temperature:
            return "°C"
        case .humidity:
            return "%"
        case .carbonDioxide:
            return "ppm"
        case .vocDensity:
            return "µg/m³"
        case .pm25:
            return "µg/m³"
        case .pm10:
            return "µg/m³"
        case .lightLevel:
            return "lux"
        case .smoke, .carbonMonoxide, .leak, .contact, .motion, .occupancy, .airQuality:
            return ""
        }
    }

    private static var airQualityOptions: [AutomationCapabilityStateOption] {
        [
            AutomationCapabilityStateOption(rawValue: 1, title: String(localized: "sensor.airQuality.excellent", defaultValue: "Excellent"), iconName: "aqi.low"),
            AutomationCapabilityStateOption(rawValue: 2, title: String(localized: "sensor.airQuality.good", defaultValue: "Good"), iconName: "aqi.low"),
            AutomationCapabilityStateOption(rawValue: 3, title: String(localized: "sensor.airQuality.fair", defaultValue: "Fair"), iconName: "aqi.medium"),
            AutomationCapabilityStateOption(rawValue: 4, title: String(localized: "sensor.airQuality.inferior", defaultValue: "Inferior"), iconName: "aqi.high"),
            AutomationCapabilityStateOption(rawValue: 5, title: String(localized: "sensor.airQuality.poor", defaultValue: "Poor"), iconName: "aqi.high")
        ]
    }
}
