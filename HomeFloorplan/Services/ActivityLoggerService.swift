import Foundation
import SwiftData
import HomeKit
import Observation

/// Servizio che persiste gli eventi di attività dell'app nel log SwiftData.
///
/// Questo servizio è `@MainActor` perché SwiftData richiede che tutte le
/// operazioni sul `ModelContext` avvengano sullo stesso attore. Il contesto
/// viene creato internamente partendo dal `ModelContainer` condiviso dell'app.
@MainActor
@Observable
final class ActivityLoggerService {

    // MARK: - Configurazione

    /// Numero massimo di eventi mantenuti nel log.
    private let maxEvents = 500
    /// Età massima (in giorni) degli eventi mantenuti nel log.
    private let maxAgeDays = 7
    /// Finestra temporale entro cui una scrittura viene considerata "nostra"
    /// per evitare di loggarla di nuovo come cambiamento esterno.
    private let echoWindow: TimeInterval = 2.0
    /// Finestra di debounce: stessa caratteristica loggata al massimo ogni N secondi.
    private let debounceWindow: TimeInterval = 5.0

    // MARK: - Stato interno

    private let context: ModelContext

    /// UUID delle caratteristiche scritte di recente da noi,
    /// mappati al timestamp della scrittura. Usato per echo-dedup.
    private var recentWriteKeys: [UUID: Date] = [:]

    /// Ultimo timestamp di log per caratteristica, usato per debounce.
    private var lastLogTime: [UUID: Date] = [:]

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.context = ModelContext(modelContainer)
    }

    // MARK: - API pubblica

    /// Logga l'esecuzione di una scena HomeKit.
    func logSceneExecution(sceneName: String, actionCount: Int) {
        let subtitle = "\(actionCount) \(actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "action") : String(localized: "count.action.plural", defaultValue: "actions"))"
        insert(ActivityEvent(
            category: .sceneExecution,
            title: sceneName,
            subtitle: subtitle,
            symbolName: "play.fill"
        ))
    }

    /// Logga la scrittura di una caratteristica da parte dell'utente.
    /// Registra anche l'UUID per il successivo echo-dedup.
    func logWrite(
        characteristicUUID: UUID,
        accessoryName: String,
        roomName: String?,
        characteristicDescription: String,
        value: String
    ) {
        // Marca come "nostra" scrittura per evitare echo
        recentWriteKeys[characteristicUUID] = Date()

        let subtitle = roomName.map { "\($0) · \(characteristicDescription): \(value)" }
                    ?? "\(characteristicDescription): \(value)"
        insert(ActivityEvent(
            category: .write,
            title: accessoryName,
            subtitle: subtitle,
            symbolName: "slider.horizontal.3",
            accessoryName: accessoryName,
            roomName: roomName
        ))
    }

    /// Logga un cambiamento esterno ricevuto dal delegate HomeKit.
    /// Restituisce senza fare nulla se il valore è il risultato di una nostra scrittura
    /// recente (echo-dedup) o se la stessa caratteristica è stata loggata da poco (debounce).
    func logExternalChange(
        characteristicUUID: UUID,
        accessoryName: String,
        roomName: String?,
        characteristicDescription: String,
        value: String
    ) {
        let now = Date()

        // Echo-dedup: se abbiamo scritto noi questa characteristic di recente, ignora
        if let writeDate = recentWriteKeys[characteristicUUID],
           now.timeIntervalSince(writeDate) < echoWindow {
            return
        }

        // Debounce: max un log ogni `debounceWindow` secondi per la stessa characteristic
        if let lastTime = lastLogTime[characteristicUUID],
           now.timeIntervalSince(lastTime) < debounceWindow {
            return
        }
        lastLogTime[characteristicUUID] = now

        let subtitle = roomName.map { "\($0) · \(characteristicDescription): \(value)" }
                    ?? "\(characteristicDescription): \(value)"
        insert(ActivityEvent(
            category: .externalChange,
            title: accessoryName,
            subtitle: subtitle,
            symbolName: "antenna.radiowaves.left.and.right",
            accessoryName: accessoryName,
            roomName: roomName
        ))
    }

    /// Elimina tutti gli eventi dal log.
    func clearAll() {
        try? context.delete(model: ActivityEvent.self)
        try? context.save()
    }

    // MARK: - Inserimento e pruning

    private func insert(_ event: ActivityEvent) {
        context.insert(event)
        pruneIfNeeded()
        try? context.save()
    }

    /// Rimuove eventi vecchi o in eccesso rispetto ai limiti configurati.
    private func pruneIfNeeded() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()

        // Elimina per età
        let oldDescriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        if let old = try? context.fetch(oldDescriptor) {
            old.forEach { context.delete($0) }
        }

        // Elimina per conteggio (mantieni solo i più recenti)
        // fetchCount is a cheap COUNT(*) — skip the expensive sort unless we're actually over cap.
        if (try? context.fetchCount(FetchDescriptor<ActivityEvent>())) ?? 0 > maxEvents {
            var countDescriptor = FetchDescriptor<ActivityEvent>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            countDescriptor.fetchLimit = maxEvents + 1
            if let all = try? context.fetch(countDescriptor), all.count > maxEvents {
                all.dropFirst(maxEvents).forEach { context.delete($0) }
            }
        }
    }
}

