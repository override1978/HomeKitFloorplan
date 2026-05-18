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
    /// Etichetta personalizzata opzionale (sovrascrive il nome HomeKit se valorizzata)
    var customLabel: String?
    var floorplan: Floorplan?
    
    init(homeKitAccessoryUUID: UUID,
         position: NormalizedPoint,
         customLabel: String? = nil) {
        self.id = UUID()
        self.homeKitAccessoryUUID = homeKitAccessoryUUID
        self.positionX = position.x
        self.positionY = position.y
        self.customLabel = customLabel
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
