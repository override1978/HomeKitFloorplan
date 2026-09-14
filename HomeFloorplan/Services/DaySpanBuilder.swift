import Foundation

// MARK: - DaySpan

/// Qualcosa che è **durato**, non qualcosa che è successo.
///
/// Il nastro sapeva dire solo istanti, e metà di ciò che accade in casa ha una
/// durata: il purificatore acceso fino alle undici, l'aspirapolvere per
/// quarantacinque minuti, la ventola tutta la notte. Con i soli punti quelle
/// cose diventano due pallini scollegati, e la domanda che uno si fa davanti al
/// nastro — «adesso sta girando qualcosa?» — non ha risposta.
///
/// Il dato c'era già: un evento «acceso» seguito da uno «spento» **è** una
/// durata. Non serviva raccogliere niente di nuovo, solo guardare le coppie
/// invece dei singoli.
struct DaySpan: Identifiable, Equatable, Sendable {
    let id: String
    let accessoryUUID: UUID
    let name: String
    let roomName: String?
    let eventType: String
    let start: Date
    /// `nil` quando sta ancora girando.
    let end: Date?
    /// Vero quando il periodo era già cominciato prima della finestra: il
    /// bordo sinistro non è un inizio ma il limite di ciò che sappiamo.
    let startsBeforeWindow: Bool

    func duration(now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }

    var isRunning: Bool { end == nil }
}

// MARK: - DaySpanBuilder

enum DaySpanBuilder {

    /// Sotto questa durata un periodo è un istante travestito.
    ///
    /// Una barra lunga due pixel non dice «è durato poco»: dice «qui c'è
    /// qualcosa di illeggibile». Sotto i cinque minuti resta il punto, che quel
    /// mestiere lo fa meglio.
    static let minimumSpan: TimeInterval = 5 * 60

    /// I tipi per cui «per quanto» è la cosa interessante.
    ///
    /// Barre per i **processi**, non per gli stati. Un processo finisce da
    /// solo — l'aspirapolvere, il purificatore, la ventola, l'umidificatore —
    /// e sapere quanto manca alla fine è un'informazione. Uno stato finisce
    /// quando qualcuno lo finisce, e una luce accesa per tre ore non racconta
    /// niente che il colore della stanza non dica già.
    ///
    /// È la stessa disciplina dei marker sulla planimetria — solo dove c'è una
    /// domanda vera — applicata all'asse del tempo. Ed è anche ciò che tiene
    /// il nastro leggibile: con trentasette accessori, «una barra per ogni cosa
    /// accesa» sarebbe un istogramma.
    static let processTypes: Set<String> = [
        AccessoryEventType.airPurifier.rawValue,
        AccessoryEventType.fan.rawValue,
        AccessoryEventType.humidifier.rawValue,
        AccessoryEventType.outlet.rawValue,
        AccessoryEventType.switch.rawValue
    ]

    /// Ricostruisce i periodi accesi dentro una finestra.
    ///
    /// - Parameters:
    ///   - raw: gli eventi della finestra, in qualunque ordine.
    ///   - window: il giorno mostrato. I periodi si tagliano ai suoi bordi.
    ///   - now: serve a distinguere «sta ancora girando» da «non sappiamo
    ///     quando è finito», che su un giorno passato sono cose diverse.
    static func build(from raw: [HumanGestureBuilder.RawChange],
                      window: DateInterval,
                      now: Date = Date()) -> [DaySpan] {
        var byAccessory: [UUID: [HumanGestureBuilder.RawChange]] = [:]
        for change in raw where processTypes.contains(change.eventType) {
            byAccessory[change.accessoryUUID, default: []].append(change)
        }

        var spans: [DaySpan] = []
        for (uuid, changes) in byAccessory {
            let ordered = changes.sorted { $0.at < $1.at }
            var openedAt: Date?
            var openedBeforeWindow = false

            // Se il primo evento della finestra è uno spegnimento, la cosa era
            // già accesa quando la finestra è cominciata: il periodo esiste, e
            // comincia al bordo. Ignorarlo perderebbe proprio i periodi lunghi,
            // che sono quelli che vale di più mostrare.
            if ordered.first?.state == false {
                openedAt = window.start
                openedBeforeWindow = true
            }

            for change in ordered {
                if change.state {
                    if openedAt == nil {
                        openedAt = change.at
                        openedBeforeWindow = false
                    }
                } else if let start = openedAt {
                    spans.append(contentsOf: make(uuid: uuid, sample: change,
                                                  start: start, end: change.at,
                                                  before: openedBeforeWindow))
                    openedAt = nil
                    openedBeforeWindow = false
                }
            }

            if let start = openedAt, let sample = ordered.last {
                // Aperto alla fine della finestra. Se la finestra contiene
                // adesso sta ancora girando; se è un giorno passato non lo
                // sappiamo, e si chiude al bordo invece di fingere che duri
                // ancora.
                let stillRunning = window.contains(now)
                spans.append(contentsOf: make(uuid: uuid, sample: sample,
                                              start: start,
                                              end: stillRunning ? nil : window.end,
                                              before: openedBeforeWindow))
            }
        }

        return spans.sorted(by: precedes)
    }

    /// Un ordinamento **totale**, non solo per inizio.
    ///
    /// Ordinare per il solo `start` lascia indecisi i pari merito, e i pari
    /// merito qui sono la norma: ogni cosa già accesa a inizio giornata parte
    /// dal bordo della finestra, quindi tre o quattro periodi condividono
    /// esattamente lo stesso istante. `sort` in Swift non è stabile, perciò a
    /// ogni ricostruzione quei periodi potevano uscire in ordine diverso — e
    /// con l'ordine cambiava la corsia. Da fuori si vedevano barre del passato
    /// che si spostavano da sole, una volta al minuto, senza che fosse
    /// cambiato niente.
    ///
    /// I criteri di spareggio finiscono sull'`id`, che è unico: così l'ordine
    /// esiste sempre ed è sempre lo stesso. È lo stesso difetto che faceva
    /// rimescolare le icone dei sensori, e vale la stessa lezione — dove c'è un
    /// ordinamento parziale, prima o poi si vede qualcosa muoversi.
    nonisolated static func precedes(_ a: DaySpan, _ b: DaySpan) -> Bool {
        if a.start != b.start { return a.start < b.start }
        let endA = a.end ?? Date.distantFuture
        let endB = b.end ?? Date.distantFuture
        if endA != endB { return endA < endB }
        return a.id < b.id
    }

    // MARK: - Private

    private static func make(uuid: UUID,
                             sample: HumanGestureBuilder.RawChange,
                             start: Date,
                             end: Date?,
                             before: Bool) -> [DaySpan] {
        if let end, end.timeIntervalSince(start) < minimumSpan { return [] }
        return [DaySpan(id: "\(uuid)@\(Int(start.timeIntervalSinceReferenceDate))",
                        accessoryUUID: uuid,
                        name: sample.accessoryName,
                        roomName: sample.roomName,
                        eventType: sample.eventType,
                        start: start,
                        end: end,
                        startsBeforeWindow: before)]
    }
}
