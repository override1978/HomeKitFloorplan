import Foundation

// MARK: - HumanGesture

/// Un gesto: ciò che una persona ha fatto in casa, in un colpo solo.
///
/// Sul nastro, sopra l'asse c'è quello che fa la casa e sotto quello che fanno
/// le persone. È l'unico criterio di selezione che regge il volume: con 135
/// accessori una giornata produce centinaia di transizioni, e disegnarle tutte
/// trasformerebbe l'asse in un istogramma illeggibile. I gesti umani invece
/// sono qualche decina, e sono gli unici su cui si possa *fare* qualcosa —
/// salvarli come scena, ripeterli, trasformarli in abitudine.
struct HumanGesture: Identifiable, Equatable, Sendable {

    /// Un singolo comando dentro il gesto.
    struct Change: Identifiable, Equatable, Sendable {
        let id: String
        let accessoryUUID: UUID
        let accessoryName: String
        let roomName: String?
        let state: Bool
        let brightness: Double?
        let eventType: String
        let at: Date
    }

    let id: String
    /// L'istante del primo comando: il gesto comincia lì.
    let at: Date
    let changes: [Change]

    /// Le stanze toccate, senza ripetizioni e in ordine di apparizione.
    var roomNames: [String] {
        var seen: Set<String> = []
        return changes.compactMap(\.roomName).filter { seen.insert($0).inserted }
    }

    /// Vero quando il gesto ha acceso più cose di quante ne abbia spente:
    /// serve a scegliere il verbo giusto senza dover leggere la lista.
    var isMostlyOn: Bool {
        changes.filter(\.state).count > changes.count / 2
    }

    /// Come si chiama un gesto quando lo si guarda da lontano.
    ///
    /// Un gesto non ha un nome: ha una lista di comandi. Ma sul nastro e in
    /// testa al pannello serve una riga sola, e la cosa che distingue due gesti
    /// della stessa giornata è quasi sempre **dove** sono successi.
    var shortTitle: String {
        let rooms = roomNames
        switch rooms.count {
        case 0:  return changes.first?.accessoryName ?? String(localized: "gesture.untitled", defaultValue: "Comandi")
        case 1:  return rooms[0]
        case 2:  return "\(rooms[0]), \(rooms[1])"
        default: return String(format: String(localized: "gesture.rooms.more",
                                              defaultValue: "%@ e altre %d stanze"),
                               rooms[0], rooms.count - 1)
        }
    }
}

// MARK: - HumanGestureBuilder

/// Riconosce i gesti umani dentro il flusso grezzo degli eventi.
///
/// Puro e senza SwiftData di proposito: le regole di attribuzione sono la parte
/// che può sbagliare, e vanno provate senza una casa vera.
enum HumanGestureBuilder {

    /// Entro quanto due comandi appartengono allo stesso gesto.
    ///
    /// Chi accende tre luci in dieci secondi ha fatto *una* cosa, non tre.
    /// Tre minuti coprono anche chi si sposta fra stanze mentre sistema.
    static let clusterWindow: TimeInterval = 3 * 60

    /// Quanto vicino a uno scatto programmato un cambiamento si considera suo.
    ///
    /// È la difesa contro l'ambiguità dell'origine: HomeKit marca «external»
    /// sia la mano di una persona sia le proprie automazioni, quindi un
    /// cambiamento che cade a ridosso di uno scatto previsto è quasi certamente
    /// l'automazione, non qualcuno. Quasi: resta un'euristica, e va detta come
    /// tale invece di spacciarla per attribuzione certa.
    static let automationTolerance: TimeInterval = 60

    /// I tipi che sono **comandi**, non osservazioni.
    ///
    /// Una finestra che si apre e un movimento rilevato sono fatti della casa,
    /// non azioni su cui si possa offrire «salva come scena»: nessuno può
    /// richiamare un sensore di movimento. Restano fuori.
    static let commandTypes: Set<String> = [
        AccessoryEventType.light.rawValue,
        AccessoryEventType.outlet.rawValue,
        AccessoryEventType.switch.rawValue,
        AccessoryEventType.blind.rawValue,
        AccessoryEventType.fan.rawValue,
        AccessoryEventType.airPurifier.rawValue,
        AccessoryEventType.humidifier.rawValue,
        AccessoryEventType.thermostat.rawValue
    ]

    /// Un evento grezzo, ridotto a ciò che serve per attribuirlo.
    struct RawChange: Equatable, Sendable {
        let accessoryUUID: UUID
        let accessoryName: String
        let roomName: String?
        let state: Bool
        let brightness: Double?
        let eventType: String
        let at: Date
        /// Origine dichiarata dall'evento: «app» per le scritture nostre e dei
        /// motori interni, «external» per tutto il resto.
        let origin: String
    }

