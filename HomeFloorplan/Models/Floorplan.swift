import Foundation
import SwiftData

enum FloorplanTapMode: String, Codable, CaseIterable {
    case openPanel       // tap → apre il pannello di controllo
    case quickToggle     // tap → toggle immediato (se possibile), long press → pannello
    
    var localized: String {
        switch self {
        case .openPanel: return "Pannello"
        case .quickToggle: return "Toggle rapido"
        }
    }
    
    var systemImage: String {
        switch self {
        case .openPanel: return "rectangle.stack"
        case .quickToggle: return "bolt.fill"
        }
    }
}

@Model
final class Floorplan {
    @Attribute(.unique) var id: UUID
    var name: String
    var imageFilename: String
    var createdAt: Date
    var updatedAt: Date
    /// Modalità di interazione sui marker. Default: aprire il pannello.
    /// rawValue salvato come String (Codable enum funziona out-of-the-box con SwiftData).
    var tapModeRaw: String = FloorplanTapMode.openPanel.rawValue
    
    @Relationship(deleteRule: .cascade, inverse: \PlacedAccessory.floorplan)
    var accessories: [PlacedAccessory] = []
    var homeUUID: UUID?
    
    init(name: String, imageFilename: String, homeUUID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.imageFilename = imageFilename
        self.createdAt = .now
        self.updatedAt = .now
        self.homeUUID = homeUUID
    }
    
    var tapMode: FloorplanTapMode {
        get { FloorplanTapMode(rawValue: tapModeRaw) ?? .openPanel }
        set { tapModeRaw = newValue.rawValue }
    }
}


