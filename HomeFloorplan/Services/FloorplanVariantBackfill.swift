import SwiftData
import SwiftUI

// MARK: - FloorplanVariantBackfill

/// Produce la variante mancante di una planimetria, senza riaprire l'editor.
///
/// Esiste perché la sola alternativa era chiedere all'utente di riesportare a
/// mano ogni volta che cambiava qualcosa nel modo in cui le varianti vengono
/// salvate — cosa che è successa tre volte di fila, ed è il segnale che il
/// debito lo stava pagando la persona sbagliata. Il documento vettoriale è
/// persistito, quindi ridisegnare è sempre possibile: non c'era ragione di
/// trattarlo come un'informazione che solo l'editor possiede.
///
/// Ridisegna solo ciò che manca, una planimetria alla volta e solo quando la
/// si sta guardando: un giro su tutte all'avvio costerebbe un raster per
/// planimetria nel momento in cui l'app deve essere pronta.
@MainActor
enum FloorplanVariantBackfill {

    /// Vero quando manca la seconda variante ma il disegno per produrla c'è.
    static func needsAlternate(_ floorplan: Floorplan) -> Bool {
        floorplan.imageDataAlternate == nil && floorplan.drawingDocument != nil
    }

    /// Disegna e salva la variante mancante.
    ///
    /// Non tocca `imageData`, `linkedRooms` né `updatedAt`: la planimetria non
    /// è cambiata, si è solo aggiunto un modo di guardarla. Muovere
    /// `updatedAt` farebbe ripartire la decodifica dell'immagine principale e
    /// segnalerebbe a CloudKit una modifica che non c'è stata.
    @discardableResult
    static func fill(_ floorplan: Floorplan, in context: ModelContext) -> Bool {
        guard needsAlternate(floorplan), let document = floorplan.drawingDocument else { return false }

        let chosen = DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard
        let other: DrawingVisualExportStyle = chosen == .architecturalDark ? .architectural : .architecturalDark

        let (image, _) = FloorplanDrawingRenderer.renderAdaptive(
            document,
            visualStyle: other,
            exportRotation: floorplan.drawingExportRotation,
            exteriorFillColorIndex: floorplan.exteriorFillColorIndex,
            viewportSize: FloorplanDrawingRenderer.defaultViewportSize,
            transparentBackground: true)

        guard let data = image.pngData() else { return false }
        floorplan.imageDataAlternate = data
        try? context.save()
        dprint("🎨 Variante \(other.rawValue) generata per \(floorplan.name)")
        return true
    }
}
