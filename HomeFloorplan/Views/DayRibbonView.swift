import SwiftUI

// MARK: - DayRibbonView

/// La giornata della casa su un asse orizzontale.
///
/// Esiste per rispondere a una domanda che un elenco non può risolvere: la
/// forma di una giornata si legge meglio in verticale o in orizzontale? In
/// colonna quindici momenti sono quindici righe da scorrere, e la distanza fra
/// le 9:00 e le 13:30 è la stessa che fra le 22:00 e le 22:30. Su un asse il
/// tempo è una lunghezza: i grappoli si addensano, i vuoti si vedono, e il
/// pomeriggio deserto diventa un fatto invece che una deduzione.
///
/// Questa è la versione che si limita a mostrare. Trascinare il tempo — e far
/// cambiare la planimetria sopra — è un'altra cosa e costa molto di più:
/// richiede di ricostruire lo stato della casa a un istante qualunque, che
/// oggi nessuno conserva. Prima conviene sapere se la forma vale il posto che
/// si prenderebbe.
struct DayRibbonView: View {

    let moments: [DayMoment]
    let day: DateInterval
    let now: Date

    @State private var selected: DayMoment?

    private var span: TimeInterval { max(day.duration, 1) }

    private func fraction(of instant: Date) -> CGFloat {
        CGFloat(min(max(instant.timeIntervalSince(day.start) / span, 0), 1))
    }

    private func color(for moment: DayMoment) -> Color {
        switch moment.kind {
        case .automation: return BrandColor.primary
        case .solar:      return .orange
        case .calendar:   return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let nowX = fraction(of: now) * width

                ZStack(alignment: .topLeading) {
                    // Le due metà della giornata: quella alle spalle e quella
                    // davanti. Distinguerle è metà del valore di un asse.
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.secondary.opacity(0.10))
                            .frame(width: nowX)
                        Rectangle().fill(BrandColor.primary.opacity(0.06))
                    }
                    .frame(height: 18)
                    .offset(y: 30)

                    hourTicks(width: width)

                    ForEach(moments) { moment in
                        let x = fraction(of: moment.at) * width
                        Button {
                            selected = (selected?.id == moment.id) ? nil : moment
                        } label: {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(color(for: moment))
                                    .frame(width: selected?.id == moment.id ? 9 : 6,
                                           height: selected?.id == moment.id ? 9 : 6)
                                Rectangle()
                                    .fill(color(for: moment).opacity(0.5))
                                    .frame(width: 1.5, height: 18)
                            }
                            .opacity(moment.isPast ? 0.45 : 1)
                            // Bersaglio generoso: i punti sono piccoli e
                            // vicini, ma toccarli deve restare facile.
                            .frame(width: 28, height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(x: x, y: 17)
                    }

                    // Adesso: l'unica linea che attraversa tutto.
                    Rectangle()
                        .fill(BrandColor.primary)
                        .frame(width: 2, height: 44)
                        .position(x: nowX, y: 22)
                }
            }
            .frame(height: 56)

            caption
        }
    }

    private func hourTicks(width: CGFloat) -> some View {
        ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
            let x = (CGFloat(hour) / 24) * width
            VStack(spacing: 2) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1, height: 6)
                Text(String(format: "%02d", hour % 24))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .position(x: min(max(x, 8), width - 8), y: 52)
        }
    }

    /// Sotto l'asse: il momento scelto, oppure quello che sta per arrivare.
    ///
    /// Un asse pieno di punti senza etichette è un grafico, non una scaletta.
    /// Mostrarle tutte lo renderebbe illeggibile, quindi ne compare una sola —
    /// e in assenza di scelta è il prossimo, che è la domanda più probabile.
    @ViewBuilder
    private var caption: some View {
        let shown = selected ?? moments.first { !$0.isPast }
        HStack(spacing: 6) {
            if let shown {
                Image(systemName: shown.symbolName)
                    .font(.caption2)
                    .foregroundStyle(color(for: shown))
                Text(shown.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                Text(shown.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if selected == nil {
                    Text(String(localized: "day.ribbon.next", defaultValue: "il prossimo"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(String(localized: "day.ribbon.done",
                            defaultValue: "Per oggi non è previsto altro."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }
}