    /// Raggruppa in gesti ciò che resta dopo aver tolto quel che non è umano.
    ///
    /// - Parameters:
    ///   - scheduledFires: gli scatti programmati della giornata, per scartare
    ///     i cambiamenti che sono quasi certamente loro.
    static func build(from raw: [RawChange],
                      scheduledFires: [Date] = [],
                      now: Date = Date()) -> [HumanGesture] {
        let fires = scheduledFires.sorted()

        let candidates = raw
            .filter { commandTypes.contains($0.eventType) }
            // Le scritture di app e motori non sono gesti: sono la casa che
            // agisce, ed è già raccontata sopra l'asse.
            .filter { $0.origin != "app" }
            .filter { !isNearAnyFire($0.at, fires: fires) }
            .sorted { $0.at < $1.at }

        guard !candidates.isEmpty else { return [] }

        var gestures: [HumanGesture] = []
        var current: [RawChange] = []

        for change in candidates {
            if let last = current.last, change.at.timeIntervalSince(last.at) > clusterWindow {
                gestures.append(makeGesture(from: current))
                current = []
            }
            current.append(change)
        }
        if !current.isEmpty { gestures.append(makeGesture(from: current)) }
        return gestures
    }

    /// Fonde più gesti in uno solo.
    ///
    /// Serve al nastro, non alle regole: la finestra di raggruppamento è di
    /// tre minuti, ma su ventiquattr'ore compresse in ottocento punti tre
    /// minuti sono meno di due punti. Due rombi che si sovrappongono sono già
    /// una cosa sola per l'occhio, e devono esserlo anche per il dito —
    /// altrimenti si tocca quello sotto e si apre quello sopra.
    static func merge(_ gestures: [HumanGesture]) -> HumanGesture {
        guard gestures.count > 1, let first = gestures.min(by: { $0.at < $1.at }) else {
            return gestures.first ?? HumanGesture(id: "gesture@empty", at: Date(), changes: [])
        }
        var latest: [UUID: HumanGesture.Change] = [:]
        for change in gestures.flatMap(\.changes).sorted(by: { $0.at < $1.at }) {
            latest[change.accessoryUUID] = change
        }
        return HumanGesture(id: first.id,
                            at: first.at,
                            changes: latest.values.sorted { $0.at < $1.at })
    }

    /// Il nome da proporre quando un gesto diventa una scena.
    ///
    /// Proporre un nome e non chiederlo a freddo: un campo vuoto davanti a
    /// «come la chiami?» è il punto in cui si abbandona. «Sera in Soggiorno» è
    /// già giusto abbastanza da premere Salva senza pensarci, e resta
    /// modificabile per chi vuole.
    static func suggestedName(for gesture: HumanGesture,
                              calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: gesture.at)
        let moment: String
        switch hour {
        case 5...11:  moment = String(localized: "gesture.part.morning",   defaultValue: "Mattina")
        case 12...17: moment = String(localized: "gesture.part.afternoon", defaultValue: "Pomeriggio")
        case 18...22: moment = String(localized: "gesture.part.evening",   defaultValue: "Sera")
        default:      moment = String(localized: "gesture.part.night",     defaultValue: "Notte")
        }
        guard let room = gesture.roomNames.first else { return moment }
        return String(format: String(localized: "gesture.suggestedName",
                                     defaultValue: "%@ in %@"), moment, room)
    }

    // MARK: - Private

    private static func isNearAnyFire(_ instant: Date, fires: [Date]) -> Bool {
        fires.contains { abs($0.timeIntervalSince(instant)) <= automationTolerance }
    }

    private static func makeGesture(from raw: [RawChange]) -> HumanGesture {
        // Un accessorio toccato più volte dentro lo stesso gesto conta una
        // volta sola, con l'ultimo stato: chi accende e spegne per sbaglio non
        // ha fatto due cose, ne ha fatta una e l'ha corretta.
        var latest: [UUID: RawChange] = [:]
        for change in raw { latest[change.accessoryUUID] = change }

        let changes = latest.values
            .sorted { $0.at < $1.at }
            .map { change in
                HumanGesture.Change(
                    id: "\(change.accessoryUUID)@\(Int(change.at.timeIntervalSinceReferenceDate))",
                    accessoryUUID: change.accessoryUUID,
                    accessoryName: change.accessoryName,
                    roomName: change.roomName,
                    state: change.state,
                    brightness: change.brightness,
                    eventType: change.eventType,
                    at: change.at)
            }

        let start = raw.first?.at ?? Date()
        return HumanGesture(id: "gesture@\(Int(start.timeIntervalSinceReferenceDate))",
                            at: start,
                            changes: changes)
    }
}
