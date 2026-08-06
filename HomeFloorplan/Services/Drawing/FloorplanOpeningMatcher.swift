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
    ///
    /// **Due scale, non una.** La x normalizzata è una frazione della larghezza
    /// dell'immagine e la y della sua altezza: se l'immagine non è quadrata i due
    /// fattori sono diversi, e usarne uno solo sbaglia progressivamente man mano
    /// che ci si allontana dal centro.
    struct Transform {
        var quarterTurns: Int
        var scaleX: Double
        var scaleY: Double
        var dx: Double
        var dy: Double
        /// Errore medio della calibrazione sulle stanze note, in metri. Serve a
        /// **rifiutare** una calibrazione sbagliata invece di usarla.
        var residual: Double

        func metres(from normalized: CGPoint) -> SIMD2<Double> {
            let turned = FloorplanMarkerRemapper.rotatedLocalPoint(
                x: Double(normalized.x), y: Double(normalized.y), quarterTurns: quarterTurns
            )
            return SIMD2(turned.x * scaleX + dx, turned.y * scaleY + dy)
        }
    }

    /// L'inquadratura dell'immagine esportata non è deducibile: si ricava
    /// confrontando le stanze collegate, che esistono in entrambi gli spazi —
    /// un rettangolo normalizzato di qua, uno in coordinate canvas di là.
    ///
    /// ⚠️ E l'immagine può essere **ruotata** rispetto alla tela: marker e
    /// `LinkedRoom` vivono nello spazio dell'export, `RoomArea` in quello del
    /// disegno. Invece di leggere `drawingExportRotation` e sperare di
    /// azzeccarne il verso, si provano tutti e quattro i quarti di giro e si
    /// tiene quello che spiega meglio le stanze note. Con due o più stanze il
    /// confronto è sovradeterminato, quindi la risposta giusta si distingue
    /// nettamente — e il residuo dice quanto fidarsi.
    static func transform(document: DrawingDocument, linkedRooms: [LinkedRoom]) -> Transform? {
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)

        var samples: [(normalized: CGPoint, canvas: SIMD2<Double>, normalizedSize: CGSize, canvasSize: SIMD2<Double>)] = []
        for room in linkedRooms {
            guard let area = document.roomAreas.first(where: { $0.hmRoomUUID == room.hmRoomUUID }),
                  room.normalizedRect.width > 0.001, room.normalizedRect.height > 0.001
            else { continue }
            let bounds = area.boundingRect
            samples.append((
                CGPoint(x: room.normalizedRect.x + room.normalizedRect.width / 2,
                        y: room.normalizedRect.y + room.normalizedRect.height / 2),
                SIMD2(Double(bounds.midX) * metresPerPoint, Double(bounds.midY) * metresPerPoint),
                CGSize(width: room.normalizedRect.width, height: room.normalizedRect.height),
                SIMD2(Double(bounds.width) * metresPerPoint, Double(bounds.height) * metresPerPoint)
            ))
        }
        guard !samples.isEmpty else { return nil }

        var best: Transform?
        for quarterTurns in 0..<4 {
            let turned = samples.map { sample -> (point: SIMD2<Double>, canvas: SIMD2<Double>) in
                let p = FloorplanMarkerRemapper.rotatedLocalPoint(
                    x: Double(sample.normalized.x), y: Double(sample.normalized.y), quarterTurns: quarterTurns
                )
                return (SIMD2(p.x, p.y), sample.canvas)
            }

            // Con una stanza sola non c'è niente da adattare: la scala viene dal
            // suo rettangolo, e i quarti di giro sono indistinguibili.
            let swapped = quarterTurns % 2 == 1
            let fallbackX = samples.map { $0.canvasSize.x / Double(swapped ? $0.normalizedSize.height : $0.normalizedSize.width) }
            let fallbackY = samples.map { $0.canvasSize.y / Double(swapped ? $0.normalizedSize.width : $0.normalizedSize.height) }

            let scaleX = slope(of: turned.map { ($0.point.x, $0.canvas.x) })
                ?? fallbackX.reduce(0, +) / Double(fallbackX.count)
            let scaleY = slope(of: turned.map { ($0.point.y, $0.canvas.y) })
                ?? fallbackY.reduce(0, +) / Double(fallbackY.count)

            let dx = turned.reduce(0.0) { $0 + $1.canvas.x - $1.point.x * scaleX } / Double(turned.count)
            let dy = turned.reduce(0.0) { $0 + $1.canvas.y - $1.point.y * scaleY } / Double(turned.count)

            let residual = turned.reduce(0.0) { total, sample in
                total + simd_distance(SIMD2(sample.point.x * scaleX + dx, sample.point.y * scaleY + dy),
                                      sample.canvas)
            } / Double(turned.count)

            let candidate = Transform(quarterTurns: quarterTurns, scaleX: scaleX, scaleY: scaleY,
                                      dx: dx, dy: dy, residual: residual)
            if residual < (best?.residual ?? .greatestFiniteMagnitude) { best = candidate }
        }
        return best
    }

    /// Pendenza ai minimi quadrati. `nil` quando i punti non hanno spread: con
    /// una stanza sola, o tutte allineate, non c'è niente da adattare.
    private static func slope(of pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 2 else { return nil }
        let meanX = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let meanY = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        let variance = pairs.reduce(0.0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard variance > 0.0001 else { return nil }
        let covariance = pairs.reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        return covariance / variance
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
              let transform = transform(document: document, linkedRooms: linkedRooms),
              // Una calibrazione che sbaglia di mezzo metro sulle stanze che
              // *conosce* non va usata per associare infissi: meglio non aprire
              // niente che aprire la finestra sbagliata.
              transform.residual < 0.5
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

    /// Perché non si è aperto niente.
    ///
    /// Ogni passaggio di questa catena può fallire in silenzio, e da fuori
    /// sembrano tutti lo stesso sintomo: la casa resta chiusa. Questi numeri li
    /// distinguono in un colpo d'occhio, senza dover ricompilare per capire a
    /// che punto si è rotta.
    struct Diagnostics {
        var markers = 0
        var withContact = 0
        var open = 0
        var calibrationRooms = 0
        var quarterTurns: Int?
        var residual: Double?
        var nearestDistance: Double?
        var matched = 0

        var summary: String {
            var parts = ["marker \(markers)", "contatti \(withContact)", "aperti \(open)"]
            if let quarterTurns, let residual {
                parts.append("rot \(quarterTurns)·90°")
                parts.append(String(format: "residuo %.2fm", residual))
            } else {
                parts.append("calibrazione ASSENTE (\(calibrationRooms) stanze)")
            }
            if let nearestDistance { parts.append(String(format: "vicino %.2fm", nearestDistance)) }
            parts.append("associati \(matched)")
            return parts.joined(separator: " · ")
        }
    }

    static func diagnostics(in document: DrawingDocument,
                            linkedRooms: [LinkedRoom],
                            markers: [(uuid: UUID, position: CGPoint)],
                            homeKit: HomeKitService) -> Diagnostics {
        var report = Diagnostics()
        report.markers = markers.count
        report.calibrationRooms = linkedRooms.filter { room in
            document.roomAreas.contains { $0.hmRoomUUID == room.hmRoomUUID }
        }.count

        var openPositions: [CGPoint] = []
        for marker in markers {
            guard let accessory = homeKit.accessory(for: marker.uuid) else { continue }
            let hasContact = accessory.services.contains { service in
                service.characteristics.contains { $0.characteristicType == HMCharacteristicTypeContactState }
            }
            guard hasContact else { continue }
            report.withContact += 1
            if isContactOpen(accessory, using: homeKit) {
                report.open += 1
                openPositions.append(marker.position)
            }
        }

        guard let transform = transform(document: document, linkedRooms: linkedRooms) else { return report }
        report.quarterTurns = transform.quarterTurns
        report.residual = transform.residual

        let openings = centres(in: document)
        for position in openPositions {
            let point = transform.metres(from: position)
            for opening in openings {
                let distance = simd_distance(point, opening.centre)
                if distance < (report.nearestDistance ?? .greatestFiniteMagnitude) {
                    report.nearestDistance = distance
                }
            }
        }

        report.matched = openOpenings(in: document, linkedRooms: linkedRooms,
                                      markers: markers, homeKit: homeKit).count
        return report
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
