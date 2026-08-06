import Foundation
import CoreGraphics
import HomeKit
import simd

// MARK: - FloorplanRoomEnvironment

/// Il valore ambientale di ogni stanza, e **dove piantarci la bandierina**.
///
/// Non si passa da `linkedRoomUUID`: si prende la posizione del marker, la si
/// porta in metri con la stessa inversione dell'export usata per gli infissi, e
/// si guarda in quale poligono cade. Un marker sta dentro una stanza per
/// costruzione — è lì che l'utente l'ha messo — mentre gli UUID delle stanze
/// HomeKit non sono stabili fra device e possono divergere dal disegno.
enum FloorplanRoomEnvironment {

    struct Reading {
        var roomID: UUID
        var roomName: String
        /// Punto in cui piantare lo stelo, in metri.
        var anchor: SIMD2<Double>
        var text: String
    }

    static func readings(in document: DrawingDocument,
                         exportRotation: DrawingExportRotation,
                         markers: [(uuid: UUID, position: CGPoint)],
                         kind: SensorAdapter.SensorKind,
                         homeKit: HomeKitService) -> [Reading] {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let areas = document.roomAreas.map { area -> (area: RoomArea, polygon: [SIMD2<Double>]) in
            (area, area.effectivePoints.map { SIMD2(Double($0.x) * metresPerPoint,
                                                    Double($0.y) * metresPerPoint) })
        }

        // Una lettura per stanza: la prima che si trova. Mediare più sensori
        // sarebbe possibile per temperatura e CO2, ma non per la qualità
        // dell'aria, che è una scala di giudizi e non un numero — e una regola
        // sola è più facile da spiegare di due.
        var byRoom: [UUID: Reading] = [:]

        for marker in markers {
            guard let text = value(of: kind, for: marker.uuid, homeKit: homeKit) else { continue }
            let point = transform.metres(from: marker.position)
            guard let match = areas.first(where: { contains(point, $0.polygon) }) else { continue }
            guard byRoom[match.area.id] == nil else { continue }
            guard let anchor = anchor(in: match.polygon) else { continue }

            byRoom[match.area.id] = Reading(roomID: match.area.id,
                                            roomName: match.area.name,
                                            anchor: anchor,
                                            text: text)
        }

        return Array(byRoom.values)
    }

    private static func value(of kind: SensorAdapter.SensorKind,
                              for accessoryUUID: UUID,
                              homeKit: HomeKitService) -> String? {
        guard let accessory = homeKit.accessory(for: accessoryUUID) else { return nil }
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.characteristicType == kind.characteristicType {
                let raw = homeKit.value(for: characteristic) ?? characteristic.value
                if let text = kind.formattedValue(raw) { return text }
            }
        }
        return nil
    }

    // MARK: - Dove sta il centro di una stanza

    /// Il punto **più interno** del poligono, non il baricentro.
    ///
    /// Il baricentro di una stanza a L cade fuori dalla stanza, e lì la
    /// bandierina spunterebbe da un muro. Si campiona una griglia e si tiene il
    /// punto più lontano da ogni bordo: è il posto dove una persona direbbe
    /// «in mezzo».
    static func anchor(in polygon: [SIMD2<Double>]) -> SIMD2<Double>? {
        guard polygon.count >= 3 else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        guard maxX > minX, maxY > minY else { return nil }

        let steps = 24
        var best: (point: SIMD2<Double>, clearance: Double)?

        for column in 0...steps {
            for row in 0...steps {
                let point = SIMD2(minX + (maxX - minX) * Double(column) / Double(steps),
                                  minY + (maxY - minY) * Double(row) / Double(steps))
                guard contains(point, polygon) else { continue }
                let clearance = distanceToBoundary(point, polygon)
                if clearance > (best?.clearance ?? -1) { best = (point, clearance) }
            }
        }
        return best?.point
    }

    private static func distanceToBoundary(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Double {
        var nearest = Double.greatestFiniteMagnitude
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let edge = b - a
            let lengthSquared = simd_length_squared(edge)
            let projection = lengthSquared > 0
                ? max(0, min(1, simd_dot(point - a, edge) / lengthSquared))
                : 0
            nearest = min(nearest, simd_distance(point, a + edge * projection))
        }
        return nearest
    }

    private static func contains(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}

// MARK: - Strato ambientale

/// Quale grandezza mostrano le bandierine. **Una sola alla volta**: due
/// codifiche sovrapposte non si leggono.
enum EnvironmentLayer: String, CaseIterable, Identifiable {
    case none, temperature, carbonDioxide, vocDensity

    var id: String { rawValue }

    var sensorKind: SensorAdapter.SensorKind? {
        switch self {
        case .none:          nil
        case .temperature:   .temperature
        case .carbonDioxide: .carbonDioxide
        case .vocDensity:    .vocDensity
        }
    }

    var shortLabel: String {
        switch self {
        case .none:          String(localized: "environment.layer.none", defaultValue: "Off")
        case .temperature:   String(localized: "environment.layer.temperature", defaultValue: "Temp")
        case .carbonDioxide: "CO₂"
        case .vocDensity:    "VOC"
        }
    }
}
