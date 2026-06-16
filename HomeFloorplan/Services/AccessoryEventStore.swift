import Foundation
import SwiftData
import Observation
import HomeKit

// MARK: - AccessoryEventStore

/// Responsabilità:
/// 1. Salva nuovi AccessoryEvent nel ModelContainer SwiftData.
/// 2. Cleanup automatico on-write: elimina record più vecchi di 30 giorni.
/// 3. Query per accessorio negli ultimi N giorni.
/// 4. Query aggregata per pattern orari (consumata dall'AI).
@Observable
final class AccessoryEventStore {

    // MARK: - Properties

    private let modelContainer: ModelContainer

    /// Last time the rolling 30-day cleanup predicate-delete ran.
    /// Throttles the batch delete to once per hour instead of once per HomeKit notification.
    @ObservationIgnored private var lastCleanupDate: Date = .distantPast

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Save

    /// Salva un evento nel database.
    /// Il cleanup rolling 30 giorni è throttled a 1x/ora per evitare una
    /// predicate-delete sincrona su ogni notifica HomeKit.
    /// Il save esplicito è rimosso: SwiftData autosave gestisce il flush
    /// senza bloccare il main thread su ogni evento.
    @MainActor
    func saveEvent(_ dto: AccessoryEventDTO) {
        let context = modelContainer.mainContext

        let activeProfileIDStr = UserDefaults.standard.string(forKey: FamilyPresenceService.activeKey)
        let activeProfileID    = activeProfileIDStr.flatMap { UUID(uuidString: $0) }
        let event = AccessoryEvent(
            accessoryID:   dto.accessoryID,
            accessoryName: dto.accessoryName,
            roomID:        dto.roomID,
            roomName:      dto.roomName,
            state:         dto.state,
            brightness:    dto.brightness,
            eventType:     dto.eventType,
            profileID:     activeProfileID
        )
        context.insert(event)

        // Batch delete throttled to once per hour — running a predicate-delete
        // on every HomeKit notification was blocking the main thread unnecessarily.
        let now = Date()
        if now.timeIntervalSince(lastCleanupDate) > 3600 {
            let cutoff = Date(timeIntervalSinceNow: -30 * 24 * 3600)
            let predicate = #Predicate<AccessoryEvent> { $0.timestamp < cutoff }
            try? context.delete(model: AccessoryEvent.self, where: predicate)
            lastCleanupDate = now
        }
    }

    // MARK: - Queries

