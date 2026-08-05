import Foundation

// MARK: - FloorplanArchive

/// Una planimetria messa da parte: tutto ciò che la ridisegna, **tranne
/// l'immagine**.
///
/// L'immagine sta in un file a parte, indicizzato dall'id della copia. Non è un
/// dettaglio implementativo: `ArchiveStore` carica l'intero indice all'avvio, e
/// qualche megabyte di sfondo dentro quel JSON verrebbe letto a ogni lancio
/// dell'app anche da chi non apre mai l'archivio.
struct FloorplanArchive: Codable, Sendable {

    /// Un marker con l'accessorio identificato **anche per nome e stanza**.
    ///
    /// L'UUID di HomeKit da solo non basta: su un altro device non coincide, e
    /// se l'accessorio viene ri-accoppiato non coincide più nemmeno su questo.
    /// Il nome permette di riagganciarlo, ed è lo stesso criterio che
    /// `HomeKitEntityResolver` usa già per i marker sincronizzati.
    struct Marker: Codable, Sendable {
        var homeKitAccessoryUUID: UUID
        var accessoryName: String?
        var roomName: String?
        var positionX: Double
        var positionY: Double
        var linkedRoomUUID: UUID?
        var customLabel: String?
    }

    var name: String
    var homeUUID: UUID?
    var tapModeRaw: String
    var exteriorFillColorIndex: Int
    var drawingVisualExportStyleRaw: String
    var drawingExportRotationRaw: String
    var linkedRoomsJSON: Data?
    var drawingDocumentJSON: Data?
    var markers: [Marker]
    /// Byte dell'immagine, per sapere cosa aspettarsi senza aprire il file.
    var imageByteCount: Int
}
