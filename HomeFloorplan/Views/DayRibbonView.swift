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

    /// Chi riceve la selezione. Il nastro non sa cosa farne: se ne occupa chi
    /// lo ospita, che è l'unico a sapere se c'è un pannello dove metterla.
    /// A quanti giorni da oggi siamo, e fin dove ci si può spingere.
    var dayOffset: Int = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    var onSelect: ((DayMoment) -> Void)? = nil
    var onSelectGesture: ((HumanGesture) -> Void)? = nil
    var onShiftDay: ((Int) -> Void)? = nil
    var onReturnToday: (() -> Void)? = nil

    @State private var selected: DayMoment?
    @State private var selectedGestureID: String?

    // MARK: Geometria

    private var span: TimeInterval { max(day.duration, 1) }
    private func fraction(of instant: Date) -> CGFloat {
        CGFloat(min(max(instant.timeIntervalSince(day.start) / span, 0), 1))
    }

    private static let labelRowHeight: CGFloat = 13
    private static let labelRows = 2
    private static let stalkTop: CGFloat = labelRowHeight * CGFloat(labelRows) + 4
    private static let stalkHeight: CGFloat = 20
    private static let axisY: CGFloat = stalkTop + stalkHeight
    private static let axisHeight: CGFloat = 10
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

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let placements = Self.layout(moments, width: width, fraction: fraction)

            ZStack(alignment: .topLeading) {
                daylightBand(width: width)
                solarBoundaries(width: width)
                hourTicks(width: width)

                ForEach(placements, id: \.moment.id) { placement in
                    marker(placement, width: width)
                }

                ForEach(Self.lane(gestures, width: width, fraction: fraction), id: \.gesture.id) { placement in
                    diamond(placement, width: width)
                }

                if dayOffset == 0 {
                    nowLine(width: width)
                } else {
                    dayBadge(width: width)
                }
            }
        }
        .frame(height: Self.totalHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = nil
            selectedGestureID = nil
        }
        // Trascinare il nastro cambia giorno.
        //
        // È il gesto che il nastro chiede da solo — è un asse orizzontale, e
        // un asse orizzontale si spinge — e non costa nessuna chrome in più su
        // una superficie dove lo spazio è già tutto assegnato. La soglia è
        // generosa perché sul nastro si tocca anche: sotto i quaranta punti
        // era un tocco storto, non un trascinamento.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let backwards = value.translation.width > 0
                    if backwards, canGoBack { onShiftDay?(-1) }
                    if !backwards, canGoForward { onShiftDay?(1) }
                }
        )
    }

    /// La data, al posto dell'ora, quando non si guarda oggi.
    ///
    /// Prende esattamente il posto della linea di «adesso» perché è la stessa
    /// domanda — *quando siamo?* — e perché fuori da oggi quella linea non
    /// avrebbe dove stare: «adesso» non cade dentro un giorno che non è questo.
    ///
    /// Ed è toccabile: è l'unica via di ritorno. Senza, si può finire in una
    /// giornata di tre settimane fa senza capire come tornare — e a quel punto
    /// il nastro ha smesso di essere una finestra ed è diventato un labirinto.
    private func dayBadge(width: CGFloat) -> some View {
        Button {
            onReturnToday?()
        } label: {
            HStack(spacing: 5) {
                Text(Self.dayLabel(offset: dayOffset, day: day.start))
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(BrandColor.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(BrandColor.primary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .position(x: width / 2, y: Self.labelRowHeight)
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
