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
/// scelto dall'utente nell'editor 2D.
enum FloorplanOpeningMatcher {

    // MARK: - Calibrazione

    /// Da coordinate normalizzate sull'immagine a metri nel disegno.
    ///
    /// **Si inverte l'export, non lo si indovina.** I tentativi precedenti
    /// ricavavano questa trasformazione confrontando le stanze collegate con le
    /// aree del disegno: approssimato, e del tutto inutile quando `linkedRooms`
    /// è vuoto o i suoi UUID non combaciano più con quelli delle aree — che è
    /// esattamente il caso in cui si è rotto, «calibrazione ASSENTE (0 stanze)».
    ///
    /// L'inquadratura invece è **deterministica**: `renderAdaptiveToImage`
    /// esporta sempre a 1600×1000, con margine del 10% sul lato lungo, centrata
    /// sul bounding box del disegno e ruotata di quarti di giro. Sono tutti dati
    /// che stanno nel documento, quindi la mappa si calcola esatta e non serve
    /// nessuna stanza collegata.
    struct Transform {
        var centre: CGPoint
        var scaleFactor: Double
        var rotation: DrawingExportRotation

        static let outputWidth: Double = 1600
        static let outputHeight: Double = 1000

        /// L'inversa esatta di `projectedPoint` dell'export.
        func metres(from normalized: CGPoint) -> SIMD2<Double> {
            let rotatedX = (Double(normalized.x) * Self.outputWidth - Self.outputWidth / 2) / scaleFactor
            let rotatedY = (Double(normalized.y) * Self.outputHeight - Self.outputHeight / 2) / scaleFactor

            let (dx, dy): (Double, Double) = switch rotation {
            case .asDrawn:          (rotatedX, rotatedY)
            case .clockwise:        (rotatedY, -rotatedX)
            case .upsideDown:       (-rotatedX, -rotatedY)
            case .counterClockwise: (-rotatedY, rotatedX)
            }

            let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
            return SIMD2((Double(centre.x) + dx) * metresPerPoint,
                         (Double(centre.y) + dy) * metresPerPoint)
        }
    }

