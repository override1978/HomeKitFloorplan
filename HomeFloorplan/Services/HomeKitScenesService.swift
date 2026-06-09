import Foundation
import HomeKit
import Observation

/// Wrapper di lettura per le scene HomeKit (`HMActionSet`).
/// Separato da HomeKitService per non sovraccaricarlo: scope ridotto a scene.
/// Aggiornamento delle scene tracciato via @Observable.
@MainActor
@Observable
final class HomeKitScenesService {
    var scenes: [SceneItem] = []
    var lastRunError: Error?
    
    private let homeKit: HomeKitService

    /// Logger attività. Iniettato dall'app dopo l'init.
    var activityLogger: ActivityLoggerService?

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }
    
    /// Carica/ricarica la lista delle scene dalla home corrente.
    func refresh() {
        guard let home = homeKit.currentHome else {
            scenes = []
            return
        }
        scenes = home.actionSets
            .map { SceneItem(actionSet: $0) }
            .sorted { $0.displayPriority < $1.displayPriority ||
                     ($0.displayPriority == $1.displayPriority &&
                      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }
    }
    
    /// Scene divise per tipo (built-in vs custom) per il pannello.
    var builtInScenes: [SceneItem] {
        scenes.filter { $0.isBuiltIn }
    }
    
    var customScenes: [SceneItem] {
        scenes.filter { !$0.isBuiltIn }
    }
    
    /// Tutte le stanze coinvolte in almeno una scena, ordinate alfabeticamente.
    /// Usato per popolare le pillole di filtro.
    var representedRooms: [(id: UUID, name: String)] {
        guard let home = homeKit.currentHome else { return [] }
        
        var roomIDs: Set<UUID> = []
        for scene in scenes {
            roomIDs.formUnion(scene.affiliatedRoomIDs)
        }
        
        let rooms = home.rooms.filter { roomIDs.contains($0.uniqueIdentifier) }
        return rooms
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (id: $0.uniqueIdentifier, name: $0.name) }
    }
    
    func run(_ scene: SceneItem) async throws {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitScenesService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(scene.actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Log esecuzione scena
        activityLogger?.logSceneExecution(sceneName: scene.name, actionCount: scene.actionCount)
    }
}

/// Modello UI per una scena HomeKit.
struct SceneItem: Identifiable {
    let actionSet: HMActionSet
    
    var id: UUID { actionSet.uniqueIdentifier }
    var name: String { actionSet.name }
    var isBuiltIn: Bool { actionSet.actionSetType != HMActionSetTypeUserDefined }
    
    /// Numero di azioni dentro la scena (per badge informativi).
    var actionCount: Int { actionSet.actions.count }
    
    /// SF Symbol per la scena. Per scene built-in usa il simbolo del tipo;
    /// per scene custom usa l'inferenza dal nome.
    var symbolName: String {
        switch actionSet.actionSetType {
        case HMActionSetTypeHomeArrival:    return "house.fill"
        case HMActionSetTypeHomeDeparture:  return "figure.walk.departure"
        case HMActionSetTypeSleep:          return "bed.double.fill"
        case HMActionSetTypeWakeUp:         return "sunrise.fill"
        default:                            return Self.inferIcon(from: name)
        }
    }

    /// Inferenza icona dal nome della scena. Riconosce keyword IT+EN comuni.
    static func inferIcon(from name: String) -> String {
        let n = name.lowercased()
        
        // Categoria sicurezza/casa
        if n.contains("allarme") || n.contains("alarm") { return "exclamationmark.shield.fill" }
        if n.contains("sicurezza") || n.contains("security") { return "shield.fill" }
        if n.contains("benvenuto") || n.contains("welcome") || n.contains("arrivo") || n.contains("arrival") {
            return "house.fill"
        }
        if n.contains("uscita") || n.contains("leave") || n.contains("departure") || n.contains("away") {
            return "figure.walk.departure"
        }
        
        // Categoria notte/giorno
        if n.contains("notte") || n.contains("night") || n.contains("dormi") || n.contains("sleep") || n.contains("buonanotte") {
            return "moon.fill"
        }
        if n.contains("buongiorno") || n.contains("morning") || n.contains("sveglia") || n.contains("wake") {
            return "sunrise.fill"
        }
        if n.contains("alba") { return "sunrise.fill" }
        if n.contains("tramonto") || n.contains("sunset") { return "sunset.fill" }
        
        // Attività
        if n.contains("cinema") || n.contains("film") || n.contains("movie") || n.contains("tv") {
            return "tv.fill"
        }
        if n.contains("cena") || n.contains("dinner") || n.contains("pranzo") || n.contains("lunch") || n.contains("cuc") {
            return "fork.knife"
        }
        if n.contains("relax") || n.contains("rilass") { return "leaf.fill" }
        if n.contains("lavor") || n.contains("studi") || n.contains("work") || n.contains("study") {
            return "laptopcomputer"
        }
        if n.contains("lettura") || n.contains("read") { return "book.fill" }
        if n.contains("party") || n.contains("festa") { return "party.popper.fill" }
        if n.contains("musica") || n.contains("music") { return "music.note" }
        if n.contains("yoga") || n.contains("meditazione") || n.contains("medita") { return "figure.mind.and.body" }
        if n.contains("doccia") || n.contains("bagno") || n.contains("shower") { return "shower.fill" }
        
        // Climatizzazione
        if n.contains("caldo") || n.contains("riscalda") || n.contains("heat") { return "flame.fill" }
        if n.contains("fresco") || n.contains("freddo") || n.contains("cool") { return "snowflake" }
        if n.contains("aria") || n.contains("air") { return "wind" }
        
        // Default scena custom
        return "wand.and.sparkles"
    }
    
