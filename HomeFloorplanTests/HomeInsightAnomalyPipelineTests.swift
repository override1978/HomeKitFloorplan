import Foundation
import SwiftData
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeInsightAnomalyPipeline — gate e flusso end-to-end", .serialized)
struct HomeInsightAnomalyPipelineTests {

    @Test("Luce accesa 7h: l'insight operativo (confidence 0.55) supera il gate dedicato")
    func operationalInsightBypassesStandardConfidenceGate() throws {
        let container = try makeContainer()
        OperationalIntelligencePolicy.default.save()

        let event = AccessoryEvent(
            accessoryID: UUID(),
            accessoryName: "Lampada Studio",
            roomName: "Studio",
            state: true,
            timestamp: Date().addingTimeInterval(-7 * 3600),
            eventType: AccessoryEventType.light.rawValue
        )
        container.mainContext.insert(event)
        try container.mainContext.save()

        let insights = HomeInsightAnomalyPipeline.detect(modelContainer: container, homeKitService: nil)

        let light = insights.first { $0.category == .lighting }
        #expect(light != nil, "L'anomalia luce deve superare il gate operativo (0.5) pur essendo sotto quello standard (0.65)")
        #expect(light?.confidence == 0.55)
        #expect(light?.kind == .anomaly)
        #expect(light?.signalType == .power)
        #expect(light?.sourceRecordType == "HomeStateInterval")
    }

    @Test("Porta aperta 30 min: l'anomalia contatto arriva dalla pipeline completa")
    func openContactSurvivesPipeline() throws {
        let container = try makeContainer()
        var policy = OperationalIntelligencePolicy.default
        policy.escalatesAtNight = false
        policy.save()

        let accessoryID = UUID()
        let event = AccessoryEvent(
            accessoryID: accessoryID,
            accessoryName: "Porta Ingresso",
            roomName: "Ingresso",
            state: false, // false = aperto per i contatti
            timestamp: Date().addingTimeInterval(-30 * 60),
            eventType: AccessoryEventType.contact.rawValue
        )
        container.mainContext.insert(event)
        try container.mainContext.save()

        let insights = HomeInsightAnomalyPipeline.detect(modelContainer: container, homeKitService: nil)

        let contact = insights.first { $0.signalType == .contact }
        #expect(contact != nil)
        #expect(contact?.confidence == 0.55)
    }

    @Test("Stanza ignorata: nessun insight dalla stanza 'Impostazioni'")
    func ignoredRoomProducesNoInsights() throws {
        let container = try makeContainer()
        var policy = OperationalIntelligencePolicy.default
        policy.ignoredRoomNames = ["Impostazioni"]
        policy.save()

        let event = AccessoryEvent(
            accessoryID: UUID(),
            accessoryName: "Presenza",
            roomName: "Impostazioni",
            state: true,
            timestamp: Date().addingTimeInterval(-8 * 3600),
            eventType: AccessoryEventType.switch.rawValue
        )
        container.mainContext.insert(event)
        try container.mainContext.save()

        let insights = HomeInsightAnomalyPipeline.detect(modelContainer: container, homeKitService: nil)
        #expect(insights.allSatisfy { $0.roomName != "Impostazioni" })
    }

    @Test("Policy disabilitata: nessun insight operativo")
    func disabledPolicyProducesNoOperationalInsights() throws {
        let container = try makeContainer()
        var policy = OperationalIntelligencePolicy.default
        policy.isEnabled = false
        policy.save()

        let event = AccessoryEvent(
            accessoryID: UUID(),
            accessoryName: "Lampada Cucina",
            roomName: "Cucina",
            state: true,
            timestamp: Date().addingTimeInterval(-8 * 3600),
            eventType: AccessoryEventType.light.rawValue
        )
        container.mainContext.insert(event)
        try container.mainContext.save()

        let insights = HomeInsightAnomalyPipeline.detect(modelContainer: container, homeKitService: nil)
        #expect(insights.allSatisfy { $0.sourceRecordType != "HomeStateInterval" })
    }

    @Test("Senza HomeKit live: intervalli 'heating' attivi scartati (mode non verificabile)")
    func activeHeatingDroppedWithoutLiveState() throws {
        let container = try makeContainer()
        OperationalIntelligencePolicy.default.save()

        let event = AccessoryEvent(
            accessoryID: UUID(),
            accessoryName: "Termostato Soggiorno",
            roomName: "Soggiorno",
            state: true,
            timestamp: Date().addingTimeInterval(-3 * 3600),
            eventType: AccessoryEventType.thermostat.rawValue
        )
        container.mainContext.insert(event)
        try container.mainContext.save()

        let insights = HomeInsightAnomalyPipeline.detect(modelContainer: container, homeKitService: nil)
        #expect(insights.allSatisfy { $0.signalType != .active }, "Un heating non confermabile live non deve generare allarmi")
    }

    // MARK: - Helper

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AccessoryEvent.self,
            SensorReading.self,
            DailySensorSummary.self,
            AccessoryUsageSummary.self,
            SensorAlertThreshold.self
        ])
        // Nel test host (app con entitlement CloudKit/App Group) la configurazione
        // default prova cloudKitDatabase/groupContainer .automatic e il container
        // fallisce con loadIssueModelContainer: qui serve tutto esplicitamente off.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
