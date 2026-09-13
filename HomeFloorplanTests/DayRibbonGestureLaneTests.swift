import Testing
import Foundation
@testable import HomeFloorplan

/// La corsia dei gesti: fusione visiva e dimensione dei rombi.
///
/// Le regole di raggruppamento vere stanno in `HumanGestureBuilderTests` e
/// ragionano in minuti. Qui si prova l'altra metà del problema: due gesti
/// distinti nel tempo possono comunque cadere sullo stesso punto dello schermo,
/// e in quel caso devono diventare un bersaglio solo.
@Suite("Corsia dei gesti")
struct DayRibbonGestureLaneTests {

    private let day = DateInterval(start: Date(timeIntervalSinceReferenceDate: 0),
                                   duration: 24 * 3600)

    private func fraction(_ instant: Date) -> CGFloat {
        CGFloat(min(max(instant.timeIntervalSince(day.start) / day.duration, 0), 1))
    }

    private func gesture(atHour hour: Double, minute: Double = 0, changes: Int = 1) -> HumanGesture {
        let at = day.start.addingTimeInterval(hour * 3600 + minute * 60)
        let list = (0..<changes).map { index in
            HumanGesture.Change(id: "c\(hour)-\(index)",
                                accessoryUUID: UUID(),
                                accessoryName: "Luce \(index)",
                                roomName: "Soggiorno",
                                state: true,
                                brightness: nil,
                                eventType: "light",
                                at: at)
        }
        return HumanGesture(id: "g\(hour)-\(minute)", at: at, changes: list)
    }

    @Test("Gesti lontani restano distinti")
    func farApartStayDistinct() {
        let placements = DayRibbonView.lane([gesture(atHour: 8), gesture(atHour: 20)],
                                            width: 800, fraction: fraction)
        #expect(placements.count == 2)
        #expect(placements[0].x < placements[1].x)
    }

    @Test("Gesti troppo vicini sullo schermo diventano un bersaglio solo")
    func nearbyGesturesMerge() {
        // Dieci minuti su 24 ore larghe 800 punti sono ~5,5 punti: oltre la
        // finestra di raggruppamento del builder, ben sotto un dito.
        let placements = DayRibbonView.lane([gesture(atHour: 8),
                                             gesture(atHour: 8, minute: 10)],
                                            width: 800, fraction: fraction)
        #expect(placements.count == 1)
        #expect(placements[0].gesture.changes.count == 2)
    }

    @Test("La fusione tiene l'ora del primo gesto")
    func mergeKeepsEarliestInstant() {
        let first = gesture(atHour: 8)
        let placements = DayRibbonView.lane([first, gesture(atHour: 8, minute: 10)],
                                            width: 800, fraction: fraction)
        #expect(placements[0].gesture.at == first.at)
    }

    @Test("Su un nastro largo gli stessi gesti si separano")
    func widerRibbonSeparates() {
        let gestures = [gesture(atHour: 8), gesture(atHour: 8, minute: 10)]
        let narrow = DayRibbonView.lane(gestures, width: 800, fraction: fraction)
        let wide   = DayRibbonView.lane(gestures, width: 4_000, fraction: fraction)
        #expect(narrow.count == 1)
        #expect(wide.count == 2)
    }

    @Test("Nessun gesto, nessun rombo")
    func emptyLane() {
        #expect(DayRibbonView.lane([], width: 800, fraction: fraction).isEmpty)
    }

    @Test("Il rombo cresce coi comandi, ma si ferma")
    func diamondGrowsAndStops() {
        let one   = DayRibbonView.diamondSide(changeCount: 1)
        let three = DayRibbonView.diamondSide(changeCount: 3)
        let many  = DayRibbonView.diamondSide(changeCount: 40)
        #expect(one < three)
        #expect(three < many)
        #expect(many <= 13)
    }

    @Test("Un gesto fuso raccoglie l'ultimo stato di ogni accessorio")
    func mergeCollapsesPerAccessory() {
        let uuid = UUID()
        func change(on: Bool, at offset: TimeInterval) -> HumanGesture.Change {
            HumanGesture.Change(id: "\(offset)", accessoryUUID: uuid, accessoryName: "Lampada",
                                roomName: "Studio", state: on, brightness: nil,
                                eventType: "light", at: day.start.addingTimeInterval(offset))
        }
        let a = HumanGesture(id: "a", at: day.start, changes: [change(on: true, at: 0)])
        let b = HumanGesture(id: "b", at: day.start.addingTimeInterval(600),
                             changes: [change(on: false, at: 600)])
        let merged = HumanGestureBuilder.merge([a, b])
        #expect(merged.changes.count == 1)
        #expect(merged.changes[0].state == false)
        #expect(merged.at == day.start)
    }

    @Test("Il nome proposto dice quando e dove")
    func suggestedNameSaysWhenAndWhere() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 13
        components.hour = 20; components.minute = 30
        let evening = Calendar.current.date(from: components)!
        let gesture = HumanGesture(id: "g", at: evening, changes: [
            HumanGesture.Change(id: "c", accessoryUUID: UUID(), accessoryName: "Piantana",
                                roomName: "Soggiorno", state: true, brightness: nil,
                                eventType: "light", at: evening)
        ])
        let name = HumanGestureBuilder.suggestedName(for: gesture)
        #expect(name.contains("Soggiorno"))
        #expect(name.contains("Sera"))
    }

    @Test("Senza stanza il nome resta solo il momento")
    func suggestedNameWithoutRoom() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 13
        components.hour = 3; components.minute = 0
        let night = Calendar.current.date(from: components)!
        let gesture = HumanGesture(id: "g", at: night, changes: [
            HumanGesture.Change(id: "c", accessoryUUID: UUID(), accessoryName: "Presa",
                                roomName: nil, state: false, brightness: nil,
                                eventType: "outlet", at: night)
        ])
        #expect(HumanGestureBuilder.suggestedName(for: gesture) == "Notte")
    }

    @Test("Il titolo breve nomina le stanze toccate")
    func shortTitleNamesRooms() {
        let at = day.start
        func change(_ room: String?) -> HumanGesture.Change {
            HumanGesture.Change(id: room ?? "-", accessoryUUID: UUID(), accessoryName: "X",
                                roomName: room, state: true, brightness: nil,
                                eventType: "light", at: at)
        }
        #expect(HumanGesture(id: "1", at: at, changes: [change("Cucina")]).shortTitle == "Cucina")
        #expect(HumanGesture(id: "2", at: at,
                             changes: [change("Cucina"), change("Sala")]).shortTitle == "Cucina, Sala")
        let three = HumanGesture(id: "3", at: at,
                                 changes: [change("Cucina"), change("Sala"), change("Studio")])
        #expect(three.shortTitle.contains("Cucina"))
        #expect(three.shortTitle.contains("2"))
    }
}
