import SwiftUI

// MARK: - DayRibbonView

/// La giornata della casa su un asse orizzontale.
///
/// Esiste per rispondere a una domanda che un elenco non può risolvere: la
/// forma di una giornata si legge meglio in verticale o in orizzontale? In
/// colonna quattordici momenti sono quattordici righe, e lo spazio fra le 9:00
/// e le 13:30 è lo stesso che fra le 22:00 e le 22:30. Su un asse il tempo è
/// una lunghezza: i grappoli si addensano, e il pomeriggio deserto diventa un
/// fatto che si vede invece di una deduzione da fare.
///
/// Questa versione si limita a mostrare. Trascinare il tempo — e far cambiare
/// la planimetria sopra — richiede di ricostruire lo stato della casa a un
/// istante qualunque, che oggi nessuno conserva.
struct DayRibbonView: View {

    let moments: [DayMoment]
    let day: DateInterval
    let now: Date
    /// Alba e tramonto: qui non sono momenti ma la cornice della giornata.
    var sunrise: Date?
    var sunset: Date?

    /// I gesti umani della giornata: la corsia sotto l'asse.
    ///
    /// Sopra la riga c'è la casa che si muove da sola, sotto le persone che la
    /// muovono. Sono due voci diverse e stanno da parti diverse, così non c'è
    /// bisogno di una legenda per capire chi ha fatto cosa.
    var gestures: [HumanGesture] = []

    /// Le cose che sono **durate**: barre sull'asse, non punti sopra.
    var spans: [DaySpan] = []

    /// Chi riceve la selezione. Il nastro non sa cosa farne: se ne occupa chi
    /// lo ospita, che è l'unico a sapere se c'è un pannello dove metterla.
    /// A quanti giorni da oggi siamo, e fin dove ci si può spingere.
    var dayOffset: Int = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    var onSelect: ((DayMoment) -> Void)? = nil
    var onSelectGesture: ((HumanGesture) -> Void)? = nil
    var onSelectSpan: ((DaySpan) -> Void)? = nil
    var onSelectRunningSpans: (([DaySpan]) -> Void)? = nil
    var onShiftDay: ((Int) -> Void)? = nil
    var onReturnToday: (() -> Void)? = nil

    /// Tieni premuto e scorri: la casa si illumina come a quell'ora.
    ///
    /// `nil` al rilascio, per tornare ad adesso. Il nastro non sa cosa
    /// significhi: si limita a dire dove sta il dito.
    var onScrubLight: ((Date?) -> Void)? = nil

    @State private var selected: DayMoment?
    @State private var selectedGestureID: String?
    @State private var selectedSpanID: String?
    /// Quanto il nastro sta seguendo il dito in questo istante.
    @State private var dragOffset: CGFloat = 0
    /// Dove sta il dito mentre si trascina la luce, in frazione di giornata.
    @State private var scrubFraction: CGFloat?

    // MARK: Geometria

    private var span: TimeInterval { max(day.duration, 1) }
    private func fraction(of instant: Date) -> CGFloat {
        CGFloat(min(max(instant.timeIntervalSince(day.start) / span, 0), 1))
    }

    /// La fascia dei nomi, sopra i pallini.
    ///
    /// Una riga sola e non due. Con il raggruppamento dei punti vicini i
    /// nominati sono pochi e distanti, quindi la seconda riga servirebbe di
    /// rado e costerebbe sempre — e su questo nastro l'altezza è la valuta.
    private static let labelRowHeight: CGFloat = 11
    private static let labelRows = 1
    private static let stalkTop: CGFloat = labelRowHeight * CGFloat(labelRows) + 3
    private static let stalkHeight: CGFloat = 7
    /// L'asse sta sotto la corsia del programmato: sopra ci sono gli eventi, qui
    /// c'è il tempo. Mischiarli nello stesso centro ottico rendeva illeggibili
    /// sia i marker sia Alba/Tramonto.
    private static let axisY: CGFloat = stalkTop + 10 + stalkHeight

    /// L'asse resta una fascia, ma non ospita più le durate individuali.
    ///
    /// Le durate sono ancora calcolate e selezionabili dalla testata, ma la
    /// scala principale deve leggere solo: momento programmato sopra, attività
    /// reale sotto. La fascia serve a dare profondità al giorno e a contenere
    /// alba/tramonto, non a diventare una lista orizzontale.
    nonisolated static let spanLanes = 3
    private static let spanLaneHeight: CGFloat = 9
    private static let spanLaneGap: CGFloat = 1
    private static let axisHeight: CGFloat = 14
    /// La corsia dei gesti, appena sotto l'asse.
    static let gestureLaneY: CGFloat = axisY + axisHeight + 22
    /// Le ore stanno sotto le pillole: se condividono quasi la stessa y, il
    /// numero del gesto sembra appartenere alla scala e il "12" sparisce.
    private static let hourLabelY: CGFloat = gestureLaneY + 17
    static let totalHeight: CGFloat = hourLabelY + 6
    /// Alta quanto le due righe chiedono davvero.
    ///
    /// Era 24, e due righe da nove e dodici punti — con interlinea e discendenti
    /// — ne vogliono ventotto. Con `alignment: .top` l'eccesso non veniva
    /// tagliato: traboccava verso il basso, si mangiava il vuoto e finiva
    /// addosso alle tacche delle automazioni, che partono esattamente dal bordo
    /// alto della timeline. Un frame più basso del suo contenuto non lo
    /// contiene: lo lascia uscire da sotto.
    private static let focusHeaderHeight: CGFloat = 28
    /// Il vuoto fra testa e asse contiene la label di "adesso".
    ///
    /// Se questo spazio è stretto, l'orario corrente deve stare quasi addosso
    /// ai pointer rossi e sembra un'etichetta dell'automazione vicina. Con una
    /// corsia propria, "20:50" resta il cursore del tempo, non un evento.
    /// Il vuoto fra testa e asse si dimezza: le etichette ora lo riempiono da
    /// sole, e tenerlo vuoto **e** metterci sopra dei nomi sarebbe pagare due
    /// volte la stessa separazione.
    private static let focusTimelineGap: CGFloat = 9

