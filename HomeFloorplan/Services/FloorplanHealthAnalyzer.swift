import Foundation
import HomeKit

enum FloorplanHealthSeverity: Int, CaseIterable {
    case info
    case warning
    case critical

    var systemImage: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

struct FloorplanHealthIssue: Identifiable {
    let id = UUID()
    let severity: FloorplanHealthSeverity
    let title: String
    let detail: String
}

enum FloorplanPlacementPriority: Int {
    case high = 0
    case medium = 1
    case low = 2

    var label: String {
        switch self {
        case .high: return String(localized: "floorplan.priority.high", defaultValue: "High")
        case .medium: return String(localized: "floorplan.priority.medium", defaultValue: "Medium")
        case .low: return String(localized: "floorplan.priority.low", defaultValue: "Low")
        }
    }
}

struct FloorplanUnplacedAccessory: Identifiable {
    let id: UUID
    let name: String
    let categoryName: String
    let priority: FloorplanPlacementPriority
}

struct FloorplanUnplacedAccessoryGroup: Identifiable {
    let id: UUID
    let roomID: UUID
    let roomName: String
    let accessories: [FloorplanUnplacedAccessory]

    var highPriorityCount: Int {
        accessories.filter { $0.priority == .high }.count
    }
}

struct FloorplanHealthReport {
    let placedCount: Int
    let linkableUnplacedCount: Int
    let linkedRoomCount: Int
    let unplacedGroups: [FloorplanUnplacedAccessoryGroup]
    let issues: [FloorplanHealthIssue]

    var criticalCount: Int { issues.filter { $0.severity == .critical }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    var isHealthy: Bool {
        criticalCount == 0 && warningCount == 0
    }
}

@MainActor
enum FloorplanHealthAnalyzer {
    static func analyze(floorplan: Floorplan, homeKit: HomeKitService) -> FloorplanHealthReport {
        let placedIDs = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
        let linkedRooms = floorplan.linkedRooms
        var issues: [FloorplanHealthIssue] = []

        let missingMarkers = floorplan.accessories.filter {
            homeKit.accessory(for: $0.homeKitAccessoryUUID) == nil
        }
        for _ in missingMarkers {
            issues.append(FloorplanHealthIssue(
                severity: .critical,
                title: String(localized: "floorplan.health.missingAccessory.title", defaultValue: "Accessory not found"),
                detail: String(localized: "floorplan.health.missingAccessory.detail", defaultValue: "A marker points to a HomeKit accessory that is no longer available.")
            ))
        }

        let linkableUnplaced = homeKit.allAccessories.filter { accessory in
            !placedIDs.contains(accessory.uniqueIdentifier) &&
                AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit).supportsFloorplanPlacement
        }
        if !linkableUnplaced.isEmpty {
            issues.append(FloorplanHealthIssue(
                severity: .warning,
                title: String(localized: "floorplan.health.unplaced.title", defaultValue: "Accessories not placed"),
                detail: String(format: String(localized: "floorplan.health.unplaced.detail", defaultValue: "%d supported HomeKit accessories are not yet on the floorplan."), linkableUnplaced.count)
            ))
        }