    /// Priorità di ordinamento: built-in prima (in ordine tematico),
    /// poi custom in ordine alfabetico.
    var displayPriority: Int {
        switch actionSet.actionSetType {
        case HMActionSetTypeWakeUp:         return 0
        case HMActionSetTypeHomeArrival:    return 1
        case HMActionSetTypeHomeDeparture:  return 2
        case HMActionSetTypeSleep:          return 3
        default:                            return 99
        }
    }
    
    /// UUID delle stanze i cui accessori sono target di almeno una azione della scena.
    /// Una scena "Buonanotte" che spegne luci in Living + Camera ritorna entrambi gli UUID.
    var affiliatedRoomIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for action in actionSet.actions {
            // HMCharacteristicWriteAction è generica → usa KVC per accedere alla characteristic
            // (HMAction eredita da NSObject quindi value(forKey:) è disponibile)
            if let characteristic = action.value(forKey: "characteristic") as? HMCharacteristic,
               let room = characteristic.service?.accessory?.room {
                ids.insert(room.uniqueIdentifier)
            }
        }
        return ids
    }
    
    /// Riepilogo leggibile delle azioni di una scena, raggruppate per accessorio.
    /// Più HMCharacteristicWriteAction sullo stesso accessorio vengono combinate
    /// in un'unica entry con descrizione concatenata.
    @MainActor
    var actionSummaries: [SceneActionSummary] {
        // Step 1: raccogli (accessory, characteristic, value) per ogni write action
        var rawActions: [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any?)] = []
        
        for action in actionSet.actions {
            guard let characteristic = action.value(forKey: "characteristic") as? HMCharacteristic,
                  let accessory = characteristic.service?.accessory else { continue }
            let targetValue = action.value(forKey: "targetValue")
            rawActions.append((accessory, characteristic, targetValue))
        }
        
        // Step 2: raggruppa per accessorio
        let grouped = Dictionary(grouping: rawActions, by: { $0.accessory.uniqueIdentifier })
        
        // Step 3: costruisci SceneActionSummary per ogni accessorio
        let summaries = grouped.compactMap { (uuid, items) -> SceneActionSummary? in
            guard let first = items.first else { return nil }
            let accessory = first.accessory
            let description = SceneActionSummary.describe(
                characteristics: items.map { (ch: $0.characteristic, value: $0.value) }
            )
            return SceneActionSummary(
                accessoryID: uuid,
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "scene.action.noRoom", defaultValue: "No Room"),
                roomID: accessory.room?.uniqueIdentifier ?? UUID(),
                description: description
            )
        }
        
        return summaries.sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }
}

/// Riepilogo di una singola azione (o gruppo di azioni sullo stesso accessorio)
/// dentro una scena. Pensato per la visualizzazione read-only.
struct SceneActionSummary: Identifiable {
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String
    let roomID: UUID
    let description: String
    
    var id: UUID { accessoryID }
    