    /// Il bounding box che l'export usa per inquadrare. Deve includere
    /// **esattamente** ciò che include lui, o il centro slitta.
    private static func contentBounds(of document: DrawingDocument) -> CGRect? {
        var points: [CGPoint] = document.walls.flatMap { [$0.start, $0.end] }
        points += document.roomLabels.map(\.position)
        for area in document.roomAreas { points += area.effectivePoints }
        for item in document.furnitureItems {
            points.append(CGPoint(x: item.rect.minX, y: item.rect.minY))
            points.append(CGPoint(x: item.rect.maxX, y: item.rect.maxY))
        }
        guard !points.isEmpty else { return nil }

        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func transform(document: DrawingDocument,
                          exportRotation: DrawingExportRotation) -> Transform? {
        guard let bounds = contentBounds(of: document) else { return nil }

        let quarterTurned = !exportRotation.quarterTurns.isMultiple(of: 2)
        let drawingWidth = quarterTurned ? bounds.height : bounds.width
        let drawingHeight = quarterTurned ? bounds.width : bounds.height
        let longestSide = max(drawingWidth, drawingHeight)
        guard longestSide > 0 else { return nil }

        let margin = longestSide * 0.10
        let scaleFactor = min(Transform.outputWidth / Double(drawingWidth + margin * 2),
                              Transform.outputHeight / Double(drawingHeight + margin * 2))

        return Transform(centre: CGPoint(x: bounds.midX, y: bounds.midY),
                         scaleFactor: scaleFactor,
                         rotation: exportRotation)
    }

    // MARK: - Aperture

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
                             exportRotation: DrawingExportRotation,
                             markers: [(uuid: UUID, position: CGPoint)],
                             homeKit: HomeKitService,
                             maxDistance: Double = 0.80) -> Set<UUID> {
        guard let transform = transform(document: document, exportRotation: exportRotation) else { return [] }
        let openings = centres(in: document)
        guard !openings.isEmpty else { return [] }

        var result: Set<UUID> = []
        for marker in markers {
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  isContactOpen(accessory, using: homeKit)
            else { continue }

            let point = transform.metres(from: marker.position)
            var best: (id: UUID, distance: Double)?
            for opening in openings {
                let distance = simd_distance(point, opening.centre)
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (opening.id, distance)
                }
            }
            if let best, best.distance <= maxDistance { result.insert(best.id) }
        }
        return result
    }

    // MARK: - Lettura HomeKit

    /// `true` se l'accessorio espone un contatto e il contatto è aperto.
    ///
    /// ⚠️ Si legge `HomeKitService.characteristicValues`, **non**
    /// `HMCharacteristic.value`. Quest'ultimo resta `nil` finché nessuno ha
    /// fatto `readValue`, e HomeKit non lo popola da solo: leggerlo direttamente
    /// dava «chiuso» per qualunque sensore mai osservato in quella sessione.
    ///
    /// L'altro motivo per passare di lì è che quel dizionario è `@Observable`:
    /// una vista che lo legge si ridisegna quando un contatto cambia.
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

    // MARK: - Diagnostica

    /// Perché non si è aperto niente. Ogni anello di questa catena può fallire
    /// in silenzio, e da fuori sembrano tutti lo stesso sintomo.
    struct Diagnostics {
        /// Un sensore di contatto, con quello che dice e dove cade.
        ///
        /// La distanza si misura su **tutti** i contatti, non solo su quelli
        /// aperti: è l'unico modo di verificare la calibrazione quando la casa è
        /// chiusa — e la casa è chiusa quasi sempre, che è esattamente il
        /// momento in cui non si riusciva a capire se funzionasse.
        struct Contact {
            var name: String
            var raw: String
            var distance: Double?
        }

        var markers = 0
        var openings = 0
        var rotation: DrawingExportRotation?
        var contacts: [Contact] = []
        var matched = 0

        var open: Int { contacts.filter { $0.raw != "0" && $0.raw != "-" }.count }

        var summary: String {
            var parts = ["marker \(markers)", "contatti \(contacts.count)",
                         "aperti \(open)", "vani \(openings)"]
            parts.append(rotation.map { "rot \($0.quarterTurns)" } ?? "NO CALIBRAZIONE")
            parts.append("associati \(matched)")

            let detail = contacts.map { contact in
                let distance = contact.distance.map { String(format: "%.2fm", $0) } ?? "?"
                return "\(contact.name)=\(contact.raw)@\(distance)"
            }.joined(separator: "  ")

            return parts.joined(separator: " · ") + (detail.isEmpty ? "" : "\n" + detail)
        }
    }

    static func diagnostics(in document: DrawingDocument,
                            exportRotation: DrawingExportRotation,
                            markers: [(uuid: UUID, position: CGPoint)],
                            homeKit: HomeKitService) -> Diagnostics {
        var report = Diagnostics()
        report.markers = markers.count
        let openings = centres(in: document)
        report.openings = openings.count
        let transform = transform(document: document, exportRotation: exportRotation)
        report.rotation = transform == nil ? nil : exportRotation

        for marker in markers {
            guard let accessory = homeKit.accessory(for: marker.uuid) else { continue }
            var raw: String?
            for service in accessory.services {
                for characteristic in service.characteristics
                where characteristic.characteristicType == HMCharacteristicTypeContactState {
                    let value = homeKit.value(for: characteristic) ?? characteristic.value
                    raw = value.map { "\($0)" } ?? "-"
                }
            }
            guard let raw else { continue }

            var nearest: Double?
            if let transform {
                let point = transform.metres(from: marker.position)
                for opening in openings {
                    let distance = simd_distance(point, opening.centre)
                    if distance < (nearest ?? .greatestFiniteMagnitude) { nearest = distance }
                }
            }

            report.contacts.append(.init(name: String(accessory.name.prefix(12)),
                                         raw: raw,
                                         distance: nearest))
        }

        report.matched = openOpenings(in: document, exportRotation: exportRotation,
                                      markers: markers, homeKit: homeKit).count
        return report
    }
}
