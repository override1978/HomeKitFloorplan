import Foundation
import Observation
import SwiftData

// MARK: - FloorplanDayModel

/// La giornata della casa: cosa è previsto, cosa è successo, cosa sta durando.
///
/// Estratto da `FloorplanEditorView`, che teneva insieme la planimetria, i
/// marker, lo zoom, la rotazione, la chrome **e** la giornata. Quel file era
/// arrivato a 2700 righe, e il costo non era estetico: ogni modifica al nastro
/// passava dallo stesso blocco che disegna la mappa, quindi ogni ritocco
/// grafico poteva rompere qualcosa che non c'entrava — cosa che è puntualmente
/// successa più volte.
///
/// La giornata è la cucitura più netta perché il suo stato non è condiviso con
/// nessun altro: nove proprietà che si muovono insieme, tre costruttori che le
/// riempiono, e niente che riguardi la geometria dello schermo. Qui diventa
/// anche verificabile senza una vista.
@Observable
@MainActor
final class FloorplanDayModel {

    // MARK: Il giorno mostrato

    /// Quanti giorni si è distanti da oggi. Zero è oggi.
    private(set) var offset = 0

    /// Fin dove si può tornare indietro: dove finisce l'archivio.
    ///
    /// Trenta giorni è la soglia di potatura di `AccessoryEvent`. Oltre, la
    /// corsia dei gesti sarebbe vuota e sembrerebbe «non hai fatto niente»
    /// invece di «non lo so più» — che è la differenza fra un'informazione e
    /// una bugia.
    static let maxDaysBack = DLCRetention.accessoryRaw

    /// Fin dove si può andare avanti.
    ///
    /// Sette giorni perché la ricorrenza settimanale è il ciclo più lungo che
    /// le automazioni HomeKit esprimono: l'ottavo non mostrerebbe niente che il
    /// primo non abbia già mostrato.
    static let maxDaysForward = 7

    // MARK: Cosa contiene

    private(set) var moments: [DayMoment] = []
    private(set) var gestures: [HumanGesture] = []
    private(set) var spans: [DaySpan] = []
    private(set) var clock = Date()

    var selectedMoment: DayMoment?
    var selectedGesture: HumanGesture?
    var selectedSpan: DaySpan?
    var selectedRunningSpans: [DaySpan] = []

    /// Se il nastro è a schermo. Lo decide la vista — dipende da modifica,
    /// flusso guidato e dimensione — e qui serve solo a non pagare una query
    /// al minuto per disegnare niente.
    var isEligible = true

    /// Chiamata quando il giorno cambia, per chiudere un dettaglio che non ha
    /// più un oggetto.
    var onDayChanged: (() -> Void)?

    // MARK: Da chi dipende

    private var context: ModelContext?
    private var automations: HomeKitAutomationsService?
    private var calendar: CalendarEventsService?
    private var scenes: HomeKitScenesService?
    private var weather: WeatherKitService?
    private var gestureRefreshTask: Task<Void, Never>?

    func configure(context: ModelContext,
                   automations: HomeKitAutomationsService,
                   calendar: CalendarEventsService,
                   scenes: HomeKitScenesService,
                   weather: WeatherKitService) {
        self.context = context
        self.automations = automations
        self.calendar = calendar
        self.scenes = scenes
        self.weather = weather
    }

    // MARK: La finestra

    var visibleDay: DateInterval { visibleDay(at: clock) }

    /// Esplicito sull'istante da cui contare, perché chi ricostruisce ha già
    /// `now` in mano e non deve dipendere dall'ordine in cui aggiorna lo stato.
    func visibleDay(at instant: Date) -> DateInterval {
        let anchor = Calendar.current.date(byAdding: .day, value: offset, to: instant) ?? instant
        return AutomationsView.dayInterval(containing: anchor)
    }

    var isShowingToday: Bool { offset == 0 }

    var hasContent: Bool { !(moments.isEmpty && gestures.isEmpty && spans.isEmpty) }

    /// Alba e tramonto del giorno visibile, e del successivo.
    ///
    /// Per oggi e domani comanda WeatherKit: tiene conto di rifrazione ed
    /// elevazione meglio di qualunque formula, e su quei due giorni la risposta
    /// ce l'ha già. Per tutti gli altri si calcola. Non è un ripiego uniforme
    /// applicato ovunque per coerenza: è usare il dato migliore dove esiste.
    var solarTimes: NextFireResolver.SolarTimes {
        if isShowingToday, let weather {
            return NextFireResolver.SolarTimes(todaySunrise: weather.todaySunrise,
                                               todaySunset: weather.todaySunset,
                                               tomorrowSunrise: weather.tomorrowSunrise,
                                               tomorrowSunset: weather.tomorrowSunset)
        }
        guard let coordinates = SolarCalculator.homeCoordinates else {
            return NextFireResolver.SolarTimes(todaySunrise: nil, todaySunset: nil,
                                               tomorrowSunrise: nil, tomorrowSunset: nil)
        }
        let day = visibleDay
        let today = SolarCalculator.events(on: day.start, at: coordinates)
        let tomorrow = SolarCalculator.events(on: day.end, at: coordinates)
        return NextFireResolver.SolarTimes(todaySunrise: today.sunrise,
                                           todaySunset: today.sunset,
                                           tomorrowSunrise: tomorrow.sunrise,
                                           tomorrowSunset: tomorrow.sunset)
    }