        let unplacedGroups = linkedRooms.compactMap { room -> FloorplanUnplacedAccessoryGroup? in
            let accessories = linkableUnplaced
                .filter {
                    $0.room?.uniqueIdentifier == room.hmRoomUUID ||
                        FloorplanRoomMatcher.matches(roomName: $0.room?.name, linkedRoom: room)
                }
                .map {
                    FloorplanUnplacedAccessory(
                        id: $0.uniqueIdentifier,
                        name: displayName(for: $0),
                        categoryName: $0.category.localizedDescription,
                        priority: placementPriority(for: $0)
                    )
                }
                .sorted {
                    if $0.priority.rawValue != $1.priority.rawValue {
                        return $0.priority.rawValue < $1.priority.rawValue
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            guard !accessories.isEmpty else { return nil }
            return FloorplanUnplacedAccessoryGroup(
                id: room.hmRoomUUID,
                roomID: room.hmRoomUUID,
                roomName: room.name,
                accessories: accessories
            )
        }
        .sorted {
            if $0.highPriorityCount != $1.highPriorityCount {
                return $0.highPriorityCount > $1.highPriorityCount
            }
            if $0.accessories.count != $1.accessories.count {
                return $0.accessories.count > $1.accessories.count
            }
            return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
        }

        if linkedRooms.isEmpty {
            issues.append(FloorplanHealthIssue(
                severity: .warning,
                title: String(localized: "floorplan.health.noRooms.title", defaultValue: "No rooms linked"),
                detail: String(localized: "floorplan.health.noRooms.detail", defaultValue: "Draw and link room areas to enable the Environment, Security, and Intelligence overlays.")
            ))
        }

        for room in linkedRooms {
            let roomAccessories = homeKit.allAccessories.filter {
                $0.room?.uniqueIdentifier == room.hmRoomUUID ||
                    FloorplanRoomMatcher.matches(roomName: $0.room?.name, linkedRoom: room)
            }

            if roomAccessories.isEmpty {
                issues.append(FloorplanHealthIssue(
                    severity: .info,
                    title: String(localized: "floorplan.health.emptyRoom.title", defaultValue: "Room without accessories"),
                    detail: String(format: String(localized: "floorplan.health.emptyRoom.detail", defaultValue: "%@ is linked to the floorplan but contains no HomeKit accessories."), room.name)
                ))
            }

            let hasSensor = roomAccessories.contains {
                AccessoryCategorizer.categorize($0) == "sensor"
            }
            if !hasSensor {
                issues.append(FloorplanHealthIssue(
                    severity: .info,
                    title: String(localized: "floorplan.health.noSensor.title", defaultValue: "No environmental sensor"),
                    detail: String(format: String(localized: "floorplan.health.noSensor.detail", defaultValue: "%@ has no environmental sensors — the Environment overlay may have less context."), room.name)
                ))
            }
        }

        let markersWithoutLinkedRoom = floorplan.accessories.filter {
            guard $0.linkedRoomUUID == nil else { return false }
            if FloorplanRoomMatcher.linkedRoomID(containing: $0.position, in: linkedRooms) != nil {
                return false
            }
            guard let accessory = homeKit.accessory(for: $0.homeKitAccessoryUUID) else {
                return true
            }
            return !isPerimeterMarkerAccessory(accessory) ||
                !FloorplanRoomMatcher.isNearAnyRoom(
                    $0.position,
                    in: linkedRooms,
                    tolerance: perimeterMarkerRoomTolerance
                )
        }
        if !markersWithoutLinkedRoom.isEmpty && !linkedRooms.isEmpty {
            issues.append(FloorplanHealthIssue(
                severity: .info,
                title: String(localized: "floorplan.health.markerOutside.title", defaultValue: "Markers outside rooms"),
                detail: String(format: String(localized: "floorplan.health.markerOutside.detail", defaultValue: "%d markers are not inside a linked room area."), markersWithoutLinkedRoom.count)
            ))
        }

        return FloorplanHealthReport(
            placedCount: floorplan.accessories.count,
            linkableUnplacedCount: linkableUnplaced.count,
            linkedRoomCount: linkedRooms.count,
            unplacedGroups: unplacedGroups,
            issues: issues.sorted { $0.severity.rawValue > $1.severity.rawValue }
        )
    }

    private static var perimeterMarkerRoomTolerance: Double {
        0.035
    }

    private static func isPerimeterMarkerAccessory(_ accessory: HMAccessory) -> Bool {
        let category = AccessoryCategorizer.categorize(accessory)
        if category == "doorLock" ||
            category == "garageDoor" ||
            category == "windowCovering" {
            return true
        }

        let serviceTypes = Set(accessory.services.map(\.serviceType))
        return serviceTypes.contains(HMServiceTypeContactSensor) ||
            serviceTypes.contains(HMServiceTypeLockMechanism) ||
            serviceTypes.contains(HMServiceTypeGarageDoorOpener) ||
            serviceTypes.contains(HMServiceTypeWindowCovering)
    }

    private static func displayName(for accessory: HMAccessory) -> String {
        guard let roomName = accessory.room?.name else { return accessory.name }
        let suffix = " " + roomName
        if accessory.name.hasSuffix(suffix) {
            return String(accessory.name.dropLast(suffix.count))
        }
        let prefix = roomName + " - "
        if accessory.name.hasPrefix(prefix) {
            return String(accessory.name.dropFirst(prefix.count))
        }
        return accessory.name
    }

    private static func placementPriority(for accessory: HMAccessory) -> FloorplanPlacementPriority {
        let category = AccessoryCategorizer.categorize(accessory)
        if category == "sensor" || category == "security" {
            return .high
        }

        let serviceTypes = Set(accessory.services.map(\.serviceType))
        if serviceTypes.contains(HMServiceTypeTemperatureSensor) ||
            serviceTypes.contains(HMServiceTypeHumiditySensor) ||
            serviceTypes.contains(HMServiceTypeAirQualitySensor) ||
            serviceTypes.contains(HMServiceTypeMotionSensor) ||
            serviceTypes.contains(HMServiceTypeContactSensor) ||
            serviceTypes.contains(HMServiceTypeSmokeSensor) ||
            serviceTypes.contains(HMServiceTypeCarbonMonoxideSensor) ||
            serviceTypes.contains(HMServiceTypeLeakSensor) ||
            serviceTypes.contains(HMServiceTypeLockMechanism) ||
            serviceTypes.contains(HMServiceTypeSecuritySystem) ||
            serviceTypes.contains(HMServiceTypeWindowCovering) {
            return .high
        }

        if category == "light" || category == "climate" {
            return .medium
        }

        return .low
    }
}