    private func color(for moment: DayMoment) -> Color {
        switch moment.kind {
        case .automation: return BrandColor.primary
        case .solar:      return .orange
        case .calendar:   return .blue
        }
    }

    // MARK: Corpo

    /// L'ultima larghezza misurata, per i gesti che vivono fuori dal
    /// `GeometryReader` e devono comunque sapere quanto è largo il nastro.
    @State private var lastWidth: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            VStack(spacing: Self.focusTimelineGap) {
                focusHeader
                timelineCanvas(width: width)
            }
        }
        .frame(height: Self.contentHeight)
        .contentShape(Rectangle())
        .gesture(dayDrag)
        .simultaneousGesture(scrubGesture)
    }

    private static let contentHeight: CGFloat = focusHeaderHeight + focusTimelineGap + totalHeight

    /// Un momento sull'asse, con quanti ne rappresenta e se porta il nome.
    struct AxisPlacement: Equatable {
        let moment: DayMoment
        /// Quanti momenti stanno sotto questo punto. Uno significa sé stesso.
        let count: Int
        let x: CGFloat
        let level: Int
        /// `nil` quando il nome non si mostra: o non c'è spazio, o quel momento
        /// è lontano dall'ora presente.
        let labelWidth: CGFloat?
    }

    /// Sotto questa distanza due momenti sono lo stesso punto per l'occhio.
    static let clusterSeparation: CGFloat = 15
    /// Quanti momenti attorno ad adesso portano il nome.
    static let labelledPast = 2
    static let labelledFuture = 3
    static let maxLabelWidth: CGFloat = 130
    /// Sotto questa larghezza l'etichetta mostrerebbe tre caratteri e un
    /// puntino: non è un'etichetta corta, è rumore con l'aria di
    /// un'informazione.
    static let minLabelWidth: CGFloat = 40

    /// I momenti sull'asse: raggruppati dove si toccano, nominati dove conta.
    ///
    /// Erano tutti pallini muti — dieci cerchi identici in cui non si
    /// riconosceva niente — e prima ancora erano tutti etichettati, con le
    /// etichette che si accavallavano. Nessuna delle due è la risposta, perché
    /// la domanda non è «nominarli o no»: è **quali**.
    ///
    /// Su un asse di ventiquattr'ore il nome serve dove si sta guardando, cioè
    /// attorno all'ora presente: cosa è appena successo e cosa sta per
    /// succedere. Il resto della giornata è contesto — dove è piena e dove è
    /// vuota — e per quello basta un punto.
    ///
    /// E dove i punti si toccano diventano **uno con il conteggio**, invece di
    /// tre cerchi sovrapposti che sembrano uno solo e si rubano il tocco a
    /// vicenda. È la stessa soluzione già adottata per i gesti: quando due cose
    /// non si distinguono a occhio, non si distinguono nemmeno col dito.
    static func axisLayout(_ moments: [DayMoment],
                           now: Date,
                           width: CGFloat,
                           fraction: (Date) -> CGFloat) -> [AxisPlacement] {
        let sorted = moments.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }

        // 1. Grappoli: chi cade troppo vicino al precedente ci finisce dentro.
        var clusters: [(moment: DayMoment, count: Int, x: CGFloat)] = []
        for moment in sorted {
            let x = fraction(moment.at) * width
            if let last = clusters.last, x - last.x < clusterSeparation {
                clusters[clusters.count - 1].count += 1
            } else {
                clusters.append((moment, 1, x))
            }
        }

        // 2. Quali nominare: una finestra attorno ad adesso.
        let boundary = clusters.firstIndex { $0.moment.at > now } ?? clusters.count
        let from = max(0, boundary - labelledPast)
        let to = min(clusters.count, boundary + labelledFuture)
        let labelled = Array(from..<to)

        // 3. Le etichette dei soli nominati si spartiscono due righe sfalsate,
        //    con la larghezza che arriva fino al vicino sulla stessa riga.
        var lastXOnRow = [CGFloat](repeating: -.greatestFiniteMagnitude, count: 2)
        var rowOf: [Int: Int] = [:]
        for index in labelled {
            let x = clusters[index].x
            for row in 0..<2 where x - lastXOnRow[row] >= minLabelWidth + 6 {
                rowOf[index] = row
                lastXOnRow[row] = x
                break
            }
        }

        return clusters.enumerated().map { index, cluster in
            guard let row = rowOf[index] else {
                return AxisPlacement(moment: cluster.moment, count: cluster.count,
                                     x: cluster.x, level: 0, labelWidth: nil)
            }
            let nextX = labelled.first { $0 > index && rowOf[$0] == row }
                .map { clusters[$0].x } ?? width
            let available = min(maxLabelWidth, nextX - cluster.x - 6)
            return AxisPlacement(moment: cluster.moment, count: cluster.count,
                                 x: cluster.x, level: row,
                                 labelWidth: available >= minLabelWidth ? available : nil)
        }
    }

    private func timelineCanvas(width: CGFloat) -> some View {
        let visibleMoments = Self.visibleMoments(moments, now: now)
        let calendarPills = visibleMoments.filter(Self.usesCalendarDurationPill)
        let pointMoments = visibleMoments.filter { !Self.usesCalendarDurationPill($0) }
        let placements = Self.axisLayout(pointMoments, now: now, width: width, fraction: fraction)

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    selected = nil
                    selectedGestureID = nil
                    selectedSpanID = nil
                }

            daylightBand(width: width)
            solarBoundaries(width: width)
            solarLabels(width: width)
            selectedSpanHitAreas(width: width)
            hourTicks(width: width)

            ForEach(calendarPills, id: \.id) { moment in
                calendarDurationPill(moment, width: width)
            }

            ForEach(placements, id: \.moment.id) { placement in
                marker(placement, width: width)
            }

            ForEach(Self.lane(gestures, width: width, fraction: fraction), id: \.gesture.id) { placement in
                diamond(placement, width: width)
            }

            if dayOffset == 0 { nowLine(width: width).zIndex(5) }
            if let scrubFraction { scrubLine(at: scrubFraction, width: width).zIndex(6) }
        }
        .frame(width: width, height: Self.totalHeight)
        .onAppear { lastWidth = width }
        .onChange(of: width) { _, new in lastWidth = new }
        .offset(x: dragOffset)
        // Il contenuto sbiadisce mentre si trascina: dice che quello che
        // stai guardando sta per non essere più valido, senza aspettare
        // che sia cambiato.
        .opacity(1 - min(abs(dragOffset) / 220, 0.45))
    }

    // MARK: Adesso / prossimo

    private var focusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentEyebrow)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(currentDetail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // Il segno che si può toccare.
                    //
                    // Il tocco c'era già e apriva il pannello, ma niente lo
                    // diceva: su un pannello al muro una funzione che non si
                    // annuncia è una funzione che non esiste.
                    if !runningSpans.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                let running = runningSpans
                guard let first = running.first else { return }
                selected = nil
                selectedGestureID = nil
                if running.count == 1 {
                    selectedSpanID = first.id
                    onSelectSpan?(first)
                } else {
                    selectedSpanID = nil
                    onSelectRunningSpans?(running)
                }
            }

            if let next = nextMoment {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(localized: "ribbon.next.eyebrow",
                                defaultValue: "PROSSIMO · \(relativeTime(to: next.at))"))
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "ribbon.next.detail",
                                    defaultValue: "\(next.at.formatted(date: .omitted, time: .shortened)) \(Self.ribbonTitle(for: next))"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                // Simmetrico a «In corso»: da una parte cosa sta girando, da
                // quella opposta cosa sta per partire, e tutt'e due aprono il
                // dettaglio. Era toccabile solo la prima, e l'asimmetria non
                // aveva ragioni — solo il fatto che era stata scritta prima.
                .onTapGesture {
                    selectedGestureID = nil
                    selectedSpanID = nil
                    selected = next
                    onSelect?(next)
                }
            } else {
                Text(String(localized: "ribbon.next.none.inline", defaultValue: "PROSSIMO · Nessun evento"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: Self.focusHeaderHeight, alignment: .top)
    }

    private var nextMoment: DayMoment? {
        moments.first { $0.at > now }
    }

    private var runningSpans: [DaySpan] {
        spans.filter { span in
            span.start <= now && (span.end ?? .distantFuture) > now
        }
    }

    private var currentEyebrow: String {
        if dayOffset == 0 {
            return String(localized: "ribbon.now.eyebrow",
                          defaultValue: "ADESSO · \(now.formatted(date: .omitted, time: .shortened))")
        }
        return DayRibbonView.dayLabel(offset: dayOffset, day: day.start).uppercased()
    }

    private var currentDetail: String {
        if let first = runningSpans.first {
            guard runningSpans.count == 1 else {
                return String(localized: "ribbon.now.running.count",
                              defaultValue: "In corso · \(runningSpans.count)")
            }
            return String(localized: "ribbon.now.running",
                          defaultValue: "\(first.name) in corso")
        }

        let past = moments.filter { $0.at <= now }.count
        let future = moments.filter { $0.at > now }.count
        if dayOffset == 0 {
            return String(localized: "ribbon.now.counts",
                          defaultValue: "\(past) eseguiti · \(future) in arrivo")
        }
        return String(localized: "ribbon.day.counts",
                      defaultValue: "\(moments.count) eventi · \(spans.count) durate")
    }

    private func relativeTime(to date: Date) -> String {
        let interval = max(date.timeIntervalSince(now), 0)
        let minutes = Int(interval / 60)
        if minutes < 1 {
            return String(localized: "ribbon.relative.now", defaultValue: "ora")
        }
        if minutes < 60 {
            return String(localized: "ribbon.relative.minutes", defaultValue: "fra \(minutes)m")
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "ribbon.relative.hours", defaultValue: "fra \(hours)h")
            : String(localized: "ribbon.relative.hoursMinutes", defaultValue: "fra \(hours)h \(remainder)m")
    }

    private static func visibleMoments(_ moments: [DayMoment], now: Date) -> [DayMoment] {
        let past = moments.filter { $0.at <= now }
        let future = moments.filter { $0.at > now }.prefix(6)
        return (past + Array(future)).sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
    }

    // MARK: Trascinare la luce

    /// Tieni premuto, poi scorri: tutta la schermata si illumina come a quell'ora.
    ///
    /// Nasce da un'impossibilità pratica: la luce circadiana attraversa quattro
    /// fasi nell'arco di una giornata, e senza un modo di muoverla si può
    /// giudicare solo quella dell'ora in cui si guarda. Per vedere l'alba
    /// bisognava alzarsi all'alba. Una funzionalità che non si può osservare
    /// non si può nemmeno tarare.
    ///
    /// Preceduto da una pressione lunga perché il trascinamento orizzontale è
    /// già dei giorni: senza, ogni scorrimento sarebbe ambiguo e uno dei due
    /// gesti dovrebbe rinunciare. Premere prima dice «non voglio cambiare
    /// giorno, voglio muovermi dentro questo».
    ///
    /// Muove solo la luce, non lo stato della casa: i marker restano quelli di
    /// adesso. È una differenza che va tenuta onesta — ricostruire la casa a un
    /// istante qualunque è un'altra cosa, e prometterla con lo stesso gesto
    /// sarebbe la bugia più facile.
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let width = max(lastWidth, 1)
                let fraction = min(max(drag.location.x / width, 0), 1)
                scrubFraction = fraction
                onScrubLight?(day.start.addingTimeInterval(day.duration * Double(fraction)))
            }
            .onEnded { _ in
                scrubFraction = nil
                onScrubLight?(nil)
            }
    }

    private func scrubLine(at fraction: CGFloat, width: CGFloat) -> some View {
        let instant = day.start.addingTimeInterval(day.duration * Double(fraction))
        let labelY = Self.axisY + Self.axisHeight + 8
        let lineTop = Self.axisY - 1
        let lineBottom = Self.gestureLaneY + 9
        let x = min(max(fraction * width, 18), width - 18)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2, height: lineBottom - lineTop)
                .position(x: x, y: (lineTop + lineBottom) / 2)

            Text(instant.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.background.opacity(0.86), in: Capsule())
                .position(x: x, y: labelY)
        }
        .frame(width: width, height: Self.totalHeight, alignment: .topLeading)
    }

    // MARK: Trascinare i giorni

    /// Il nastro segue il dito, e un colpetto basta.
    ///
    /// Prima era una soglia secca a quaranta punti: funzionava e non si
    /// capiva, perché un gesto che non dà risposta mentre lo fai non sembra un
    /// gesto — sembra che non sia successo niente. Seguire il dito è ciò che
    /// rende il nastro *afferrabile*: si scopre che si muove provando a
    /// muoverlo.
    ///
    /// Si decide sulla traiettoria prevista e non sulla distanza percorsa, così
    /// un colpetto svelto conta quanto un trascinamento lungo — è quello che
    /// fa sentire la cosa inerziale invece che a scatti.
    private var dayDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = Self.resisted(value.translation.width,
                                           canGoBack: canGoBack, canGoForward: canGoForward)
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                if predicted > Self.commitDistance, canGoBack {
                    onShiftDay?(-1)
                } else if predicted < -Self.commitDistance, canGoForward {
                    onShiftDay?(1)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = 0
                }
            }
    }

    static let commitDistance: CGFloat = 60

    /// Quanto il nastro segue il dito, e quanto resiste al bordo.
    ///
    /// Oltre il limite non si blocca: rallenta. Un muro invisibile lascia
    /// credere che il gesto non abbia funzionato, mentre un elastico dice
    /// «ho capito, ma di là non c'è niente» — e lo dice col dito, che è
    /// l'unico posto dove si stava già guardando.
    nonisolated static func resisted(_ translation: CGFloat,
                                     canGoBack: Bool,
                                     canGoForward: Bool) -> CGFloat {
        let allowed = translation > 0 ? canGoBack : canGoForward
        return allowed ? translation * 0.75 : translation * 0.12
    }

    /// «Ieri», «Domani», o la data. Le parole dove esistono, la data dove no.
    nonisolated static func dayLabel(offset: Int, day: Date) -> String {
        switch offset {
        case 0:  return String(localized: "ribbon.day.today", defaultValue: "Oggi")
        case -1: return String(localized: "ribbon.day.yesterday", defaultValue: "Ieri")
        case 1:  return String(localized: "ribbon.day.tomorrow", defaultValue: "Domani")
        default: return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    // MARK: Cornice del giorno

    /// La banda che dice dov'è il giorno e dov'è la notte.
    ///
    /// È la ragione per cui alba e tramonto non sono pallini: come sfondo
    /// raccontano la stessa cosa senza occupare due posti nella fila e senza
    /// chiedere un'etichetta. Un asse che comincia scuro, si schiarisce e
    /// torna scuro *è già* una giornata, prima ancora di leggerci sopra.
    private func daylightBand(width: CGFloat) -> some View {
        let riseX = sunrise.map(fraction) ?? 0.25
        let setX  = sunset.map(fraction)  ?? 0.85
        return LinearGradient(
            stops: [
                .init(color: .secondary.opacity(0.10), location: 0),
                .init(color: .secondary.opacity(0.10), location: max(riseX - 0.02, 0)),
                .init(color: .orange.opacity(0.16),    location: min(riseX + 0.02, 1)),
                .init(color: .orange.opacity(0.16),    location: max(setX - 0.02, 0)),
                .init(color: .secondary.opacity(0.10), location: min(setX + 0.02, 1)),
                .init(color: .secondary.opacity(0.10), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: Self.axisHeight)
            .clipShape(Capsule())
            .position(x: width / 2, y: Self.axisY + Self.axisHeight / 2)
    }

    /// Due trattini sottili dove il giorno comincia e finisce.
    ///
    /// Il gradiente da solo direbbe «verso quell'ora»; questi dicono l'ora.
    @ViewBuilder
    private func solarBoundaries(width: CGFloat) -> some View {
        ForEach([sunrise, sunset].compactMap { $0 }, id: \.self) { instant in
            Rectangle()
                .fill(Color.orange.opacity(0.55))
                .frame(width: 1, height: Self.axisHeight + 8)
                .position(x: fraction(of: instant) * width,
                          y: Self.axisY + Self.axisHeight / 2)
        }
    }

    @ViewBuilder
    private func solarLabels(width: CGFloat) -> some View {
        ForEach(solarAnnotations, id: \.date) { item in
            // Testo nudo sulla riga delle ore, non più una pillola sulla banda.
            //
            // Con fondo e bordo avevano il peso visivo di un evento, e sull'asse
            // competevano con le cose che succedono davvero. Ma alba e tramonto
            // non succedono: sono la cornice — la banda del giorno li racconta
            // già come sfondo, e questi due nomi servono solo a dire l'ora
            // esatta di un confine che si vede da sé.
            Text(item.title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.orange.opacity(0.65))
                .lineLimit(1)
                .fixedSize()
                .position(x: min(max(fraction(of: item.date) * width, 24), width - 34),
                          y: Self.hourLabelY)
        }
    }

    private var solarAnnotations: [(title: String, date: Date)] {
        [
            sunrise.map { (String(localized: "ribbon.sunrise", defaultValue: "Alba"), $0) },
            sunset.map { (String(localized: "ribbon.sunset", defaultValue: "Tramonto"), $0) }
        ].compactMap { $0 }
    }

    private func hourTicks(width: CGFloat) -> some View {
        ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
            let x = (CGFloat(hour) / 24) * width
            Text(String(format: "%02d", hour % 24))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .position(x: min(max(x, 10), width - 10),
                          y: Self.hourLabelY)
        }
    }

    // MARK: Momenti

    private func marker(_ placement: AxisPlacement, width: CGFloat) -> some View {
        let moment = placement.moment
        let isSelected = selected?.id == moment.id
        let tint = color(for: moment)

        return VStack(alignment: .leading, spacing: 0) {
            if let labelWidth = placement.labelWidth {
                Text(Self.ribbonTitle(for: moment))
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(moment.isPast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.top, CGFloat(placement.level) * Self.labelRowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(width: max(placement.labelWidth ?? 0, 32),
               height: Self.stalkTop, alignment: .topLeading)
        .overlay(alignment: .top) { stalk(moment: moment, tint: tint, isSelected: isSelected) }
        .frame(width: max(placement.labelWidth ?? 0, 32),
               height: Self.totalHeight,
               alignment: .topLeading)
        .contentShape(Rectangle())
        .position(x: placement.x, y: Self.totalHeight / 2)
        .onTapGesture {
            selected = isSelected ? nil : moment
            if !isSelected { onSelect?(moment) }
        }
    }

    nonisolated private static func usesCalendarDurationPill(_ moment: DayMoment) -> Bool {
        guard case .calendar(false) = moment.kind,
              let end = moment.calendarEnd,
              end.timeIntervalSince(moment.at) >= 30 * 60
        else { return false }
        return true
    }

    private func calendarDurationPill(_ moment: DayMoment, width: CGFloat) -> some View {
        let isSelected = selected?.id == moment.id
        let x0 = fraction(of: moment.at) * width
        let x1 = fraction(of: min(moment.calendarEnd ?? moment.at, day.end)) * width
        let pillWidth = max(x1 - x0, 28)
        let center = min(max(x0 + pillWidth / 2, pillWidth / 2), width - pillWidth / 2)
        let tint = Color(hue: 0.58, saturation: 0.48, brightness: 0.78)

        return HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 7, weight: .bold))
            if pillWidth >= 82 {
                Text(Self.ribbonTitle(for: moment))
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(tint.opacity(moment.isPast ? 0.55 : 0.95))
        .padding(.horizontal, pillWidth >= 82 ? 6 : 0)
        .frame(width: pillWidth, height: 11)
        .background {
            Capsule()
                .fill(tint.opacity(moment.isPast ? 0.08 : 0.14))
        }
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(isSelected ? 0.90 : 0.42),
                              lineWidth: isSelected ? 1.4 : 0.8)
        }
        .overlay {
            if isSelected {
                Capsule()
                    .strokeBorder(tint.opacity(0.75), lineWidth: 1)
                    .padding(-3)
            }
        }
        .frame(width: pillWidth, height: 26)
        .contentShape(Rectangle())
        .position(x: center, y: Self.axisY + Self.axisHeight / 2)
        .onTapGesture {
            selectedGestureID = nil
            selectedSpanID = nil
            selected = isSelected ? nil : moment
            if !isSelected { onSelect?(moment) }
        }
        .zIndex(1)
    }

    /// Il gambo e il punto.
    ///
    /// Passato e futuro si distinguono per **forma** e non solo per intensità:
    /// il passato è vuoto, il futuro è pieno. Una differenza di sola opacità si
    /// perde sotto il sole o su uno schermo storto, mentre pieno contro vuoto
    /// resta leggibile sempre — ed è anche il modo in cui si disegna da secoli
    /// la differenza fra ciò che è accaduto e ciò che è previsto.
    private func stalk(moment: DayMoment, tint: Color, isSelected: Bool,
                       count: Int = 1) -> some View {
        VStack(spacing: 0) {
            Group {
                if case .calendar = moment.kind {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(moment.isPast ? 0.14 : 0.22))
                        Image(systemName: "calendar")
                            .font(.system(size: isSelected ? 8 : 7, weight: .bold))
                            .foregroundStyle(tint.opacity(moment.isPast ? 0.72 : 1))
                    }
                } else if moment.isPast {
                    Circle()
                        .strokeBorder(tint.opacity(0.85), lineWidth: 1.5)
                } else {
                    Circle().fill(tint)
                }
            }
            .frame(width: isSelected ? 11 : 10, height: isSelected ? 11 : 10)
            // Il grappolo porta quanti ne nasconde.
            //
            // Tre cerchi sovrapposti sembrano uno solo e si rubano il tocco a
            // vicenda: dire «3» è l'unico modo perché quel punto non menta
            // sulla propria consistenza.
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(min(count, 9))")
                        .font(.system(size: 7, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 10, height: 10)
                        .background(Circle().fill(tint))
                        .offset(x: 6, y: -4)
                }
            }

            Rectangle()
                .fill(tint.opacity(moment.isPast ? 0.30 : 0.55))
                .frame(width: isSelected ? 2 : 1.2, height: Self.stalkHeight)
        }
        // Il gambo comincia dove finisce la fascia dei nomi: prima partiva dal
        // bordo alto e il pallino si sedeva sull'etichetta.
        .offset(y: Self.stalkTop)
    }

    // MARK: Durate

    /// Le durate non si disegnano nel nastro compatto.
    ///
    /// Prima ogni processo lungo diventava una barra dentro la scala. Era
    /// corretto come dato, ma sbagliato come lettura: se si vedeva solo
    /// "Purificatore Studio", sembrava che la casa stesse facendo solo quello.
    /// La vista compatta ora tiene le durate nella testata "In corso" e nel
    /// pannello laterale; qui restano solo aree di tocco invisibili, per non
    /// perdere la selezione quando una durata è già aperta.
    @ViewBuilder
    private func selectedSpanHitAreas(width: CGFloat) -> some View {
        let placed = Self.assignLanes(spans, now: now)
        ForEach(placed, id: \.span.id) { item in
            let x0 = fraction(of: item.span.start) * width
            let x1 = fraction(of: item.span.end ?? now) * width
            let barWidth = max(x1 - x0, 3)
            let isSelected = selectedSpanID == item.span.id

            Color.clear
                .frame(width: barWidth, height: Self.spanLaneHeight + Self.spanLaneGap)
                .contentShape(Rectangle())
                .position(x: x0 + barWidth / 2, y: Self.spanLaneY(item.lane))
                .onTapGesture {
                    selected = nil
                    selectedGestureID = nil
                    if isSelected {
                        selectedSpanID = nil
                    } else {
                        selectedSpanID = item.span.id
                        onSelectSpan?(item.span)
                    }
                }
                .opacity(isSelected ? 1 : 0.001)
        }
    }

    private func spanReadout(_ span: DaySpan, width: CGFloat) -> some View {
        let x0 = fraction(of: span.start) * width
        let x1 = fraction(of: span.end ?? now) * width
        return Text(span.name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Self.spanTint(for: span))
            .lineLimit(1)
            .fixedSize()
            .position(x: min(max((x0 + x1) / 2, 40), width - 40),
                      y: Self.axisY - 7)
    }

    @ViewBuilder
    private func spanContent(_ span: DaySpan, barWidth: CGFloat) -> some View {
        let icon = Self.spanSymbol(for: span)
        if barWidth > 18 {
            Image(systemName: icon)
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 5)
                .frame(width: max(barWidth - 6, 0), alignment: .leading)
                .allowsHitTesting(false)
        }
    }

    /// Il simbolo del processo, lo stesso che l'accessorio porta altrove.
    nonisolated static func spanSymbol(for span: DaySpan) -> String {
        switch AccessoryEventType(rawValue: span.eventType) {
        case .thermostat:   return "thermometer"
        case .airPurifier: return "air.purifier"
        case .fan:         return "fan"
        case .humidifier:  return "humidifier"
        case .outlet:      return "powerplug"
        default:           return "switch.2"
        }
    }

    private static func spanLaneY(_ lane: Int) -> CGFloat {
        axisY + 1 + (spanLaneHeight + spanLaneGap) * CGFloat(lane) + spanLaneHeight / 2
    }

    struct SpanPlacement: Equatable {
        let span: DaySpan
        let lane: Int
    }

    /// Dà a ogni periodo una riga in cui non tocca nessuno.
    ///
    /// Assegnazione greedy sul tempo: si scorre per inizio e si prende la prima
    /// riga libera. È l'algoritmo giusto perché il problema è letteralmente
    /// quello di colorare un grafo di intervalli, e su un asse temporale il
    /// greedy ordinato per inizio è ottimo — non esiste una disposizione che
    /// usi meno righe.
    ///
    /// Oltre il numero di righe disponibili si rinuncia invece di accavallare.
    /// È la stessa scelta delle etichette dei momenti: due cose sovrapposte non
    /// si leggono né l'una né l'altra, e l'ultima arrivata che copre le altre
    /// le rovina tutte per mostrare sé stessa.
    ///
    /// L'ordinamento è quello **totale** di `DaySpanBuilder.precedes` e non un
    /// confronto sul solo inizio: a parità di inizio — cioè per tutto ciò che
    /// era già acceso a mezzanotte — un ordinamento parziale lasciava decidere
    /// al caso, e le corsie cambiavano da sole a ogni ricostruzione.
    nonisolated static func assignLanes(_ spans: [DaySpan], now: Date) -> [SpanPlacement] {
        var laneEnds = [Date](repeating: .distantPast, count: spanLanes)
        var placements: [SpanPlacement] = []

        for span in spans.sorted(by: DaySpanBuilder.precedes) {
            let end = span.end ?? now
            guard let lane = (0..<spanLanes).first(where: { laneEnds[$0] <= span.start }) else { continue }
            laneEnds[lane] = end
            placements.append(SpanPlacement(span: span, lane: lane))
        }
        return placements
    }

    /// Un colore per famiglia di processo, non uno per accessorio.
    ///
    /// Tenuti desaturati e distinti dai due che significano già qualcosa —
    /// `BrandColor.primary` per le automazioni, il verde acqua per i gesti — e
    /// lontani dall'arancione e dal rosso, che nell'app vogliono dire
    /// attenzione e urgenza.
    nonisolated static func spanTint(for span: DaySpan) -> Color {
        switch AccessoryEventType(rawValue: span.eventType) {
        case .thermostat:        return Color(hue: 0.07, saturation: 0.58, brightness: 0.68)
        case .airPurifier, .fan: return Color(hue: 0.52, saturation: 0.45, brightness: 0.62)
        case .humidifier:        return Color(hue: 0.58, saturation: 0.42, brightness: 0.60)
        default:                 return Color(hue: 0.72, saturation: 0.34, brightness: 0.60)
        }
    }

    // MARK: Gesti

    /// Una pillola per ogni gesto, con dentro quanti comandi contiene.
    ///
    /// La forma a rombo era riconoscibile, ma il numero appeso sopra diventava
    /// fragile nei temi chiari e finiva per sembrare un badge esterno. La
    /// pillola prende spunto dal nastro con durate: sta sulla timeline, porta il
    /// numero dentro e mantiene un bersaglio di tocco leggibile.
    private func diamond(_ placement: GesturePlacement, width: CGFloat) -> some View {
        let gesture = placement.gesture
        let isSelected = selectedGestureID == gesture.id
        let count = min(gesture.changes.count, 99)
        // Larghezza fissa: il numero lo dice già.
        //
        // La pillola cresceva col numero di comandi **e** lo scriveva dentro.
        // Due codifiche per un dato solo: quella che si legge esattamente — la
        // cifra — e quella che si legge male — la larghezza, che oltretutto
        // faceva sembrare un gesto lungo nel tempo ciò che era solo numeroso.
        let pillWidth = Self.gesturePillWidth(changeCount: 1)

        return HStack(spacing: 3) {
            if gesture.isScene {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text("\(count)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
        }
            .foregroundStyle(gesture.isScene ? Self.gestureTint : .white)
            .frame(width: pillWidth, height: 16)
            .background {
                Capsule()
                    .fill(gesture.isScene ? Color.clear : Self.gestureTint.opacity(isSelected ? 1 : 0.82))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Self.gestureTint.opacity(isSelected ? 1 : 0.95),
                                  lineWidth: gesture.isScene || isSelected ? 1.5 : 0.6)
            }
            .overlay {
                if isSelected {
                    Capsule()
                        .strokeBorder(Self.gestureTint.opacity(0.9), lineWidth: 1)
                        .padding(-3)
                }
            }
            .frame(width: max(38, pillWidth + 8), height: 28)
            .contentShape(Rectangle())
            .position(x: placement.x, y: Self.gestureLaneY)
            .onTapGesture {
                selected = nil
                if isSelected {
                    selectedGestureID = nil
                } else {
                    selectedGestureID = gesture.id
                    onSelectGesture?(gesture)
                }
            }
    }

    private static let gestureTint = Color.teal

    nonisolated static func gesturePillWidth(changeCount: Int) -> CGFloat {
        min(max(24, 22 + CGFloat(String(min(max(changeCount, 1), 99)).count) * 7), 38)
    }

    nonisolated static func diamondSide(changeCount: Int) -> CGFloat {
        min(7 + CGFloat(max(changeCount - 1, 0)) * 1.4, 13)
    }

    struct GesturePlacement {
        let gesture: HumanGesture
        let x: CGFloat
    }

    /// Colloca i gesti sull'asse, fondendo quelli che finirebbero uno sull'altro.
    ///
    /// La fusione è visiva, non semantica: le regole di raggruppamento stanno
    /// in `HumanGestureBuilder` e ragionano in minuti, qui si ragiona in punti
    /// perché è lo schermo a decidere cosa si distingue. Su ventiquattr'ore
    /// larghe ottocento punti, tre minuti sono meno di due punti: senza questo
    /// passaggio due gesti vicini diventerebbero un rombo che ne nasconde un
    /// altro, e toccandolo si aprirebbe quello sbagliato.
    static func lane(_ gestures: [HumanGesture],
                     width: CGFloat,
                     fraction: (Date) -> CGFloat,
                     minSpacing: CGFloat = 26) -> [GesturePlacement] {
        let sorted = gestures.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }

        var groups: [[HumanGesture]] = []
        var currentX: CGFloat = -.greatestFiniteMagnitude

        for gesture in sorted {
            let x = fraction(gesture.at) * width
            if x - currentX < minSpacing, !groups.isEmpty {
                groups[groups.count - 1].append(gesture)
            } else {
                groups.append([gesture])
                currentX = x
            }
        }

        return groups.map { group in
            let merged = group.count == 1 ? group[0] : HumanGestureBuilder.merge(group)
            return GesturePlacement(gesture: merged, x: fraction(merged.at) * width)
        }
    }

    private func nowLine(width: CGFloat) -> some View {
        let x = fraction(of: now) * width
        let labelX = min(max(x, 22), width - 22)
        let labelY = Self.axisY + Self.axisHeight + 8
        let lineTop = Self.axisY - 1
        let lineBottom = Self.gestureLaneY + 9
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.85))
                .frame(width: 2, height: lineBottom - lineTop)
                .position(x: x, y: (lineTop + lineBottom) / 2)

            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.background.opacity(0.82), in: Capsule())
                .position(x: labelX, y: labelY)
        }
        .frame(width: width, height: Self.totalHeight, alignment: .topLeading)
    }

    // MARK: La barra del giorno

    /// I comandi del giorno, sempre visibili.
    ///
    /// Il trascinamento da solo non bastava: è un gesto che nessuno prova se
    /// niente gli dice che esiste, e su un pannello appeso al muro non c'è
    /// nemmeno la curiosità di chi tiene l'oggetto in mano. Due frecce e una
    /// data risolvono la scoperta e restano utili dopo — sono anche il modo
    /// più preciso di spostarsi di un giorno solo, che col dito è sempre un po'
    /// una scommessa.
    ///
    /// Vive fuori dal disegno dell'asse di proposito: lassù ogni riga è già
    /// assegnata alle etichette dei momenti, e una pillola galleggiante in
    /// mezzo finirebbe sotto o sopra un nome.
    struct DayBar: View {
        let dayOffset: Int
        let day: Date
        var onReturnToday: (() -> Void)? = nil

        var body: some View {
            label
                .frame(maxWidth: .infinity)
            .frame(height: 20)
        }

        @ViewBuilder
        private var label: some View {
            if dayOffset == 0 {
                Text(DayRibbonView.dayLabel(offset: 0, day: day))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                // Fuori da oggi l'etichetta diventa la via di ritorno. Senza,
                // si può finire in una giornata di tre settimane fa senza
                // capire come tornare, e il nastro smette di essere una
                // finestra per diventare un labirinto.
                Button { onReturnToday?() } label: {
                    HStack(spacing: 5) {
                        Text(DayRibbonView.dayLabel(offset: dayOffset, day: day))
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(BrandColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(BrandColor.primary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Titolo per l'asse

    /// Il nome ridotto a ciò che lo distingue.
    ///
    /// Sull'asse lo spazio è il vincolo, e i nomi generati dall'app Casa
    /// cominciano tutti con la parte che non serve: «Alle 09:00 di ogni giorno
    /// Attiva Purificatore» in ottantotto punti diventa «Alle 09:00 di ogni…»,
    /// cioè un'etichetta che consuma una riga intera per non dire niente. E
    /// l'ora è doppiamente sprecata, perché la posizione sull'asse *è già*
    /// l'ora.
    ///
    /// Quindi qui si taglia più a fondo che nell'elenco: via l'orario iniziale
    /// e, se quel che resta comincia in minuscolo, via anche le parole di
    /// servizio fino alla prima maiuscola — che è dove comincia la cosa vera.
    /// «del mattino imposta la Buonanotte» diventa «Buonanotte», che su un
    /// asse è esattamente l'etichetta giusta.
    ///
    /// Vale solo per le automazioni: «Festa Morelli» e «Alba» sono già nomi, e
    /// accorciarli li rovinerebbe. E se non c'è nessuna maiuscola da cui
    /// ripartire, il nome resta intero — meglio troncato che svuotato.
    static func ribbonTitle(for moment: DayMoment) -> String {
        guard moment.isAutomationKind else { return moment.title }

        var rest = Substring(moment.title).drop { $0.isWhitespace }

        // Una parola di servizio davanti («Alle», «At»…), se seguita dall'ora.
        let afterWord = rest.drop { $0.isLetter }
        if afterWord.count < rest.count, afterWord.first?.isWhitespace == true {
            let candidate = afterWord.drop { $0.isWhitespace }
            if candidate.first?.isNumber == true { rest = candidate }
        }

        // L'orario, se c'è.
        let hour = rest.prefix { $0.isNumber }
        if (1...2).contains(hour.count) {
            var after = rest.dropFirst(hour.count)
            if let sep = after.first, sep == ":" || sep == "." {
                after = after.dropFirst()
                let minute = after.prefix { $0.isNumber }
                if minute.count == 2 {
                    rest = after.dropFirst(minute.count)
                        .drop { $0.isWhitespace || $0 == "-" || $0 == "–" || $0 == "—" || $0 == ":" }
                }
            }
        }

        // Se riparte in minuscolo, si salta fino alla prima maiuscola.
        if let first = rest.first, !first.isUppercase {
            let words = rest.split(separator: " ", omittingEmptySubsequences: true)
            if let start = words.firstIndex(where: { $0.first?.isUppercase == true }) {
                rest = Substring(words[start...].joined(separator: " "))
            }
        }

        let out = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? moment.title : out
    }

    // MARK: Disposizione delle etichette

    struct Placement {
        let moment: DayMoment
        let x: CGFloat
        let level: Int
        /// `nil` quando non c'è spazio: meglio nessuna etichetta di due
        /// sovrapposte che non si leggono né l'una né l'altra.
        let labelWidth: CGFloat?
    }

    /// Colloca le etichette su due righe sfalsate, e rinuncia quando non ci stanno.
    ///
    /// Con quattordici momenti in ventiquattr'ore lo spazio medio basterebbe,
    /// ma i momenti non sono distribuiti a caso: si addensano al mattino e la
    /// sera, che è appunto ciò che l'asse deve mostrare. Le due righe sfalsate
    /// recuperano i grappoli vicini; per quelli che restano troppo stretti la
    /// scelta è tacere, perché due etichette accavallate costano più di
    /// nessuna.
    static func layout(_ moments: [DayMoment],
                       width: CGFloat,
                       fraction: (Date) -> CGFloat) -> [Placement] {
        // Il tetto c'è perché un'etichetta lunghissima in una zona vuota
        // sbilancerebbe l'asse, ma a 88 punti anche i nomi con tutto lo spazio
        // del mondo intorno venivano troncati — «Alfred In Settiman…» con sei
        // ore libere davanti. Centotrenta lascia respirare chi ha posto senza
        // permettere a nessuno di invadere il vicino, perché la larghezza vera
        // resta comunque la distanza dal prossimo sulla stessa riga.
        let maxLabelWidth: CGFloat = 130
        // Sotto questa larghezza l'etichetta mostrerebbe tre caratteri e un
        // puntino: non è un'etichetta corta, è rumore con l'aria di
        // un'informazione. Meglio il solo punto, che almeno non promette nulla.
        let minLabelWidth: CGFloat = 40
        let sorted = moments.sorted { $0.at < $1.at }
        let xs = sorted.map { fraction($0.at) * width }

        var lastXOnRow = [CGFloat](repeating: -.greatestFiniteMagnitude, count: 2)
        var rowOf = [Int?](repeating: nil, count: sorted.count)

        for (index, x) in xs.enumerated() {
            for row in 0..<2 where x - lastXOnRow[row] >= minLabelWidth + 6 {
                rowOf[index] = row
                lastXOnRow[row] = x
                break
            }
        }

        return sorted.enumerated().map { index, moment in
            guard let row = rowOf[index] else {
                return Placement(moment: moment, x: xs[index], level: 0, labelWidth: nil)
            }
            // Larghezza disponibile: fino al prossimo vicino sulla stessa riga.
            let nextX = xs.indices.dropFirst(index + 1)
                .first { rowOf[$0] == row }
                .map { xs[$0] } ?? width
            let available = min(maxLabelWidth, nextX - xs[index] - 6)
            return Placement(moment: moment,
                             x: xs[index],
                             level: row,
                             labelWidth: available >= minLabelWidth ? available : nil)
        }
    }
}
