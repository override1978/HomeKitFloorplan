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

    @State private var selected: DayMoment?

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
    private static let totalHeight: CGFloat = axisY + axisHeight + 14

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

                nowLine(width: width)
            }
        }
        .frame(height: Self.totalHeight)
        .contentShape(Rectangle())
        .onTapGesture { selected = nil }
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
                          y: Self.axisY + Self.axisHeight + 8)
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
        .onTapGesture { selected = isSelected ? nil : moment }
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
        let maxLabelWidth: CGFloat = 88
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
