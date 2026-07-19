import Foundation
import Testing
@testable import HomeFloorplan

/// Test del core puro del livello B (interprete LLM delle abitudini).
@Suite("HabitInterpreterCore — riassunto uso e parsing risposta")
struct HabitInterpreterCoreTests {

    private func sample(_ name: String, id: UUID, minutesAgo: Int,
                        origin: String = "external",
                        state: Bool = true) -> UsageEvidenceBuilder.EventSample {
        .init(accessoryID: id, accessoryName: name, roomName: "Salotto",
              eventType: "light", state: state,
              timestamp: Date(timeIntervalSince1970: 1_750_000_000 - Double(minutesAgo * 60)),
              origin: origin)
    }

    @Test("Il riassunto contiene istogramma per accessorio e conteggio accensioni")
    func summaryContainsHistogram() {
        let a = UUID()
        let events = (0..<5).map { sample("Lampada", id: a, minutesAgo: $0 * 1440) }
        let summary = HabitInterpreterCore.buildUsageSummary(events: events, existingAutomations: [])
        #expect(summary.contains("Lampada"))
        #expect(summary.contains("on×5"))
    }

    @Test("Con eventi external presenti, gli eventi app sono esclusi dal riassunto")
    func externalPreferredOverApp() {
        let a = UUID(), b = UUID()
        let events = (0..<3).map { sample("Manuale", id: a, minutesAgo: $0 * 1440) }
            + (0..<10).map { sample("Engine", id: b, minutesAgo: $0 * 720, origin: "app") }
        let summary = HabitInterpreterCore.buildUsageSummary(events: events, existingAutomations: [])
        #expect(summary.contains("Manuale"))
        #expect(!summary.contains("Engine"))
    }

    @Test("Le sequenze A→B entro 2 minuti compaiono se ripetute almeno 3 volte")
    func sequencesDetected() {
        let a = UUID(), b = UUID()
        var events: [UsageEvidenceBuilder.EventSample] = []
        for day in 0..<4 {
            events.append(sample("Proiettore", id: a, minutesAgo: day * 1440))
            events.append(sample("Ambilight", id: b, minutesAgo: day * 1440 - 1)) // 1 min dopo
        }
        let summary = HabitInterpreterCore.buildUsageSummary(events: events, existingAutomations: [])
        #expect(summary.contains("Proiettore -> Ambilight"))
    }

    @Test("Gesto manuale dopo un gruppo automatizzato: annotato come gap, gruppo etichettato")
    func gapAfterAutomatedGroupIsAnnotated() {
        // Scena serale: 4 accessori nello stesso minuto, per 5 giorni.
        let sceneAccessories = (0..<4).map { _ in UUID() }
        let manual = UUID()
        var events: [UsageEvidenceBuilder.EventSample] = []
        for day in 0..<5 {
            let base = day * 1440
            for (i, id) in sceneAccessories.enumerated() {
                events.append(sample("Scena\(i)", id: id, minutesAgo: base))
            }
            // Gesto manuale 2 minuti DOPO il gruppo (minutesAgo minore = più tardi).
            events.append(sample("Presa Divano", id: manual, minutesAgo: base - 2))
        }
        let summary = HabitInterpreterCore.buildUsageSummary(events: events, existingAutomations: [])
        #expect(summary.contains("RESIDUAL MANUAL ACTIONS"))
        #expect(summary.contains("Presa Divano"))
        #expect(summary.contains("AFTER an automated group"))
        #expect(summary.contains("AUTOMATED GROUPS already firing"))
        // Gli accessori della scena NON devono comparire tra i gesti manuali.
        let manualSection = summary.components(separatedBy: "AUTOMATED GROUPS").first ?? ""
        #expect(!manualSection.contains("Scena0"))
    }

    @Test("Le automazioni esistenti sono elencate nel riassunto")
    func existingAutomationsListed() {
        let summary = HabitInterpreterCore.buildUsageSummary(
            events: [sample("Luce", id: UUID(), minutesAgo: 0)],
            existingAutomations: ["Buonanotte 23:00"]
        )
        #expect(summary.contains("Buonanotte 23:00"))
    }

    @Test("Parsing: array JSON pulito")
    func parseCleanArray() {
        let json = """
        [{"title":"Sera","explanation":"vista alle 19","triggerType":"calendar",\
        "triggerTime":"19:30","weekdays":[2,3,4,5,6],"triggerAccessoryName":null,\
        "targetAccessoryName":"Lampada","additionalTargetNames":["Treppiede","Parentesi"],\
        "action":"on"}]
        """
        let out = HabitInterpreterCore.parseSuggestions(json)
        #expect(out.count == 1)
        #expect(out[0].targetAccessoryName == "Lampada")
        #expect(out[0].triggerTime == "19:30")
        #expect(out[0].additionalTargetNames == ["Treppiede", "Parentesi"])
    }

    @Test("Parsing: tollera code fence e testo attorno; scarta azioni non valide")
    func parseTolerantAndValidating() {
        let response = """
        Ecco le proposte:
        ```json
        [{"title":"A","explanation":"e","triggerType":"calendar","triggerTime":"08:00",
          "weekdays":null,"triggerAccessoryName":null,"targetAccessoryName":"Caffè","action":"on"},
         {"title":"B","explanation":"e","triggerType":"calendar","triggerTime":"09:00",
          "weekdays":null,"triggerAccessoryName":null,"targetAccessoryName":"X","action":"esplodi"}]
        ```
        """
        let out = HabitInterpreterCore.parseSuggestions(response)
        #expect(out.count == 1)
        #expect(out[0].targetAccessoryName == "Caffè")
    }

    @Test("Parsing: risposta senza JSON valido → lista vuota")
    func parseGarbage() {
        #expect(HabitInterpreterCore.parseSuggestions("nessuna proposta").isEmpty)
        #expect(HabitInterpreterCore.parseSuggestions("[]").isEmpty)
    }
}
