import Foundation
import SwiftData

/// Categoria di evento registrato nel log attività.
enum ActivityEventCategory: String, Codable {
    /// Esecuzione di una scena HomeKit.
    case sceneExecution
    /// Scrittura diretta di una caratteristica (toggle, slider, ecc.).
    case write
    /// Cambiamento proveniente da una fonte esterna (automazione, altra app, sensore).
    case externalChange
}

/// Singolo evento persistito nel log attività dell'app.
@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var categoryRaw: String
    var title: String
    var subtitle: String
    var symbolName: String
    var accessoryName: String?
    var roomName: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: ActivityEventCategory,
        title: String,
        subtitle: String,
        symbolName: String,
        accessoryName: String? = nil,
        roomName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.categoryRaw = category.rawValue
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.accessoryName = accessoryName
        self.roomName = roomName
    }

    /// Categoria tipizzata derivata da `categoryRaw`.
    var category: ActivityEventCategory {
        ActivityEventCategory(rawValue: categoryRaw) ?? .write
    }

    /// Data normalizzata a mezzanotte (UTC) usata per raggruppare per giorno.
    var sectionDate: Date {
        Calendar.current.startOfDay(for: timestamp)
    }
}
