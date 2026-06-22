import Foundation
import HomeKit

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

@MainActor
enum AutomationCapabilityCatalog {

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
            characteristicType: HMCharacteristicTypeSecuritySystemCurrentState,
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

        return result
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
        AutomationCharacteristicCapability(
            id: "\(accessory.uniqueIdentifier.uuidString)-\(characteristic.uniqueIdentifier.uuidString)",
            accessoryID: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            roomName: accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room"),
            characteristic: characteristic,
            title: title,
            iconName: iconName,
            valueKind: valueKind,
            supportedRoles: [.trigger, .condition],
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
        case .temperature, .humidity, .airQuality, .lightLevel:
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
        case .temperature, .humidity, .airQuality, .lightLevel:
            return String(localized: "sensor.state.inactive", defaultValue: "Inactive")
        }
    }

    private static func sensorUnit(for kind: SensorAdapter.SensorKind) -> String {
        switch kind {
        case .temperature:
            return "°C"
        case .humidity:
            return "%"
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