    /// Recupera tutti gli eventi per un accessorio negli ultimi N giorni.
    @MainActor
    func fetchEvents(for accessoryID: UUID, days: Int = 30) -> [AccessoryEvent] {
        let context = modelContainer.mainContext
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 24 * 3600)

        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate<AccessoryEvent> {
                $0.accessoryID == accessoryID && $0.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Restituisce pattern aggregati per tutti gli accessori negli ultimi N giorni.
    /// I pattern sono ordinati per confidenza decrescente.
    @MainActor
    func fetchPatterns(days: Int = 14) -> [AccessoryPattern] {
        let context = modelContainer.mainContext
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 24 * 3600)

        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate<AccessoryEvent> { $0.timestamp >= cutoff }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        // Raggruppa per accessoryID
        let grouped = Dictionary(grouping: events, by: \.accessoryID)

        return grouped.compactMap { (accessoryID, eventsForAccessory) in
            buildPattern(accessoryID: accessoryID, events: eventsForAccessory)
        }.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - DTO Factory

    // HAP UUID costanti (lowercase) — allineate con ActivityLoggerService
    private static let onUUID             = "00000025-0000-1000-8000-0026bb765291"
    private static let brightnessUUID     = "00000008-0000-1000-8000-0026bb765291"
    private static let targetPositionUUID = "0000007c-0000-1000-8000-0026bb765291"
    private static let currentPositionUUID = "0000006d-0000-1000-8000-0026bb765291"
    /// Contatto: aperto/chiuso (HMCharacteristicTypeContactState)
    private static let contactStateUUID   = "0000006a-0000-1000-8000-0026bb765291"
    /// Movimento (HMCharacteristicTypeMotionDetected)
    private static let motionDetectedUUID = "00000022-0000-1000-8000-0026bb765291"
    /// Switch programmabile / generico
    private static let activeUUID         = "000000b0-0000-1000-8000-0026bb765291"

    /// Crea un AccessoryEventDTO da una HMCharacteristic se il tipo è rilevante.
    /// Restituisce nil per sensori ambientali, termostati, serrature e altri tipi
    /// che non vanno in questo store.
    static func makeDTO(
        from characteristic: HMCharacteristic,
        value: Any?,
        accessory: HMAccessory
    ) -> AccessoryEventDTO? {
        let type = characteristic.characteristicType.lowercased()

        func intVal(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let u = v as? UInt8 { return Int(u) }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        }
        func doubleVal(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let f = v as? Float { return Double(f) }
            if let i = v as? Int { return Double(i) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }

        let roomID = accessory.room.flatMap { _ in nil as UUID? } // HMRoom non ha UUID pubblico
        let roomName = accessory.room?.name

        switch type {
        case onUUID:
            // Luce o switch generico: distingui per categoria servizio
            guard let raw = intVal(value) else { return nil }
            let state = raw != 0
            // Recupera brightness se presente nello stesso servizio
            let brightness: Double? = characteristic.service?.characteristics
                .first(where: { $0.characteristicType.lowercased() == brightnessUUID })
                .flatMap { doubleVal($0.value).map { $0 / 100.0 } }
            // Tipo: se il servizio ha una brightness, è una luce; altrimenti switch
            let hasColor = characteristic.service?.characteristics
                .contains(where: { $0.characteristicType.lowercased() == brightnessUUID }) ?? false
            let eventType = hasColor ? AccessoryEventType.light.rawValue : AccessoryEventType.switch.rawValue

            return AccessoryEventDTO(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomID: roomID,
                roomName: roomName,
                state: state,
                brightness: brightness,
                eventType: eventType
            )

        case targetPositionUUID:
            // Tapparella/blind
            guard let raw = intVal(value) else { return nil }
            let state = raw > 0 // posizione > 0 = aperto
            return AccessoryEventDTO(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomID: roomID,
                roomName: roomName,
                state: state,
                brightness: nil,
                eventType: AccessoryEventType.blind.rawValue
            )

        case contactStateUUID:
            // Sensore contatto: 0 = chiuso, 1 = aperto
            guard let raw = intVal(value) else { return nil }
            let state = raw == 0 // "chiuso" = true (contatto integro)
            return AccessoryEventDTO(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomID: roomID,
                roomName: roomName,
                state: state,
                brightness: nil,
                eventType: AccessoryEventType.contact.rawValue
            )

        case motionDetectedUUID:
            // Sensore di movimento
            guard let raw = intVal(value) else { return nil }
            let state = raw != 0
            return AccessoryEventDTO(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomID: roomID,
                roomName: roomName,
                state: state,
                brightness: nil,
                eventType: AccessoryEventType.motion.rawValue
            )

        case activeUUID:
            // Termostati, fan, purificatori, prese smart — usano Active (0xB0) invece di PowerState
            guard let raw = intVal(value) else { return nil }
            let state = raw != 0
            let serviceChars = characteristic.service?.characteristics ?? []
            func hasChar(_ uuid: String) -> Bool {
                serviceChars.contains { $0.characteristicType.lowercased() == uuid }
            }
            let eventType: String
            if hasChar("000000b2-0000-1000-8000-0026bb765291") {   // TargetHeaterCoolerState
                eventType = AccessoryEventType.thermostat.rawValue
            } else if hasChar("00000029-0000-1000-8000-0026bb765291") {  // RotationSpeed
                eventType = AccessoryEventType.fan.rawValue
            } else if hasChar("000000a8-0000-1000-8000-0026bb765291") {  // TargetAirPurifierState
                eventType = AccessoryEventType.airPurifier.rawValue
            } else {
                eventType = AccessoryEventType.outlet.rawValue
            }
            return AccessoryEventDTO(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                roomID: roomID,
                roomName: roomName,
                state: state,
                brightness: nil,
                eventType: eventType
            )

        default:
            return nil
        }
    }

    // MARK: - Pattern Building

    private func buildPattern(accessoryID: UUID, events: [AccessoryEvent]) -> AccessoryPattern? {
        guard !events.isEmpty, let first = events.first else { return nil }

        let onEvents = events.filter { $0.state }
        let offEvents = events.filter { !$0.state }

        // Calcola orario medio di accensione
        let avgOnTime = averageTimeString(from: onEvents.map(\.timestamp))
        let avgOffTime = averageTimeString(from: offEvents.map(\.timestamp))

        // Pattern giorni della settimana (giorni in cui si è attivato)
        let weekdays = Array(Set(onEvents.map(\.weekday))).sorted()

        // Confidenza = rapporto tra giorni con attività / giorni nella finestra (14)
        let activeDays = Set(events.map {
            Calendar.current.startOfDay(for: $0.timestamp)
        }).count
        let confidence = min(1.0, Double(activeDays) / 14.0)

        return AccessoryPattern(
            accessoryID: accessoryID,
            accessoryName: first.accessoryName,
            eventType: first.eventType,
            avgOnTime: avgOnTime ?? "--:--",
            avgOffTime: avgOffTime ?? "--:--",
            weekdayPattern: weekdays,
            confidence: confidence
        )
    }

    /// Calcola l'orario medio da un array di Date, considerando solo ore e minuti.
    private func averageTimeString(from dates: [Date]) -> String? {
        guard !dates.isEmpty else { return nil }

        let cal = Calendar.current
        var totalMinutes = 0
        for date in dates {
            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            totalMinutes += hour * 60 + minute
        }
        let avg = totalMinutes / dates.count
        let h = avg / 60
        let m = avg % 60
        return String(format: "%02d:%02d", h, m)
    }
}
