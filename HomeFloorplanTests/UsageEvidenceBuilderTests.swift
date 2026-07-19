import Foundation
import Testing
@testable import HomeFloorplan

/// Test del nuovo estrattore di evidenze d'uso (pivot "da giudice a testimone").
@Suite("UsageEvidenceBuilder — evidenze d'uso senza gate di confidenza")
struct UsageEvidenceBuilderTests {

    private let cal = Calendar(identifier: .gregorian)

    /// Evento alle `hour:minute` di `daysAgo` giorni fa rispetto a un lunedì fisso.
    private func event(_ accessory: UUID, name: String = "Luce",
                       daysAgo: Int, hour: Int, minute: Int = 0,
                       state: Bool = true) -> UsageEvidenceBuilder.EventSample {
        // Lunedì 2 giugno 2025 come ancora deterministica.
        let anchor = cal.date(from: DateComponents(year: 2025, month: 6, day: 2, hour: hour, minute: minute))!
        let ts = cal.date(byAdding: .day, value: -daysAgo, to: anchor)!
        return .init(accessoryID: accessory, accessoryName: name, roomName: "Salotto",
                     eventType: "light", state: state, timestamp: ts)
    }

    @Test("Accensioni ricorrenti alla stessa ora producono un'evidenza con finestra giusta")
    func recurringOnEventsProduceEvidence() {
        let a = UUID()
        // 6 sere feriali alle ~19:30 su 2 settimane
        let events = [0, 1, 2, 3, 4, 7].map { event(a, daysAgo: $0, hour: 19, minute: 30) }
        let out = UsageEvidenceBuilder.build(from: events)
        #expect(out.count == 1)
        let e = out[0]
        #expect(e.distinctDays == 6)
        #expect(e.occurrences == 6)
        #expect(e.windowStartMinute <= 19 * 60 + 30)
        #expect(e.windowEndMinute > 19 * 60 + 30)
    }

    @Test("Meno giorni distinti del minimo: nessuna evidenza")
    func belowMinDaysProducesNothing() {
        let a = UUID()
        let events = [0, 1, 2].map { event(a, daysAgo: $0, hour: 8) } // 3 < 4 default
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Gli spegnimenti (state=false) sono ignorati")
    func offEventsIgnored() {
        let a = UUID()
        let events = [0, 1, 2, 3, 4].map { event(a, daysAgo: $0, hour: 22, state: false) }
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Eventi sparsi a caso nel giorno non concentrano una finestra")
    func scatteredEventsProduceNothing() {
        let a = UUID()
        // 6 giorni ma orari sparsi (finestra 60' non ne cattura ≥4 in giorni distinti)
        let hours = [1, 5, 9, 13, 17, 21]
        let events = hours.enumerated().map { i, h in event(a, daysAgo: i, hour: h) }
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Solo giorni feriali → pattern .weekdays")
    func weekdayDominance() {
        let a = UUID()
        // daysAgo 0..4 dal lunedì = lun,dom?? — ancora: lun 2 giu; daysAgo 0=lun,1=dom,2=sab,3=ven,4=gio
        // Uso daysAgo 0,3,4,7,10,11 → lun,ven,gio,lun,mar? calcolo: scelgo espliciti feriali
        let feriali = [0, 3, 4, 7, 10]  // lun, ven, gio, lun(prec), mer? — tutti non-weekend tranne verifica sotto
        let events = feriali.map { event(a, daysAgo: $0, hour: 7, minute: 15) }
        let out = UsageEvidenceBuilder.build(from: events)
        #expect(out.count == 1)
        // Con l'ancora lunedì: daysAgo 1=domenica e 2=sabato sono esclusi → dominanza feriale
        #expect(out[0].weekdayPattern == .weekdays)
    }

    @Test("Eventi originati dall'app/engine sono esclusi")
    func appOriginatedEventsExcluded() {
        let a = UUID()
        let events = (0..<6).map { d -> UsageEvidenceBuilder.EventSample in
            let base = event(a, daysAgo: d, hour: 21)
            return .init(accessoryID: base.accessoryID, accessoryName: base.accessoryName,
                         roomName: base.roomName, eventType: base.eventType,
                         state: true, timestamp: base.timestamp, origin: "app")
        }
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Sensori contatto/movimento sono esclusi (non azionabili)")
    func sensorTypesExcluded() {
        let a = UUID()
        let events = (0..<6).map { d -> UsageEvidenceBuilder.EventSample in
            let base = event(a, name: "Finestra", daysAgo: d, hour: 23)
            return .init(accessoryID: base.accessoryID, accessoryName: base.accessoryName,
                         roomName: base.roomName, eventType: "contact",
                         state: true, timestamp: base.timestamp)
        }
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Eventi sincronizzati di molti accessori nello stesso minuto sono scartati (scene)")
    func bulkSynchronizedEventsExcluded() {
        // 5 accessori che "si accendono" tutti alle 23:00 in punto per 6 giorni:
        // è una scena serale, non 5 abitudini umane.
        let accessories = (0..<5).map { _ in UUID() }
        let events = (0..<6).flatMap { day in
            accessories.map { event($0, daysAgo: day, hour: 23, minute: 0) }
        }
        #expect(UsageEvidenceBuilder.build(from: events).isEmpty)
    }

    @Test("Accessori diversi producono evidenze separate, ordinate per forza")
    func multipleAccessoriesSortedByStrength() {
        let strong = UUID(), weak = UUID()
        let events = (0..<8).map { event(strong, name: "Forte", daysAgo: $0, hour: 20) }
            + (0..<4).map { event(weak, name: "Debole", daysAgo: $0, hour: 6) }
        let out = UsageEvidenceBuilder.build(from: events)
        #expect(out.count == 2)
        #expect(out[0].accessoryName == "Forte")
        #expect(out[0].distinctDays == 8)
        #expect(out[1].distinctDays == 4)
    }
}