// MARK: - Helpers per descrizione caratteristiche HomeKit

extension ActivityLoggerService {

    /// Converte una `HMCharacteristic` e il suo valore in stringhe leggibili.
    static func describe(characteristic: HMCharacteristic, value: Any?) -> (name: String, valueString: String) {
        let name = humanReadableName(for: characteristic)
        let valueStr = humanReadableValue(for: characteristic, value: value)
        return (name, valueStr)
    }

    // HAP UUID costanti (lowercase) — stesse usate in HomeKitScenesService
    private static let onUUID              = "00000025-0000-1000-8000-0026bb765291"
    private static let activeUUID          = "000000b0-0000-1000-8000-0026bb765291"
    private static let brightnessUUID      = "00000008-0000-1000-8000-0026bb765291"
    private static let targetTempUUID      = "00000035-0000-1000-8000-0026bb765291"
    private static let currentTempUUID     = "00000011-0000-1000-8000-0026bb765291"
    private static let targetPositionUUID  = "0000007c-0000-1000-8000-0026bb765291"
    private static let humidityUUID        = "00000010-0000-1000-8000-0026bb765291"
    private static let lockTargetUUID      = "0000001e-0000-1000-8000-0026bb765291"
    private static let heatingCoolingUUID  = "00000033-0000-1000-8000-0026bb765291"
    private static let hueUUID             = "00000013-0000-1000-8000-0026bb765291"
    private static let saturationUUID      = "0000002f-0000-1000-8000-0026bb765291"
    private static let colorTempUUID       = "000000ce-0000-1000-8000-0026bb765291"

    private static func normalizedType(_ characteristic: HMCharacteristic) -> String {
        characteristic.characteristicType.lowercased()
    }

    private static func humanReadableName(for characteristic: HMCharacteristic) -> String {
        switch normalizedType(characteristic) {
        case onUUID:             return String(localized: "char.name.power",       defaultValue: "Power")
        case activeUUID:         return String(localized: "char.name.active",      defaultValue: "Active")
        case brightnessUUID:     return String(localized: "char.name.brightness",  defaultValue: "Brightness")
        case targetTempUUID:     return String(localized: "char.name.targetTemp",  defaultValue: "Temperature")
        case currentTempUUID:    return String(localized: "char.name.currentTemp", defaultValue: "Current Temperature")
        case targetPositionUUID: return String(localized: "char.name.position",    defaultValue: "Position")
        case humidityUUID:       return String(localized: "char.name.humidity",    defaultValue: "Humidity")
        case lockTargetUUID:     return String(localized: "char.name.lock",        defaultValue: "Lock")
        case heatingCoolingUUID: return String(localized: "char.name.mode",        defaultValue: "Mode")
        case hueUUID:            return String(localized: "char.name.hue",         defaultValue: "Hue")
        case saturationUUID:     return String(localized: "char.name.saturation",  defaultValue: "Saturation")
        case colorTempUUID:      return String(localized: "char.name.colorTemp",   defaultValue: "Color Temperature")
        default:
            return characteristic.localizedDescription
        }
    }

    private static func humanReadableValue(for characteristic: HMCharacteristic, value: Any?) -> String {
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

        switch normalizedType(characteristic) {
        case onUUID, activeUUID:
            return intVal(value) == 1
                ? String(localized: "accessory.state.on",  defaultValue: "On")
                : String(localized: "accessory.state.off", defaultValue: "Off")
        case brightnessUUID:
            if let v = intVal(value) { return "\(v)%" }
        case targetTempUUID, currentTempUUID:
            if let v = doubleVal(value) { return String(format: "%.1f°C", v) }
        case humidityUUID:
            if let v = doubleVal(value) { return String(format: "%.0f%%", v) }
        case targetPositionUUID:
            if let v = intVal(value) {
                let logicalPosition = characteristic.service?.accessory.map {
                    WindowCoveringPositionMapper.logicalPosition(
                        fromRaw: v,
                        accessoryID: $0.uniqueIdentifier
                    )
                } ?? v
                return logicalPosition == 0
                    ? String(localized: "accessory.position.closed", defaultValue: "Closed")
                    : (logicalPosition == 100 ? String(localized: "accessory.position.open", defaultValue: "Open") : "\(logicalPosition)%")
            }
        case lockTargetUUID:
            return intVal(value) == 1
                ? String(localized: "accessory.position.closed", defaultValue: "Closed")
                : String(localized: "accessory.position.open",   defaultValue: "Open")
        case hueUUID:
            if let v = doubleVal(value) { return "\(Int(v))°" }
        case saturationUUID:
            if let v = doubleVal(value) { return "\(Int(v))%" }
        default:
            break
        }

        // Fallback generico
        if let i = intVal(value) { return "\(i)" }
        if let d = doubleVal(value) { return String(format: "%.1f", d) }
        return value.map { "\($0)" } ?? "—"
    }
}