    /// Converte un set di (characteristic, value) per uno STESSO accessorio
    /// in una stringa human-readable concatenata.
    static func describe(characteristics: [(ch: HMCharacteristic, value: Any?)]) -> String {
        var parts: [String] = []
        
        // UUID HAP comuni
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let onUUID = "00000025-0000-1000-8000-0026BB765291"
        let brightnessUUID = "00000008-0000-1000-8000-0026BB765291"
        let targetPositionUUID = "0000007C-0000-1000-8000-0026BB765291"
        let targetTempUUID = "00000035-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let targetHeaterCoolerStateUUID = "000000B2-0000-1000-8000-0026BB765291"
        let lockTargetStateUUID = "0000001E-0000-1000-8000-0026BB765291"
        let targetDoorStateUUID = "00000032-0000-1000-8000-0026BB765291"
        let securityTargetStateUUID = "00000067-0000-1000-8000-0026BB765291"
        let targetAirPurifierStateUUID = "000000A8-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"
        let hueUUID = "00000013-0000-1000-8000-0026BB765291"
        let saturationUUID = "0000002F-0000-1000-8000-0026BB765291"
        
        // Helper per estrarre int/double
        func intVal(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let u = any as? UInt8 { return Int(u) }
            if let n = any as? NSNumber { return n.intValue }
            return nil
        }
        func doubleVal(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let f = any as? Float { return Double(f) }
            if let i = any as? Int { return Double(i) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }
        
        for (ch, value) in characteristics {
            switch ch.characteristicType {
            case onUUID, activeUUID:
                if intVal(value) == 1 {
                    parts.append(String(localized: "accessory.state.on", defaultValue: "On"))
                } else if intVal(value) == 0 {
                    parts.append(String(localized: "accessory.state.off", defaultValue: "Off"))
                }
            case brightnessUUID:
                if let v = intVal(value) { parts.append("\(v)%") }
            case targetPositionUUID:
                if let v = intVal(value) {
                    parts.append(v == 0
                        ? String(localized: "accessory.position.closed", defaultValue: "Closed")
                        : (v == 100 ? String(localized: "accessory.position.open", defaultValue: "Open") : "\(v)%"))
                }
            case targetTempUUID, heatingThresholdUUID, coolingThresholdUUID:
                if let t = doubleVal(value) {
                    parts.append(String(format: "%.1f°", t))
                }
            case targetHeaterCoolerStateUUID:
                switch intVal(value) ?? -1 {
                case 0: parts.append(String(localized: "thermostat.mode.auto", defaultValue: "Auto"))
                case 1: parts.append(String(localized: "thermostat.mode.heat", defaultValue: "Heat"))
                case 2: parts.append(String(localized: "thermostat.mode.cool", defaultValue: "Cool"))
                default: break
                }
            case rotationSpeedUUID:
                if let v = intVal(value) {
                    let fanStr = String(localized: "accessory.fan.speed", defaultValue: "Fan")
                    parts.append("\(fanStr) \(v)%")
                }
            case lockTargetStateUUID:
                if intVal(value) == 1 { parts.append(String(localized: "accessory.lock.lock", defaultValue: "Lock")) }
                else if intVal(value) == 0 { parts.append(String(localized: "accessory.lock.unlock", defaultValue: "Unlock")) }
            case targetDoorStateUUID:
                if intVal(value) == 0 { parts.append(String(localized: "accessory.door.open", defaultValue: "Open")) }
                else if intVal(value) == 1 { parts.append(String(localized: "accessory.door.close", defaultValue: "Close")) }
            case securityTargetStateUUID:
                switch intVal(value) ?? -1 {
                case 0: parts.append(String(localized: "security.mode.home", defaultValue: "Home"))
                case 1: parts.append(String(localized: "security.mode.away", defaultValue: "Away"))
                case 2: parts.append(String(localized: "security.mode.night", defaultValue: "Night"))
                case 3: parts.append(String(localized: "security.mode.disarm", defaultValue: "Disarm"))
                default: break
                }
            case targetAirPurifierStateUUID:
                if intVal(value) == 0 { parts.append(String(localized: "airpurifier.mode.manual", defaultValue: "Manual Mode")) }
                else if intVal(value) == 1 { parts.append(String(localized: "airpurifier.mode.auto", defaultValue: "Auto Mode")) }
            case hueUUID:
                if let v = doubleVal(value) {
                    let hueStr = String(localized: "light.hue", defaultValue: "Hue")
                    parts.append("\(hueStr) \(Int(v))°")
                }
            case saturationUUID:
                if let v = doubleVal(value) {
                    let satStr = String(localized: "light.saturation", defaultValue: "Saturation")
                    parts.append("\(satStr) \(Int(v))%")
                }
            default:
                // Fallback: mostra valore raw
                if let intV = intVal(value) {
                    parts.append("\(intV)")
                } else if let doubleV = doubleVal(value) {
                    parts.append(String(format: "%.1f", doubleV))
                }
            }
        }

        return parts.isEmpty
            ? String(localized: "scene.action.custom", defaultValue: "Custom Action")
            : parts.joined(separator: " • ")
    }
}
