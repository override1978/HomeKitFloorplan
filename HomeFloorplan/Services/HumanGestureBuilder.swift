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

    /// Il nome della scena riconosciuta, quando il gesto è l'esecuzione di una.
    ///
    /// Cambia tutto ciò che il pannello dice e offre: una scena ha già un
    /// nome, si riesegue in un colpo solo, e non ha senso salvarla come
    /// scena una seconda volta.
    var sceneName: String?
    var sceneID: UUID?
    var isScene: Bool { sceneID != nil }

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
        if let sceneName { return sceneName }
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

    /// L'unica origine che vale come gesto, dichiarata in positivo.
    ///
    /// Era una lista nera — «tutto tranne `app`» — e non filtrava niente: il
    /// valore `app` non viene scritto da nessuna parte. Il percorso di
    /// scrittura passa `user` o `engine` verbatim, il delegate scrive
    /// `external`, e il commento del modello che parlava di `app` era rimasto
    /// indietro. Risultato: ogni valutazione di SmartLighting e ogni tap dentro
    /// l'app comparivano nella corsia come se fossero stati una mano.
    ///
    /// In positivo questo non può ricapitare: il giorno che nasce una quarta
    /// origine, resta fuori finché qualcuno non decide che è un gesto — che è
    /// il verso giusto in cui sbagliare.
    static let humanOrigin = "external"

    /// Oltre quanti comandi insieme si smette di credere alla mano.
    static let simultaneityThreshold = 6

    /// Entro quanto quei comandi devono cadere perché sia una raffica.
    ///
    /// Il criterio non è *quanti* ma *quanto in fretta*: «esco di casa e spengo
    /// quindici cose» è un gesto vero, e anzi il più interessante della
    /// giornata — ma dura un minuto, perché una mano cammina. Quarantasette
    /// accessori in dieci stanze nello stesso istante sono una scena, un
    /// automatismo o una riconsegna di massa dopo una riconnessione: qualunque
    /// cosa siano, non sono qualcuno che gira per casa.
    ///
    /// Resta fuori anche il caso ambiguo: una persona che tocca una scena
    /// nell'app Casa *ha* un'intenzione umana, ma il modo giusto di mostrarla è
    /// col nome della scena, non come una lista di quarantasette comandi.
    /// Finché non sappiamo riconoscerla, tacere è più onesto che sbagliare
    /// nome.
    static let simultaneityWindow: TimeInterval = 5

    /// Quanto ci vuole, come minimo, per passare da una stanza all'altra.
    ///
    /// Era un tetto sul numero di stanze, e sbagliava: i gesti si concatenano —
    /// la finestra di tre minuti vale fra comandi *consecutivi* — quindi un
    /// giro serale per casa, una stanza ogni due minuti, diventa un gesto solo
    /// da otto stanze. È il gesto più reale che ci sia, e un tetto sul
    /// conteggio lo buttava via insieme alle raffiche.
    ///
    /// Il vincolo giusto è lo stesso della simultaneità, applicato alle stanze
    /// invece che agli accessori: non *quante*, ma *quanto in fretta*. Dieci
    /// secondi a stanza è una camminata svelta in un appartamento — esci di
    /// casa toccando quattro stanze in un minuto e passi — ma rende
    /// impossibili le dieci stanze in due secondi, che è ciò che si voleva
    /// escludere.
    static let minimumRoomTransition: TimeInterval = 10

    /// Quante stanze può toccare un gesto senza che qualcuno abbia camminato.
    ///
    /// Un interruttore di gruppo accende la Scala e l'Entrata insieme, e le due
    /// luci stanno in due stanze HomeKit diverse: pretendere il tempo di
    /// percorrenza lì significherebbe negare un gesto che è avvenuto davvero,
    /// con un solo dito. Fino a tre stanze quindi non si chiede niente; di là
    /// «stanze» comincia a voler dire «percorso», e un percorso ha bisogno di
    /// tempo.
    static let roomsWithoutWalking = 3

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

    /// Una scena ridotta a ciò che serve per riconoscerla: quali accessori tocca.
    struct SceneSignature: Equatable, Sendable {
        let id: UUID
        let name: String
        let accessoryUUIDs: Set<UUID>
    }

    /// Quanta parte di una raffica deve appartenere a una scena perché sia lei.
    ///
    /// Non il contrario — non si chiede che la raffica copra la scena — perché
    /// una scena che imposta quaranta accessori ne muove solo quelli che non
    /// erano già nello stato giusto: la sera in cui metà casa è già spenta,
    /// «Buonanotte» produce venti eventi, non quaranta. Pretendere la
    /// copertura la renderebbe irriconoscibile proprio nei casi normali.
    static let sceneMatchRatio = 0.8

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
                      scenes: [SceneSignature] = [],
                      now: Date = Date()) -> [HumanGesture] {
        let fires = scheduledFires.sorted()

        let candidates = raw
            .filter { commandTypes.contains($0.eventType) }
            // Le scritture di app e motori non sono gesti: sono la casa che
            // agisce, ed è già raccontata sopra l'asse.
            .filter { $0.origin == humanOrigin }
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

        // Prima si prova a dare un nome, poi si scarta ciò che è rimasto senza.
        // L'ordine è tutto: una scena riconosciuta è informazione buona proprio
        // perché muove molte cose insieme, e la regola di plausibilità —
        // scritta per togliere di mezzo le raffiche anonime — la butterebbe via
        // per la stessa ragione per cui è interessante.
        return gestures
            .map { attribute($0, to: scenes) }
            .filter { $0.isScene || isPlausiblyHuman($0) }
    }

    /// Riconosce l'esecuzione di una scena dentro una raffica di comandi.
    ///
    /// Fra più scene compatibili vince la più piccola: una «Spegni tutto» da
    /// quaranta accessori contiene quasi ogni altra scena della casa, e senza
    /// questa regola si prenderebbe il merito di tutte.
    nonisolated static func attribute(_ gesture: HumanGesture,
                                      to scenes: [SceneSignature]) -> HumanGesture {
        guard gesture.changes.count > simultaneityThreshold, !scenes.isEmpty else { return gesture }
        let touched = Set(gesture.changes.map(\.accessoryUUID))
        guard !touched.isEmpty else { return gesture }

        let match = scenes
            .filter { scene in
                let shared = touched.intersection(scene.accessoryUUIDs).count
                return Double(shared) / Double(touched.count) >= sceneMatchRatio
            }
            .min { $0.accessoryUUIDs.count < $1.accessoryUUIDs.count }

        guard let match else { return gesture }
        var named = gesture
        named.sceneName = match.name
        named.sceneID = match.id
        return named
    }

    /// Vero quando un gruppo può davvero essere stato fatto da qualcuno.
    ///
    /// Ultima rete, dopo tutte le attribuzioni: quelle guardano *da dove*
    /// arriva un comando, questa guarda *come si muove* il gruppo. Serve
    /// perché HomeKit marca «external» anche ciò che external non è in senso
    /// utile — le proprie scene, le riconsegne dopo una riconnessione — e
    /// nessuna di quelle porta un'etichetta che lo dica.
    nonisolated static func isPlausiblyHuman(_ gesture: HumanGesture) -> Bool {
        guard let first = gesture.changes.first?.at,
              let last = gesture.changes.last?.at else { return true }
        let span = last.timeIntervalSince(first)

        // Un percorso ha bisogno di tempo per essere percorso.
        let rooms = gesture.roomNames.count
        if rooms > roomsWithoutWalking {
            let transitions = Double(rooms - 1)
            if span < transitions * minimumRoomTransition { return false }
        }

        guard gesture.changes.count > simultaneityThreshold else { return true }
        return span >= simultaneityWindow
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
        var merged = HumanGesture(id: first.id,
                                  at: first.at,
                                  changes: latest.values.sorted { $0.at < $1.at })
        // Il nome di una scena sopravvive alla fusione visiva: se uno dei
        // rombi sovrapposti era «Buonanotte», dirlo resta meglio che tornare a
        // «quarantasette comandi».
        if let named = gestures.first(where: { $0.isScene }) {
            merged.sceneName = named.sceneName
            merged.sceneID = named.sceneID
        }
        return merged
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
