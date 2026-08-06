import Foundation
import CoreGraphics
import HomeKit
import simd

// MARK: - FloorplanOpeningMatcher

/// Collega un'apertura del disegno al sensore di contatto che la sorveglia.
///
/// ⚠️ **È una corrispondenza per vicinanza, non un legame dichiarato.** Nel
/// modello dati non esiste niente che leghi una porta a un accessorio: l'unica
/// evidenza disponibile è che un sensore di contatto sta fisicamente *sulla*
/// porta che sorveglia, quindi il suo marker cade a pochi centimetri dal vano.
///
/// Funziona, e si vede subito quando non funziona — ma resta un'euristica. Se
/// la funzione convince, il passo giusto è un campo esplicito sull'`Opening`
/// scelto dall'utente nell'editor 2D: due sensori sulle due ante di una
/// portafinestra, o un sensore montato sullo stipite invece che sull'anta,
/// qui si sbagliano senza modo di accorgersene.
enum FloorplanOpeningMatcher {

    /// Da coordinate normalizzate sull'immagine a metri nel modello.
    struct Transform {
        var scale: Double
        var dx: Double
        var dy: Double

        func metres(from normalized: CGPoint) -> SIMD2<Double> {
            SIMD2(Double(normalized.x) * scale + dx, Double(normalized.y) * scale + dy)
        }
    }

    /// L'inquadratura dell'immagine esportata non è deducibile: si ricava
    /// confrontando le stanze collegate, che esistono in entrambi gli spazi —
    /// un rettangolo normalizzato di qua, uno in coordinate canvas di là.
    ///
    /// La scala si media su **entrambi gli assi** di tutte le stanze; gli
    /// scostamenti si calcolano dopo, con la scala già mediata, perché
    /// mediarli ognuno con la propria lascerebbe un errore sistematico.
    static func transform(document: DrawingDocument, linkedRooms: [LinkedRoom]) -> Transform? {
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        var scales: [Double] = []
        var pairs: [(normalized: CGPoint, canvas: CGPoint)] = []

        for room in linkedRooms {
            guard let area = document.roomAreas.first(where: { $0.hmRoomUUID == room.hmRoomUUID })
            else { continue }
            let bounds = area.boundingRect

            if room.normalizedRect.width > 0.001 {
                scales.append(Double(bounds.width) * metresPerPoint / Double(room.normalizedRect.width))
            }
            if room.normalizedRect.height > 0.001 {
                scales.append(Double(bounds.height) * metresPerPoint / Double(room.normalizedRect.height))
            }
            pairs.append((CGPoint(x: room.normalizedRect.x + room.normalizedRect.width / 2,
                                  y: room.normalizedRect.y + room.normalizedRect.height / 2),
                          CGPoint(x: bounds.midX, y: bounds.midY)))
        }

        guard !scales.isEmpty, !pairs.isEmpty else { return nil }
        let scale = scales.reduce(0, +) / Double(scales.count)

        let dx = pairs.reduce(0.0) { $0 + Double($1.canvas.x) * metresPerPoint - Double($1.normalized.x) * scale }
        let dy = pairs.reduce(0.0) { $0 + Double($1.canvas.y) * metresPerPoint - Double($1.normalized.y) * scale }
        let count = Double(pairs.count)

        return Transform(scale: scale, dx: dx / count, dy: dy / count)
    }

    /// Il centro di ogni apertura, in metri.
    static func centres(in document: DrawingDocument) -> [(id: UUID, centre: SIMD2<Double>)] {
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        return document.openings.compactMap { opening in
            guard let wall = document.walls.first(where: { $0.id == opening.wallID }) else { return nil }
            let start = SIMD2(Double(wall.start.x) * metresPerPoint, Double(wall.start.y) * metresPerPoint)
            let end = SIMD2(Double(wall.end.x) * metresPerPoint, Double(wall.end.y) * metresPerPoint)
            return (opening.id, start + (end - start) * Double(opening.t))
        }
    }

    /// Le aperture sorvegliate da un contatto che risulta **aperto**.
    ///
    /// - Parameter maxDistance: oltre questa distanza il marker non sta su
    ///   quell'infisso, e associarlo sarebbe inventare.
    static func openOpenings(in document: DrawingDocument,
                             linkedRooms: [LinkedRoom],
                             openMarkerPositions: [CGPoint],
                             maxDistance: Double = 0.80) -> Set<UUID> {
        guard !openMarkerPositions.isEmpty,
              let transform = transform(document: document, linkedRooms: linkedRooms)
        else { return [] }

        let openings = centres(in: document)
        guard !openings.isEmpty else { return [] }

        var result: Set<UUID> = []
        for marker in openMarkerPositions {
            let point = transform.metres(from: marker)
            var best: (id: UUID, distance: Double)?
            for opening in openings {
                let distance = simd_distance(point, opening.centre)
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (opening.id, distance)
                }
            }
            if let best, best.distance <= maxDistance {
                result.insert(best.id)
            }
        }
        return result
    }

    // MARK: - Lettura HomeKit

    /// `true` se l'accessorio espone un contatto e il contatto è aperto.
    ///
    /// ⚠️ Si legge `HomeKitService.characteristicValues`, **non**
    /// `HMCharacteristic.value`. Quest'ultimo resta `nil` finché nessuno ha
    /// fatto `readValue`, e HomeKit non lo popola da solo: leggerlo direttamente
    /// dava «chiuso» per qualunque sensore mai osservato in quella sessione,
    /// cioè sempre, se la vista si apre dalla lista invece che dall'editor.
    ///
    /// L'altro motivo per passare di lì è che quel dizionario è `@Observable`:
    /// una vista che lo legge si ridisegna quando un contatto cambia, senza
    /// doverlo chiedere.
    static func isContactOpen(_ accessory: HMAccessory, using homeKit: HomeKitService) -> Bool {
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.characteristicType == HMCharacteristicTypeContactState {
                let value = homeKit.value(for: characteristic) ?? characteristic.value
                if let number = value as? Int, number != 0 { return true }
                if let flag = value as? Bool, flag { return true }
                if let number = value as? NSNumber, number.intValue != 0 { return true }
            }
        }
        return false
    }

    /// Le aperture aperte, risolte contro lo stato corrente di HomeKit.
    static func openOpenings(in document: DrawingDocument,
                             linkedRooms: [LinkedRoom],
                             markers: [(uuid: UUID, position: CGPoint)],
                             homeKit: HomeKitService) -> Set<UUID> {
        let openMarkers = markers.compactMap { marker -> CGPoint? in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  isContactOpen(accessory, using: homeKit)
            else { return nil }
            return marker.position
        }
        return openOpenings(in: document,
                            linkedRooms: linkedRooms,
                            openMarkerPositions: openMarkers)
    }
}
