import SwiftUI

// MARK: - FloorplanRotation

/// Rotazione 90° della planimetria (design v3, regola mobile 3): una piantina
/// larga su uno schermo alto spreca metà viewport — se i due aspect
/// differiscono di oltre 1.5× e girarla aiuta, la si mostra ruotata.
///
/// La rotazione è DATI, non trasformazioni: la bitmap viene ruotata una volta
/// (e cache-ata) e le coordinate normalizzate vengono trasposte alla fonte.
/// Tutto ciò che sta a valle — imageRect, marker, tap resolver, collisioni,
/// zoom, contro-scala — lavora sull'immagine ruotata come se fosse nata così,
/// e le etichette restano orizzontali senza contro-rotazioni. L'alternativa
/// (`rotationEffect` sul subtree + overlay contro-ruotati) avrebbe attraversato
/// lo stack dei gesti, che è la zona più fragile del file.
///
/// Attiva SOLO in visualizzazione: in modifica si lavora sempre
/// nell'orientamento originale, così le scritture (posizioni marker) non
/// richiedono mai la trasformazione inversa.
enum FloorplanRotation {

    /// Soglia di sproporzione oltre la quale la rotazione conviene.
    static let mismatchThreshold: CGFloat = 1.5

    /// Vero se planimetria e viewport sono sproporzionati oltre soglia E la
    /// rotazione riduce la sproporzione.
    static func shouldRotate(imageSize: CGSize, container: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return false }
        let planAspect = imageSize.width / imageSize.height
        let viewAspect = container.width / container.height
        let mismatch = max(planAspect / viewAspect, viewAspect / planAspect)
        guard mismatch > mismatchThreshold else { return false }
        let rotatedAspect = 1 / planAspect
        let rotatedMismatch = max(rotatedAspect / viewAspect, viewAspect / rotatedAspect)
        return rotatedMismatch < mismatch
    }

    // MARK: Trasposizione coordinate (90° orario)

    /// (x, y) normalizzato nell'originale → nell'immagine ruotata 90° CW.
    /// Verifica: (0,0) alto-sinistra → (1,0) alto-destra; (1,0) → (1,1).
    static func point(_ p: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: 1 - p.y, y: p.x)
    }

    static func codablePoint(_ p: CodablePoint) -> CodablePoint {
        CodablePoint(x: 1 - p.y, y: p.x)
    }

    static func rect(_ r: CodableRect) -> CodableRect {
        CodableRect(x: 1 - r.y - r.height, y: r.x, width: r.height, height: r.width)
    }

    static func room(_ room: LinkedRoom) -> LinkedRoom {
        var rotated = room
        rotated.normalizedRect = rect(room.normalizedRect)
        rotated.normalizedPoints = room.normalizedPoints?.map(codablePoint)
        return rotated
    }

    static func rooms(_ rooms: [LinkedRoom]) -> [LinkedRoom] {
        rooms.map(room)
    }

    // MARK: Bitmap

    /// Ruota la bitmap di 90° orario. Costosa: passare SEMPRE dalla cache.
    static func rotatedImage(_ image: UIImage) -> UIImage {
        let newSize = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width, y: 0)
            ctx.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

// MARK: - FloorplanRotatedImageCache

/// Memoizza la bitmap ruotata per l'immagine corrente. Classe in @State come
/// gli altri cache dell'editor: la mutazione interna non invalida la view.
final class FloorplanRotatedImageCache {
    private var sourceID: ObjectIdentifier?
    private var rotated: UIImage?

    func rotated(for image: UIImage) -> UIImage {
        let id = ObjectIdentifier(image)
        if sourceID == id, let rotated { return rotated }
        let result = FloorplanRotation.rotatedImage(image)
        sourceID = id
        rotated = result
        return result
    }
}