    /// Sposta la finestra, entro i limiti di ciò che si può dire davvero.
    func shift(by delta: Int) {
        let target = max(-Self.maxDaysBack, min(Self.maxDaysForward, offset + delta))
        guard target != offset else { return }
        offset = target
        clearSelection()
        onDayChanged?()
        refresh()
    }

    func clearSelection() {
        selectedMoment = nil
        selectedGesture = nil
        selectedSpan = nil
        selectedRunningSpans = []
    }

    // MARK: Ricostruzione

    func refresh() {
        guard let automations, let calendar else { return }
        let now = Date()
        clock = now
        let day = visibleDay(at: now)
        if automations.automations.isEmpty { automations.refresh() }
        calendar.refresh(day: day)
        moments = DayTimeline.build(day: day,
                                    now: now,
                                    automations: automations.fires(in: day, now: now,
                                                                   solar: solarTimes),
                                    solar: solarTimes,
                                    calendarEntries: calendar.todayEntries)
        // La corsia si legge solo quando c'è: in modifica e nel flusso guidato
        // il nastro non è a schermo, e una query al minuto per disegnare niente
        // è il genere di costo che non si vede finché non diventa uno scatto
        // mentre si trascina un marker.
        if isEligible {
            gestures = loadGestures(day: day, now: now)
        } else {
            gestures = []
            spans = []
        }
    }

    /// Ricostruisce la sola corsia dei gesti, poco dopo l'ultimo evento.
    ///
    /// Separato da `refresh` perché i momenti costano molto di più —
    /// attraversano ottantasette automazioni ed enumerano le occorrenze di
    /// ciascuna — e non cambiano perché qualcuno ha acceso una luce.
    ///
    /// Il ritardo breve non è pigrizia: accendere i faretti dell'entrata sono
    /// tre eventi in mezzo secondo, e ricostruire tre volte per disegnare lo
    /// stesso rombo è lavoro buttato. Quattro decimi non si percepiscono e
    /// fanno collassare la raffica in un ridisegno solo — che è anche il modo
    /// in cui il gesto si forma davvero: non esiste finché non è finito.
    func scheduleGestureRefresh() {
        // Un evento di adesso non cambia ieri: mentre si guarda un altro
        // giorno il nastro sta fermo, com'è giusto che sia.
        guard isEligible, isShowingToday else { return }
        gestureRefreshTask?.cancel()
        gestureRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            self.gestures = self.loadGestures(day: self.visibleDay, now: now)
        }
    }

    /// I gesti umani del giorno, letti dal registro eventi.
    ///
    /// La finestra è il giorno e non «gli ultimi N»: la corsia deve coprire
    /// esattamente lo stesso arco dell'asse sopra, altrimenti un pomeriggio
    /// vuoto potrebbe voler dire «nessuno ha toccato niente» oppure «il limite
    /// si è esaurito prima», e le due cose non si distinguerebbero guardando.
    ///
    /// Senza tetto sul numero di righe. Ce n'era uno a tremila, con il
    /// ragionamento che una giornata normale ne produce qualche centinaio.
    /// Erano sbagliate entrambe le parti: questa casa ne produce
    /// quattromilacinquecento al giorno, e ordinate per timestamp crescente un
    /// tetto non toglie «le meno importanti» — toglie **la fine della
    /// giornata**. Il difetto peggiore non era la troncatura ma il fatto che
    /// non si vedesse: una giornata tagliata ha lo stesso aspetto di una
    /// giornata tranquilla.
    private func loadGestures(day: DateInterval, now: Date) -> [HumanGesture] {
        guard let context, let scenes else { return [] }
        let start = day.start
        let end = day.end
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        guard let events = try? context.fetch(descriptor) else { return [] }

        let raw = events.map { event in
            HumanGestureBuilder.RawChange(accessoryUUID: event.accessoryID,
                                          accessoryName: event.accessoryName,
                                          roomName: event.roomName,
                                          state: event.state,
                                          brightness: event.brightness,
                                          eventType: event.eventType,
                                          at: event.timestamp,
                                          origin: event.originRaw)
        }
        // Una lettura sola, due letture diverse degli stessi eventi: i gesti
        // guardano *chi* ha agito, i periodi guardano *per quanto*. Rifare la
        // query per la seconda sarebbe pagare due volte la stessa risposta.
        let fires = moments.filter(\.isAutomationKind).map(\.at)
        spans = DaySpanBuilder.build(from: raw, window: day, scheduledFires: fires, now: now)

        let built = HumanGestureBuilder.build(from: raw,
                                              scheduledFires: fires,
                                              scenes: scenes.sceneSignatures(),
                                              now: now)
        // I due racconti si incontrano qui: dove la barra dice già tutto, il
        // rombo si toglie di mezzo.
        return HumanGestureBuilder.removingCovered(built, by: spans)
    }
}
