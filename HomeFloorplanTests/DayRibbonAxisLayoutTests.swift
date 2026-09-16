import Testing
import Foundation
@testable import HomeFloorplan

/// I momenti sull'asse: raggruppati dove si toccano, nominati dove conta.
@Suite("La disposizione dei momenti")
struct DayRibbonAxisLayoutTests {

    private let day = DateInterval(start: Date(timeIntervalSinceReferenceDate: 0),
                                   duration: 24 * 3600)
    private let width: CGFloat = 1900

    private func fraction(_ instant: Date) -> CGFloat {
        CGFloat(min(max(instant.timeIntervalSince(day.start) / day.duration, 0), 1))
    }

    private func at(_ hour: Double) -> Date { day.start.addingTimeInterval(hour * 3600) }

    private func moment(_ hour: Double, _ title: String = "Automazione") -> DayMoment {
        DayMoment(id: "\(hour)-\(title)", at: at(hour), title: title, detail: nil,
                  kind: .automation(isConditional: false), isPast: false)
    }

    private func layout(_ moments: [DayMoment], now: Date) -> [DayRibbonView.AxisPlacement] {
        DayRibbonView.axisLayout(moments, now: now, width: width, fraction: fraction)
    }

    // MARK: I grappoli

    @Test("Momenti lontani restano punti distinti")
    func farApartStayDistinct() {
        let placements = layout([moment(3), moment(9), moment(15)], now: at(12))
        #expect(placements.count == 3)
        #expect(placements.allSatisfy { $0.count == 1 })
    }

    @Test("Momenti troppo vicini diventano un punto solo, che dice quanti sono")
    func nearbyMomentsCluster() {
        // Tre minuti su ventiquattr'ore larghe 1900 punti sono quattro punti:
        // tre cerchi da dieci punti lì sopra sembrano uno solo.
        //
        // La distanza si misura dall'**ancora** del grappolo e non dall'ultimo
        // entrato, o una catena di punti appena separati si fonderebbe tutta:
        // ciò che conta è se il cerchio disegnato copre il prossimo, e quel
        // cerchio sta sull'ancora.
        let placements = layout([moment(9), moment(9.05), moment(9.1)], now: at(12))
        #expect(placements.count == 1)
        #expect(placements[0].count == 3)
    }

    @Test("Il rappresentante del grappolo è il primo in ordine di tempo")
    func clusterKeepsTheEarliest() {
        let placements = layout([moment(9, "Primo"), moment(9.1, "Secondo")], now: at(12))
        #expect(placements[0].moment.title == "Primo")
    }

    @Test("Su un asse più largo gli stessi momenti si separano")
    func widerAxisSeparates() {
        let moments = [moment(9), moment(9.05)]
        let narrow = DayRibbonView.axisLayout(moments, now: at(12), width: 600, fraction: fraction)
        let wide = DayRibbonView.axisLayout(moments, now: at(12), width: 9000, fraction: fraction)
        #expect(narrow.count == 1)
        #expect(wide.count == 2)
    }

    // MARK: I nomi

    @Test("I nomi stanno attorno ad adesso, non ovunque")
    func labelsClusterAroundNow() {
        // Il difetto da cui si viene: o tutti etichettati, e si accavallano, o
        // nessuno, e restano dieci cerchi identici. La domanda non è se
        // nominarli ma quali.
        let moments = (0..<12).map { moment(Double($0) * 2) }
        let placements = layout(moments, now: at(12))
        let labelled = placements.filter { $0.labelWidth != nil }
        #expect(labelled.count >= 2)
        #expect(labelled.count <= DayRibbonView.labelledPast + DayRibbonView.labelledFuture)
        // E cadono attorno a mezzogiorno, non alle sette del mattino.
        #expect(labelled.allSatisfy { abs($0.moment.at.timeIntervalSince(at(12))) < 8 * 3600 })
    }

    @Test("Il nome va anche a ciò che è appena passato, non solo al futuro")
    func pastNearNowIsNamedToo() {
        let moments = (0..<12).map { moment(Double($0) * 2) }
        let placements = layout(moments, now: at(12))
        let labelled = placements.filter { $0.labelWidth != nil }
        #expect(labelled.contains { $0.moment.at <= at(12) }, "cosa è appena successo conta")
        #expect(labelled.contains { $0.moment.at > at(12) }, "e anche cosa sta per succedere")
    }

    @Test("A fine giornata i nomi restano sugli ultimi, senza sforare")
    func lateDayDoesNotOverrun() {
        let moments = (0..<8).map { moment(Double($0) * 3) }
        let placements = layout(moments, now: at(23.5))
        let labelled = placements.filter { $0.labelWidth != nil }
        #expect(labelled.isEmpty == false)
        #expect(labelled.allSatisfy { $0.moment.at <= at(23.5) })
    }

    @Test("Due nomi sulla stessa riga non si sovrappongono mai")
    func labelsNeverOverlap() {
        let moments = (0..<10).map { moment(11 + Double($0) * 0.4) }
        let placements = layout(moments, now: at(12))
        let labelled = placements.filter { $0.labelWidth != nil }.sorted { $0.x < $1.x }
        for pair in zip(labelled, labelled.dropFirst()) where pair.0.level == pair.1.level {
            #expect(pair.0.x + (pair.0.labelWidth ?? 0) <= pair.1.x + 0.5,
                    "un nome invade il successivo sulla stessa riga")
        }
    }

    @Test("Un'etichetta troppo stretta non si disegna affatto")
    func tooNarrowMeansNoLabel() {
        // Tre caratteri e un puntino non sono un nome corto: sono rumore con
        // l'aria di un'informazione.
        let placements = layout([moment(12), moment(12.35)], now: at(12))
        for placement in placements {
            if let labelWidth = placement.labelWidth {
                #expect(labelWidth >= DayRibbonView.minLabelWidth)
            }
        }
    }

    @Test("Nessun momento, nessuna disposizione")
    func emptyInput() {
        #expect(layout([], now: at(12)).isEmpty)
    }

    @Test("L'ordine di ingresso non cambia il risultato")
    func inputOrderDoesNotMatter() {
        let moments = [moment(3), moment(9), moment(15)]
        #expect(layout(moments, now: at(12)) == layout(moments.reversed(), now: at(12)))
    }
}
