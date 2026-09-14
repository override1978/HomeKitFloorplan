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

    private static let labelRowHeight: CGFloat = 13
    private static let labelRows = 2
    private static let stalkTop: CGFloat = labelRowHeight * CGFloat(labelRows) + 4
    // Il gambo si accorcia per pagare le righe più alte dei periodi: la fascia
    // non poteva crescere ancora senza rubare spazio alla planimetria, e fra un
    // gambo lungo e una barra leggibile il gambo è l'ornamento.
    private static let stalkHeight: CGFloat = 14
    private static let axisY: CGFloat = stalkTop + stalkHeight

    /// L'asse è diventato una fascia, perché i periodi hanno bisogno di righe.
    ///
    /// Con una riga sola due periodi sovrapposti si disegnavano uno sull'altro
    /// e il risultato era una striscia continua con dentro dei nomi tagliati:
    /// sembrava una cosa sola con tre etichette invece di tre cose. Il tempo si
    /// sovrappone — è la sua natura — e l'unico modo di mostrarlo è dare a
    /// ciascuno una riga sua.
    static let spanLanes = 3
    /// Nove punti e non sei: dentro sei non ci sta niente, e una barra che non
    /// può dire cosa è costringe a toccarla per saperlo — su un pannello
    /// appeso al muro, che nessuno tocca per curiosità, vuol dire non dirlo.
    private static let spanLaneHeight: CGFloat = 9
    private static let spanLaneGap: CGFloat = 1
    private static let axisHeight: CGFloat =
        spanLaneHeight * CGFloat(spanLanes) + spanLaneGap * CGFloat(spanLanes - 1) + 2
    /// La corsia dei gesti, appena sotto l'asse.
    static let gestureLaneY: CGFloat = axisY + axisHeight + 9
    private static let hourLabelY: CGFloat = gestureLaneY + 15
    static let totalHeight: CGFloat = hourLabelY + 9

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
            let width = geo.size.width
            let placements = Self.layout(moments, width: width, fraction: fraction)

            ZStack(alignment: .topLeading) {
                daylightBand(width: width)
                solarBoundaries(width: width)
                spanBars(width: width)
                hourTicks(width: width)

                ForEach(placements, id: \.moment.id) { placement in
                    marker(placement, width: width)
                }

                ForEach(Self.lane(gestures, width: width, fraction: fraction), id: \.gesture.id) { placement in
                    diamond(placement, width: width)
                }

                if let span = spans.first(where: { $0.id == selectedSpanID }) {
                    spanReadout(span, width: width)
                }
                if dayOffset == 0 { nowLine(width: width) }
                if let scrubFraction { scrubLine(at: scrubFraction, width: width) }
            }
            .onAppear { lastWidth = width }
            .onChange(of: width) { _, new in lastWidth = new }
            .offset(x: dragOffset)
            // Il contenuto sbiadisce mentre si trascina: dice che quello che
            // stai guardando sta per non essere più valido, senza aspettare
            // che sia cambiato.
            .opacity(1 - min(abs(dragOffset) / 220, 0.45))
        }
        .frame(height: Self.totalHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = nil
            selectedGestureID = nil
            selectedSpanID = nil
        }
        .gesture(dayDrag)
        .simultaneousGesture(scrubGesture)
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
        return VStack(spacing: 1) {
            Text(instant.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.orange)
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2, height: Self.axisY + Self.axisHeight - Self.labelRowHeight)
        }
        .position(x: min(max(fraction * width, 18), width - 18),
                  y: (Self.axisY + Self.axisHeight) / 2 + 4)
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

    private func marker(_ placement: Placement, width: CGFloat) -> some View {
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
        .frame(width: max(placement.labelWidth ?? 0, 10),
               height: Self.stalkTop, alignment: .topLeading)
        .overlay(alignment: .topLeading) { stalk(moment: moment, tint: tint, isSelected: isSelected) }
        .frame(height: Self.totalHeight, alignment: .top)
        .position(x: placement.x + max(placement.labelWidth ?? 0, 10) / 2 - 5,
                  y: Self.totalHeight / 2)
        .onTapGesture {
            selected = isSelected ? nil : moment
            if !isSelected { onSelect?(moment) }
        }
    }

    /// Il gambo e il punto.
    ///
    /// Passato e futuro si distinguono per **forma** e non solo per intensità:
    /// il passato è vuoto, il futuro è pieno. Una differenza di sola opacità si
    /// perde sotto il sole o su uno schermo storto, mentre pieno contro vuoto
    /// resta leggibile sempre — ed è anche il modo in cui si disegna da secoli
    /// la differenza fra ciò che è accaduto e ciò che è previsto.
    private func stalk(moment: DayMoment, tint: Color, isSelected: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if moment.isPast {
                    Circle()
                        .strokeBorder(tint.opacity(0.85), lineWidth: 1.5)
                } else {
                    Circle().fill(tint)
                }
            }
            .frame(width: isSelected ? 9 : 7, height: isSelected ? 9 : 7)

            Rectangle()
                .fill(tint.opacity(moment.isPast ? 0.30 : 0.55))
                .frame(width: isSelected ? 2 : 1.2, height: Self.stalkHeight)
        }
        .offset(x: -4, y: Self.stalkTop - 8)
    }

    // MARK: Durate

    /// Le barre dei periodi, dentro l'asse.
    ///
    /// Dentro e non sopra: un periodo non è un avvenimento che sta *in* un
    /// momento, è un pezzo di giornata che è stato in un certo modo — e la
    /// giornata è l'asse. Metterle su una corsia propria le farebbe sembrare
    /// una terza categoria di cose accanto alle altre due, mentre sono lo
    /// sfondo su cui le altre due succedono. Costa anche zero altezza, che su
    /// questa fascia è l'unica valuta che conta.
    @ViewBuilder
    private func spanBars(width: CGFloat) -> some View {
        let placed = Self.assignLanes(spans, now: now)
        ForEach(placed, id: \.span.id) { item in
            let x0 = fraction(of: item.span.start) * width
            let x1 = fraction(of: item.span.end ?? now) * width
            let barWidth = max(x1 - x0, 3)
            let isSelected = selectedSpanID == item.span.id
            let tint = Self.spanTint(for: item.span)

            Capsule()
                .fill(tint.opacity(item.span.isRunning ? 0.95 : 0.70))
                .overlay {
                    // Un filo di bordo chiaro: la barra vive dentro la banda
                    // del giorno, che a mezzogiorno è quasi bianca e a
                    // mezzanotte quasi nera. Senza, su uno dei due estremi
                    // sparirebbe nello sfondo.
                    Capsule().strokeBorder(.white.opacity(isSelected ? 0.9 : 0.35), lineWidth: 0.5)
                }
                .overlay(alignment: .leading) { spanContent(item.span, barWidth: barWidth) }
                .frame(width: barWidth, height: Self.spanLaneHeight)
                // Il bersaglio è alto quanto il passo fra due corsie: qualche
                // punto in più della barra, ma non abbastanza da invadere la
                // corsia vicina. Allargarlo di più sembrerebbe generoso e
                // sarebbe il contrario, perché due corsie adiacenti sono
                // adiacenti proprio quando si sovrappongono nel tempo: il
                // bersaglio grande di una ruberebbe i tocchi all'altra.
                .frame(height: Self.spanLaneHeight + Self.spanLaneGap)
                // **Prima** di `position`, non dopo.
                //
                // `position` espande la vista a tutto lo spazio disponibile e
                // ci colloca dentro il contenuto: una `contentShape` applicata
                // dopo descrive quello spazio, non la barra. Ogni barra aveva
                // così come area di tocco l'intero nastro, e a vincere era
                // sempre la stessa — toccandone una qualunque si apriva la
                // scheda di quell'unica. Gli altri elementi funzionavano per
                // caso: senza `contentShape` il tocco segue il disegno, che è
                // già la forma giusta.
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
        }
    }

    /// Il nome del periodo scelto, dove vivono le etichette.
    ///
    /// Fuori dalla barra e non dentro: le righe sono alte sei punti, e un testo
    /// lì dentro andrebbe a sette punti e troncato a metà parola — «Purificatore
    /// Stu» non è un nome, è un rumore con la forma di un nome. Solo il
    /// selezionato, perché tre nomi insieme sono di nuovo il problema da cui si
    /// veniva.
    private func spanReadout(_ span: DaySpan, width: CGFloat) -> some View {
        let x0 = fraction(of: span.start) * width
        let x1 = fraction(of: span.end ?? now) * width
        // Solo per le barre strette: su quelle larghe il nome è già dentro, e
        // scriverlo due volte sarebbe solo più inchiostro per la stessa cosa.
        return Text(x1 - x0 > 64 ? "" : span.name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Self.spanTint(for: span))
            .lineLimit(1)
            .fixedSize()
            .position(x: min(max((x0 + x1) / 2, 40), width - 40),
                      y: Self.axisY - 7)
    }

    /// Cosa c'è scritto dentro una barra: un'icona, e il nome se ci sta.
    ///
    /// L'icona per prima perché sopravvive a qualunque larghezza e si legge da
    /// lontano, che è la distanza da cui si guarda un pannello al muro. Il nome
    /// entra solo quando può entrare **intero**: un nome troncato a metà parola
    /// non è un nome corto, è una promessa non mantenuta, e ne avevamo già
    /// visto l'effetto con «Purificatore Stu».
    @ViewBuilder
    private func spanContent(_ span: DaySpan, barWidth: CGFloat) -> some View {
        let icon = Self.spanSymbol(for: span)
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 6, weight: .bold))
            if barWidth > 64 {
                Text(span.name)
                    .font(.system(size: 7, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.leading, 4)
        .frame(width: max(barWidth - 6, 0), alignment: .leading)
        .allowsHitTesting(false)
    }

    /// Il simbolo del processo, lo stesso che l'accessorio porta altrove.
    nonisolated static func spanSymbol(for span: DaySpan) -> String {
        switch AccessoryEventType(rawValue: span.eventType) {
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
        case .airPurifier, .fan: return Color(hue: 0.52, saturation: 0.45, brightness: 0.62)
        case .humidifier:        return Color(hue: 0.58, saturation: 0.42, brightness: 0.60)
        default:                 return Color(hue: 0.72, saturation: 0.34, brightness: 0.60)
        }
    }

    // MARK: Gesti

    /// Un rombo per ogni gesto, grande quanto il gesto è stato ampio.
    ///
    /// Rombo e non cerchio: la differenza di forma è l'unico modo per cui la
    /// corsia si legge anche coprendo metà del nastro con una mano, e non
    /// dipende dal colore — che qui deve restare libero di significare
    /// dell'altro. La dimensione segue il numero di comandi perché «ho spento
    /// una luce» e «ho sistemato tutto il piano» non sono lo stesso gesto, e
    /// l'unica differenza che si può mostrare senza etichette è quanto spazio
    /// occupano.
    private func diamond(_ placement: GesturePlacement, width: CGFloat) -> some View {
        let gesture = placement.gesture
        let isSelected = selectedGestureID == gesture.id
        let side = Self.diamondSide(changeCount: gesture.changes.count) + (isSelected ? 3 : 0)

        return Rectangle()
            // Una scena è vuota come le automazioni passate sopra l'asse: non
            // l'ha fatta una mano, e la stessa distinzione di forma che lassù
            // separa il previsto dal fatto, qui separa ciò che ha premuto
            // qualcuno da ciò che ha eseguito la casa.
            .fill(gesture.isScene ? Color.clear : Self.gestureTint.opacity(isSelected ? 1 : 0.75))
            .overlay {
                if gesture.isScene {
                    Rectangle().strokeBorder(Self.gestureTint.opacity(isSelected ? 1 : 0.8),
                                             lineWidth: 1.5)
                }
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
            .overlay {
                if isSelected {
                    Rectangle()
                        .strokeBorder(Self.gestureTint, lineWidth: 1)
                        .frame(width: side + 6, height: side + 6)
                        .rotationEffect(.degrees(45))
                }
            }
            // Il bersaglio del dito è sempre più grande del rombo: un rombo da
            // sette punti è leggibile ma non toccabile, e ridurre il disegno a
            // ciò che le dita richiedono farebbe della corsia una fila di
            // bolloni.
            .frame(width: 30, height: 26)
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
        return VStack(spacing: 1) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(BrandColor.primary)
            Rectangle()
                .fill(BrandColor.primary)
                .frame(width: 2, height: Self.axisY + Self.axisHeight - Self.labelRowHeight)
        }
        .position(x: min(max(x, 18), width - 18), y: (Self.axisY + Self.axisHeight) / 2 + 4)
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
        let canGoBack: Bool
        let canGoForward: Bool
        var onShiftDay: ((Int) -> Void)? = nil
        var onReturnToday: (() -> Void)? = nil

        var body: some View {
            HStack(spacing: 6) {
                arrow("chevron.left", enabled: canGoBack) { onShiftDay?(-1) }
                Spacer(minLength: 0)
                label
                Spacer(minLength: 0)
                arrow("chevron.right", enabled: canGoForward) { onShiftDay?(1) }
            }
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

        private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    // Disabilitata si vede ancora, sbiadita: sparire
                    // cambierebbe la larghezza della barra e farebbe ballare
                    // la data ogni volta che si tocca un limite.
                    .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 30, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
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
