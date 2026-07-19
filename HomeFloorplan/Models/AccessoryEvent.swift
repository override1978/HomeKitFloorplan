import Foundation
import SwiftData

// MARK: - AccessoryEvent

/// Registrazione puntuale dello stato di un accessorio HomeKit.
/// Usato per costruire lo storico delle abitudini e alimentare le feature AI.
/// I sensori ambientali (temperatura, umidità, CO2) NON vanno qui — hanno SensorReading.
@Model
final class AccessoryEvent {
    #Index<AccessoryEvent>([\.timestamp], [\.accessoryID])

    @Attribute(.unique) var id: UUID
    var accessoryID: UUID
    var accessoryName: String
    /// UUID della stanza HomeKit (opzionale).
    var roomID: UUID?
    var roomName: String?
    /// true = on/aperto, false = off/chiuso.
    var state: Bool
    /// Luminosità 0.0–1.0 per luci dimmerabili. Nil per altri tipi.
    var brightness: Double?
    var timestamp: Date
    /// Giorno settimana secondo Calendar (1 = domenica … 7 = sabato).
    var weekday: Int
    /// Tipo dispositivo: "light", "blind", "switch", "contact", "motion".
    var eventType: String
    /// Family profile active when this event was recorded. Nil = global / no profile.
    var profileID: UUID?
    /// Origine del cambiamento: "app" (scritture di app/engine, echi inclusi)
    /// o "external" (mano umana o automazioni HomeKit native). Permette alle
    /// analisi di distinguere l'uso reale dall'attività generata dal sistema.
    var originRaw: String = "external"

    init(
        id: UUID = UUID(),
        accessoryID: UUID,
        accessoryName: String,
        roomID: UUID? = nil,
        roomName: String? = nil,
        state: Bool,
        brightness: Double? = nil,
        timestamp: Date = Date(),
        eventType: String,
        profileID: UUID? = nil,
        originRaw: String = "external"
    ) {
        self.originRaw = originRaw
        self.id = id
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.roomID = roomID
        self.roomName = roomName
        self.state = state
        self.brightness = brightness
        self.timestamp = timestamp
        self.weekday   = Calendar.current.component(.weekday, from: timestamp)
        self.eventType = eventType
        self.profileID = profileID
    }
}

// MARK: - AccessoryEventType

/// Tipi di dispositivo supportati da AccessoryEvent.
enum AccessoryEventType: String {
    case light      = "light"
    case blind      = "blind"
    case `switch`   = "switch"
    case contact    = "contact"
    case motion     = "motion"
    // Dispositivi che usano "Active" (0xB0) invece di "PowerState" (0x25)
    case thermostat = "thermostat"
    case fan        = "fan"
    case airPurifier = "airPurifier"
    case humidifier = "humidifier"
    case outlet     = "outlet"
}

// MARK: - AccessoryEventDTO

/// DTO senza riferimento a SwiftData, usato da HomeKitService per costruire eventi.
struct AccessoryEventDTO {
    let accessoryID: UUID
    let accessoryName: String
    let roomID: UUID?
    let roomName: String?
    let state: Bool
    let brightness: Double?
    let eventType: String
    /// Vedi `AccessoryEvent.originRaw`. Default "external"; i call site delle
    /// scritture dell'app la impostano a "app".
    var origin: String = "external"
}

// MARK: - AccessoryPattern

/// Pattern aggregato per un accessorio, calcolato su una finestra di N giorni.
/// Consumato dall'AI per generare suggerimenti.
struct AccessoryPattern {
    let accessoryID: UUID
    let accessoryName: String
    let eventType: String
    /// Orario medio di accensione (es. "07:15").
    let avgOnTime: String
    /// Orario medio di spegnimento (es. "23:30").
    let avgOffTime: String
    /// Giorni della settimana in cui l'accessorio si attiva solitamente (1–7).
    let weekdayPattern: [Int]
    /// Confidenza del pattern 0.0–1.0 (basata sul numero di campioni).
    let confidence: Double
}
