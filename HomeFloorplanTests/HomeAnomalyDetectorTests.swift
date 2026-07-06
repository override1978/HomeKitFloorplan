import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeAnomalyDetector — regole intervallo e segnale")
struct HomeAnomalyDetectorTests {

    // MARK: - Contatti aperti

    @Test("Contatto aperto 20 min: insight low/0.55 (sotto il gate standard, sopra quello operativo)")
    func openContactBasic() {
        var config = HomeAnomalyDetector.Configuration()
        config.escalatesOpenContactsAtNight = false

        let interval = makeInterval(
            entityName: "Finestra Cucina",
            roomName: "Cucina",
            signalType: .contact,
            stateRaw: "open",
            startedAt: Date().addingTimeInterval(-20 * 60)
        )

        let insights = HomeAnomalyDetector.detect(intervals: [interval], configuration: config)
        let insight = try? #require(insights.first)
        #expect(insight?.kind == .anomaly)
        #expect(insight?.severity == .low)
        #expect(insight?.confidence == 0.55)
        #expect(insight?.category == .security) // "finestra" → window-like
        #expect(insight?.signalType == .contact)
    }

    @Test("Contatto aperto 10 min: sotto la durata minima, nessun insight")
    func openContactBelowMinimum() {
        var config = HomeAnomalyDetector.Configuration()
        config.escalatesOpenContactsAtNight = false

        let interval = makeInterval(
            entityName: "Porta Ingresso",
            signalType: .contact,
            stateRaw: "open",
            startedAt: Date().addingTimeInterval(-10 * 60)
        )

        #expect(HomeAnomalyDetector.detect(intervals: [interval], configuration: config).isEmpty)
    }

