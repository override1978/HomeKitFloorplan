import Foundation
import Testing
@testable import HomeFloorplan

@Suite("DayTimeline — la giornata fonde più sorgenti")
struct DayTimelineTests {

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
    private func fire(_ name: String, _ h: Int, _ m: Int = 0,
                      conditional: Bool = false,
                      scenes: [String] = [],
                      actions: Int = 0) -> HomeKitAutomationsService.ScheduledFire {
        .init(id: "\(name)@\(h):\(m)", automationID: name, name: name, at: date(h, m),
              actionSetNames: scenes, actionCount: actions,
              isPast: false, isConditional: conditional)
    }

    @Test("Alba e tramonto entrano nella giornata come momenti a sé")
    func solarMomentsAreIncluded() throws {
        let solar = NextFireResolver.SolarTimes(todaySunrise: date(6, 58), todaySunset: date(19, 32))
        let moments = DayTimeline.build(day: day, now: date(12), automations: [], solar: solar)
        #expect(moments.count == 2)
        #expect(moments.first?.kind == .solar(.sunrise))
        #expect(moments.last?.kind == .solar(.sunset))
        #expect(moments.first?.isPast == true, "alle 12 l'alba è passata")
        #expect(moments.last?.isPast == false)
    }

    @Test("Le sorgenti si fondono in un solo ordine cronologico")
    func sourcesMergeInOrder() {
        let solar = NextFireResolver.SolarTimes(todaySunrise: date(7), todaySunset: date(19, 30))
        let moments = DayTimeline.build(
            day: day, now: date(12),
            automations: [fire("Sveglia", 7, 15), fire("Notte", 23)],
            solar: solar,
            calendarEntries: [.init(id: "e1", title: "Dentista", start: date(17), isAllDay: false)])
        #expect(moments.map(\.title) == ["Alba", "Sveglia", "Dentista", "Tramonto", "Notte"])
    }

    @Test("Un impegno di tutto il giorno si ancora all'inizio e resta presente")
    func allDayEventAnchorsAtStart() throws {
        let moments = DayTimeline.build(
            day: day, now: date(14), automations: [], solar: .init(),
            calendarEntries: [.init(id: "v", title: "Vacanza", start: date(9), isAllDay: true)])
        let moment = try #require(moments.first)
        #expect(moment.at == day.start, "senza un'ora vera si ancora al giorno")
        #expect(moment.isPast == false, "dura tutto il giorno: non è passato alle 14")
        #expect(moment.kind == .calendar(isAllDay: true))
    }

    @Test("Il sottotitolo dice le scene, o quante azioni, o tace")
    func detailFallsBackSensibly() {
        let withScenes = DayTimeline.build(day: day, now: date(12),
                                           automations: [fire("A", 8, scenes: ["Sera", "Notte"], actions: 5)],
                                           solar: .init())
        #expect(withScenes.first?.detail == "Sera · Notte")

        let withCount = DayTimeline.build(day: day, now: date(12),
                                          automations: [fire("B", 8, actions: 3)],
                                          solar: .init())
        #expect(withCount.first?.detail?.contains("3") == true)

        let silent = DayTimeline.build(day: day, now: date(12),
                                       automations: [fire("C", 8)], solar: .init())
        #expect(silent.first?.detail == nil, "meglio niente di un'etichetta che riempie e non dice")
    }

    @Test("Quel che cade fuori dalla giornata non entra")
    func outsideTheDayIsExcluded() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: date(10))!
        let moments = DayTimeline.build(
            day: day, now: date(12), automations: [], solar: .init(),
            calendarEntries: [.init(id: "x", title: "Domani", start: tomorrow, isAllDay: false)])
        #expect(moments.isEmpty)
    }

    @Test("Solo le automazioni portano l'ambiguità previsto/avvenuto")
    func onlyAutomationsAreProvisional() {
        let solar = NextFireResolver.SolarTimes(todaySunrise: date(7))
        let moments = DayTimeline.build(day: day, now: date(12),
                                        automations: [fire("A", 8)], solar: solar)
        #expect(moments.filter(\.isAutomationKind).count == 1,
                "un'alba è un fatto, non una promessa")
    }
}
