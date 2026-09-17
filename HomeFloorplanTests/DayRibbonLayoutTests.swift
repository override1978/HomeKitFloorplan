import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("DayRibbonLayoutEngine — le etichette non si accavallano")
struct DayRibbonLayoutTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func date(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: h, minute: m))!
    }
    private var day: DateInterval {
        DateInterval(start: date(0), end: cal.date(byAdding: .day, value: 1, to: date(0))!)
    }
    private func moment(_ title: String, _ h: Int, _ m: Int = 0, past: Bool = false) -> DayMoment {
        DayMoment(id: "\(title)-\(h):\(m)", at: date(h, m), title: title,
                  detail: nil, kind: .automation(isConditional: false), isPast: past)
    }
    private func fraction(_ instant: Date) -> CGFloat {
        CGFloat(instant.timeIntervalSince(day.start) / day.duration)
    }

    @Test("Momenti ben distanziati ricevono tutti un'etichetta, tutti sulla prima riga")
    func spacedMomentsAllLabelled() {
        let placements = DayRibbonLayoutEngine.layout(
            [moment("A", 2), moment("B", 9), moment("C", 16), moment("D", 22)],
            width: 900, fraction: fraction)
        #expect(placements.allSatisfy { $0.labelWidth != nil })
        #expect(placements.allSatisfy { $0.level == 0 })
    }

    @Test("Due momenti vicini si sfalsano su due righe invece di sovrapporsi")
    func closeMomentsStagger() {
        let placements = DayRibbonLayoutEngine.layout(
            [moment("Alba", 7, 2), moment("Sveglia", 7, 15)],
            width: 900, fraction: fraction)
        #expect(Set(placements.map(\.level)) == [0, 1],
                "sulla stessa riga si coprirebbero")
    }

    @Test("In un grappolo troppo fitto qualcuno rinuncia all'etichetta")
    func denseClusterDropsLabels() {
        let cluster = [moment("A", 19, 30), moment("B", 19, 35),
                       moment("C", 19, 40), moment("D", 19, 45)]
        let placements = DayRibbonLayoutEngine.layout(cluster, width: 900, fraction: fraction)
        #expect(placements.contains { $0.labelWidth == nil },
                "due etichette accavallate costano più di nessuna")
        #expect(placements.contains { $0.labelWidth != nil },
                "ma non devono sparire tutte")
    }

    @Test("L'etichetta non invade il vicino sulla stessa riga")
    func labelStopsBeforeNeighbour() throws {
        let placements = DayRibbonLayoutEngine.layout(
            [moment("Primo", 10), moment("Secondo", 13)],
            width: 900, fraction: fraction)
        let first = try #require(placements.first)
        let second = try #require(placements.last)
        if first.level == second.level, let w = first.labelWidth {
            #expect(first.x + w <= second.x, "si fermerebbe dentro il vicino")
        }
    }

    @Test("L'ordine di uscita è cronologico anche se l'ingresso non lo è")
    func outputIsChronological() {
        let placements = DayRibbonLayoutEngine.layout(
            [moment("Sera", 22), moment("Mattino", 7), moment("Pranzo", 13)],
            width: 900, fraction: fraction)
        #expect(placements.map(\.moment.title) == ["Mattino", "Pranzo", "Sera"])
    }

    @Test("Su una larghezza minuscola nessuna etichetta viene inventata")
    func tinyWidthYieldsNoLabels() {
        let placements = DayRibbonLayoutEngine.layout(
            [moment("A", 8), moment("B", 9), moment("C", 10)],
            width: 60, fraction: fraction)
        #expect(placements.allSatisfy { $0.labelWidth == nil },
                "meglio tre punti muti di tre etichette illeggibili")
    }
}

// MARK: - Titolo sull'asse

@MainActor
@Suite("DayRibbonLayoutEngine — l'etichetta comincia da ciò che distingue")
struct DayRibbonTitleTests {

    private func automation(_ title: String) -> DayMoment {
        DayMoment(id: title, at: Date(), title: title, detail: nil,
                  kind: .automation(isConditional: false), isPast: false)
    }
    private func short(_ title: String) -> String {
        DayRibbonView.ribbonTitle(for: automation(title))
    }

    @Test("Via l'orario, resta l'azione")
    func dropsLeadingTime() {
        #expect(short("Alle 07:30 Sveglia Lavoro") == "Sveglia Lavoro")
        #expect(short("22:00 Attivo Antifurto") == "Attivo Antifurto")
    }

    @Test("Via anche le parole di servizio fino alla prima maiuscola")
    func dropsConnectiveWords() {
        #expect(short("Alle 09:00 di ogni giorno Attiva Purificatore") == "Attiva Purificatore")
        #expect(short("Alle 02:00 del mattino imposta la Buonanotte") == "Buonanotte",
                "su un asse è esattamente l'etichetta che serve")
    }

    @Test("Un nome già pulito non si tocca")
    func leavesCleanNameAlone() {
        #expect(short("Modalità Notturna") == "Modalità Notturna")
        #expect(short("Alfred In Settimana Aspira Mansarda") == "Alfred In Settimana Aspira Mansarda")
    }

    @Test("Senza maiuscole da cui ripartire il nome resta intero")
    func keepsAllLowercaseName() {
        #expect(short("Alle 08:00 accendi la luce") == "accendi la luce")
        #expect(short("spegni tutto") == "spegni tutto",
                "meglio troncato che svuotato")
    }

    @Test("I momenti che non sono automazioni restano intatti")
    func leavesOtherKindsAlone() {
        let event = DayMoment(id: "e", at: Date(), title: "Festa Morelli", detail: nil,
                              kind: .calendar(isAllDay: false), isPast: false)
        #expect(DayRibbonView.ribbonTitle(for: event) == "Festa Morelli")

        let dawn = DayMoment(id: "s", at: Date(), title: "Alba", detail: nil,
                             kind: .solar(.sunrise), isPast: true)
        #expect(DayRibbonView.ribbonTitle(for: dawn) == "Alba")
    }
}