    @Test("Contatto aperto 50 min: elevated per durata → medium/0.75")
    func openContactElevatedByDuration() {
        var config = HomeAnomalyDetector.Configuration()
        config.escalatesOpenContactsAtNight = false

        let interval = makeInterval(
            entityName: "Porta Balcone",
            signalType: .contact,
            stateRaw: "open",
            startedAt: Date().addingTimeInterval(-50 * 60)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval], configuration: config).first
        #expect(insight?.severity == .medium)
        #expect(insight?.confidence == 0.75)
    }

    @Test("Escalation notturna sticky: aperto dalle 23:00 di ieri resta elevated anche di giorno")
    func nightEscalationIsSticky() {
        var config = HomeAnomalyDetector.Configuration()
        config.escalatesOpenContactsAtNight = true
        // Soglia durata volutamente irraggiungibile: l'elevation può venire SOLO dal tocco notturno.
        config.elevatedOpenContactDuration = 100 * 3600

        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let startedAt = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!

        let interval = makeInterval(
            entityName: "Finestra Studio",
            signalType: .contact,
            stateRaw: "open",
            startedAt: startedAt
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval], configuration: config).first
        #expect(insight?.severity == .medium)
        #expect(insight?.confidence == 0.75)
    }

    // MARK: - Power (luci/prese)

    @Test("Presa attiva 7h senza baseline: insight low/0.55 deviceHealth")
    func longRunningPowerWithoutBaseline() {
        let interval = makeInterval(
            entityName: "Presa Lavatrice",
            signalType: .power,
            stateRaw: "on",
            startedAt: Date().addingTimeInterval(-7 * 3600)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval]).first
        #expect(insight?.severity == .low)
        #expect(insight?.confidence == 0.55)
        #expect(insight?.category == .deviceHealth)
        #expect(insight?.signalType == .power)
    }

    @Test("Presa attiva 3h senza baseline: sotto le 6h di default, nessun insight")
    func powerBelowFallbackDuration() {
        let interval = makeInterval(
            entityName: "Presa TV",
            signalType: .power,
            stateRaw: "on",
            startedAt: Date().addingTimeInterval(-3 * 3600)
        )
        #expect(HomeAnomalyDetector.detect(intervals: [interval]).isEmpty)
    }

    @Test("deviceRoleRaw 'light' vince sui token del nome: 'Studio Cubo' è una luce")
    func structuralDeviceRoleBeatsNameTokens() {
        let interval = makeInterval(
            entityName: "Studio Cubo", // nessun token luce/presa nel nome
            roomName: "Studio",
            signalType: .power,
            stateRaw: "on",
            deviceRoleRaw: "light",
            startedAt: Date().addingTimeInterval(-7 * 3600)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval]).first
        #expect(insight?.category == .lighting)
    }

    @Test("Nome che contiene già la stanza: niente 'Studio Studio Cubo' nel messaggio")
    func entityNameNotDuplicatedWithRoom() {
        let interval = makeInterval(
            entityName: "Studio Cubo",
            roomName: "Studio",
            signalType: .power,
            stateRaw: "on",
            deviceRoleRaw: "light",
            startedAt: Date().addingTimeInterval(-7 * 3600)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval]).first
        #expect(insight?.message.contains("Studio Studio") == false)
    }

    @Test("Intervallo attivo: il messaggio riporta la durata stimata")
    func activeIntervalMessageIncludesDuration() {
        let interval = makeInterval(
            entityName: "Presa Lavatrice",
            signalType: .power,
            stateRaw: "on",
            startedAt: Date().addingTimeInterval(-7 * 3600)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval]).first
        #expect(insight?.message.contains("7h") == true)
    }

    @Test("Power con baseline durata: soglia = p95 × 1.5, confidence dalla baseline")
    func powerWithDurationBaseline() {
        let accessoryID = UUID().uuidString
        let baseline = HomeBaseline(
            entityID: accessoryID,
            entityName: "Luce Studio",
            roomName: "Studio",
            signalType: .power,
            baselineKind: .duration,
            windowRaw: "preview-14d",
            mean: 1800,
            p95: 3600, // 1h abituale → soglia 1.5h
            sampleCount: 5,
            confidence: 0.7,
            contextKey: "preview.raw.duration.on"
        )
        let interval = makeInterval(
            entityID: accessoryID,
            entityName: "Luce Studio",
            roomName: "Studio",
            signalType: .power,
            stateRaw: "on",
            startedAt: Date().addingTimeInterval(-2 * 3600) // 2h > 1.5h
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval], baselines: [baseline]).first
        #expect(insight != nil)
        #expect(insight?.confidence == 0.7)
        #expect(insight?.category == .lighting) // "luce" → light role
    }

    @Test("Anomalia power: trasporta l'azione correttiva 'spegni'")
    func powerAnomalyCarriesTurnOffAction() throws {
        let interval = makeInterval(
            entityName: "Presa Lavatrice",
            signalType: .power,
            stateRaw: "on",
            deviceRoleRaw: "outlet",
            startedAt: Date().addingTimeInterval(-7 * 3600)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval]).first
        let json = try #require(insight?.suggestedActionJSON)
        let action = try JSONDecoder().decode(AINextAction.self, from: #require(json.data(using: .utf8)))
        #expect(action.accessoryActionType == "off")
        #expect(action.accessoryID == interval.entityID)
    }

    @Test("Anomalia contatto: nessuna azione (una finestra non si chiude via software)")
    func contactAnomalyHasNoAction() {
        var config = HomeAnomalyDetector.Configuration()
        config.escalatesOpenContactsAtNight = false

        let interval = makeInterval(
            entityName: "Finestra Cucina",
            signalType: .contact,
            stateRaw: "open",
            startedAt: Date().addingTimeInterval(-20 * 60)
        )

        let insight = HomeAnomalyDetector.detect(intervals: [interval], configuration: config).first
        #expect(insight?.suggestedActionJSON == nil)
    }

    // MARK: - Segnali (baseline z-score)

    @Test("Temperatura z-score 6: anomalia high con signalType strutturato")
    func temperatureHighDeviation() {
        let entityID = UUID().uuidString
        let baseline = HomeBaseline(
            entityID: entityID,
            roomName: "Camera",
            signalType: .temperature,
            baselineKind: .range,
            windowRaw: "daily",
            mean: 20,
            standardDeviation: 1,
            sampleCount: 10,
            confidence: 0.8
        )
        let signal = makeSignal(entityID: entityID, roomName: "Camera", signalType: .temperature, value: 26)

        let insights = HomeAnomalyDetector.detect(signals: [signal], baselines: [baseline])
        let insight = insights.first
        #expect(insight?.severity == .high)
        #expect(insight?.kind == .anomaly)
        #expect(insight?.signalType == .temperature)
    }

    @Test("Delta sotto la policy minima: outcome smallDelta, nessun insight")
    func smallDeltaIsFiltered() {
        let entityID = UUID().uuidString
        let baseline = HomeBaseline(
            entityID: entityID,
            roomName: "Camera",
            signalType: .temperature,
            baselineKind: .range,
            windowRaw: "daily",
            mean: 20,
            standardDeviation: 1,
            sampleCount: 10,
            confidence: 0.8
        )
        let signal = makeSignal(entityID: entityID, roomName: "Camera", signalType: .temperature, value: 21)

        let evaluations = HomeAnomalyDetector.evaluate(signals: [signal], baselines: [baseline])
        #expect(evaluations.first?.outcome == .smallDelta)
        #expect(evaluations.first?.insight == nil)
    }

    // MARK: - Helper

    private func makeInterval(
        entityID: String = UUID().uuidString,
        entityName: String,
        roomName: String? = "Stanza",
        signalType: HomeSignalType,
        stateRaw: String,
        deviceRoleRaw: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil
    ) -> HomeStateInterval {
        HomeStateInterval(
            entityID: entityID,
            entityName: entityName,
            roomName: roomName,
            signalType: signalType,
            stateRaw: stateRaw,
            deviceRoleRaw: deviceRoleRaw,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func makeSignal(
        entityID: String,
        roomName: String,
        signalType: HomeSignalType,
        value: Double
    ) -> HomeSignalEvent {
        HomeSignalEvent(
            sourceKind: .sensor,
            entityKind: .sensor,
            entityID: entityID,
            entityName: "Sensore",
            roomName: roomName,
            signalType: signalType,
            value: .double(value),
            rawSourceType: "Test"
        )
    }
}
