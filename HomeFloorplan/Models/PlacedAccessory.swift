import Foundation
import SwiftData

@Model
final class PlacedAccessory : Identifiable{
    @Attribute(.unique) var id: UUID
    /// UUID dell'HMAccessory in HomeKit (HMAccessory.uniqueIdentifier).
    /// Non duplichiamo i dati dell'accessorio: la fonte di verità resta HomeKit.
    var homeKitAccessoryUUID: UUID
    var positionX: Double   // 0...1
    var positionY: Double   // 0...1
    /// UUID della stanza disegnata/linkata sul floorplan che contiene il marker.
    /// Nil per marker legacy o marker fuori da una stanza linkata.
    var linkedRoomUUID: UUID?
    /// L'apertura che questo accessorio sorveglia, quando è un sensore di
    /// contatto appoggiato su una porta o una finestra.
    ///
    /// Gemello di `linkedRoomUUID`: derivato dalla posizione quando il marker
    /// si posa, ricalcolato se lo si sposta, correggibile a mano. Prima la
    /// corrispondenza si calcolava a ogni apertura della vista 3D — invisibile,
    /// non correggibile, e per questo impossibile da diagnosticare quando
    /// sbagliava.
    var linkedOpeningID: UUID?
    /// Altezza da terra in metri, per gli oggetti che in 3D stanno in verticale.
    ///
    /// Il disegno 2D non può contenerla: una pianta non ha quota. `nil` vuol
    /// dire «usa il default del tipo» — soffitto per un faretto, tavolo per una
    /// lampada da appoggio.
    var mountHeight: Double?
    /// Dove punta la luce: basso, intorno, alto. Anche questa non esiste in
    /// pianta, e cambia completamente come la stanza si illumina.
    var lightDirectionRaw: String?
    /// Etichetta personalizzata opzionale (sovrascrive il nome HomeKit se valorizzata)
    var customLabel: String?
    var floorplan: Floorplan?
    
    init(homeKitAccessoryUUID: UUID,
         position: NormalizedPoint,
         customLabel: String? = nil,
         linkedRoomUUID: UUID? = nil) {
        self.id = UUID()
        self.homeKitAccessoryUUID = homeKitAccessoryUUID
        self.positionX = position.x
        self.positionY = position.y
        self.customLabel = customLabel
        self.linkedRoomUUID = linkedRoomUUID
    }
    
    /// Accesso conveniente come NormalizedPoint
    var position: NormalizedPoint {
        get { NormalizedPoint(x: positionX, y: positionY) }
        set {
            positionX = newValue.x
            positionY = newValue.y
        }
    }
}
