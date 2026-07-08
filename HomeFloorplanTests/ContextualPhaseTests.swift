import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("P2 — Contextual Phase")
struct ContextualPhaseTests {

    // MARK: - ContextualCondition

    @Test("Signature round-trip e parsing difensivo")
    func conditionSignatureRoundTrip() {
        let condition = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5)
        #expect(ContextualCondition.parse(fromSignature: condition.signature) == condition)

        #expect(ContextualCondition.parse(fromSignature: "context:lightSensor:below:150") ==
                ContextualCondition(sensorTypeRaw: "lightSensor", direction: "below", threshold: 150))
        #expect(ContextualCondition.parse(fromSignature: "sequential:x:y") == nil)
        #expect(ContextualCondition.parse(fromSignature: "context:temp:sideways:27") == nil)
        #expect(ContextualCondition.parse(fromSignature: "context:temp:above:non-un-numero") == nil)
    }

    @Test("Arrotondamento soglia a step leggibile per tipo")
    func thresholdRounding() {
        #expect(ContextualCorrelationEngine.roundToStep(27.3, step: 0.5) == 27.5)
        #expect(ContextualCorrelationEngine.roundToStep(163, step: 25) == 175)
        #expect(ContextualCorrelationEngine.step(for: .temperature) == 0.5)
        #expect(ContextualCorrelationEngine.step(for: .lightSensor) == 25)
    }

    // MARK: - Correlatore: scenari sintetici

    @Test("Eventi sempre col caldo + baseline mista → condizione temperature/above trovata")
    func correlationFindsDominantCondition() {
        // 30 giorni: baseline a 20°, ma nei momenti degli eventi la stanza è a 29-31°
        let (candidate, events, readings) = makeScenario(
            eventValues: [29, 30, 31, 29.5, 30.5, 30],
            baselineValue: 20
        )

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings
        )

        let pattern = try? #require(patterns.first)
        #expect(pattern?.patternType == .contextual)
        let condition = pattern?.causeSignature.flatMap(ContextualCondition.parse(fromSignature:))
        #expect(condition?.sensorTypeRaw == "temperature")
        #expect(condition?.direction == "above")
        // Soglia = midpoint(mediana eventi ≈30, mediana baseline 20) ≈ 25
        #expect(condition.map { $0.threshold > 20 && $0.threshold < 30 } == true)
    }

    @Test("Condizione sempre vera (baseRate ~1) → scartata")
    func alwaysTrueConditionRejected() {
        // Baseline E eventi tutti a ~30°: la condizione non discrimina nulla
        let (candidate, events, readings) = makeScenario(
            eventValues: [30, 30.2, 29.8, 30.1, 30, 29.9],
            baselineValue: 30
        )

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings
        )
        #expect(patterns.isEmpty)
    }

    @Test("Sotto il minimo di osservazioni → scartata")
    func tooFewObservationsRejected() {
        let (candidate, events, readings) = makeScenario(
            eventValues: [29, 30, 31], // solo 3 eventi (< 5)
            baselineValue: 20
        )

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings
        )
        #expect(patterns.isEmpty)
    }

    // MARK: - Opportunità da pattern contestuale

    @Test("Pattern contestuale → opportunità 'characteristic' strutturalmente convertibile")
    func contextualPatternProducesConvertibleOpportunity() {
        let condition = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5)
        let pattern = BehavioralPattern(
            id: UUID(),
            patternType: .contextual,
            detectedAt: Date(),
            accessoryName: "Tenda Studio",
            accessoryID: UUID(),
            roomName: "Studio",
            eventTypeRaw: "blind",
            action: .close,
            numericValue: nil,
            avgMinuteOfDay: 14 * 60,
            timeDeviationMinutes: 120,
            weekdays: [],
            dayType: nil,
            causeSignature: condition.signature,
            causeName: "Temperatura > 27.5°C",
            avgGapSeconds: nil,
            observations: 8,
            validations: 8,
            firstObservedAt: Date().addingTimeInterval(-12 * 24 * 3600),
            lastObservedAt: Date(),
            stabilityDays: 12,
            distinctActiveDays: 7,
            status: .active,
            dismissedAt: nil,
            approvedAt: nil,
            naturalLanguageDescription: "Chiudi Tenda Studio quando Temperatura supera 27.5°C"
        )

        let opportunity = AutomationOpportunity(from: pattern)
        #expect(opportunity.triggerType == "characteristic")
        #expect(opportunity.triggerSensorType == "temperature")
        #expect(opportunity.triggerThreshold == 27.5)
        #expect(opportunity.triggerDirection == "above")
        #expect(opportunity.isStructurallyConvertibleToAutomation)
    }

    // MARK: - P2 v2: encoding multi-condizione

    @Test("Signature multi round-trip, stanza con caratteri riservati, primaria stabile")
    func multiConditionSignatureRoundTrip() {
        let primary = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5)
        let secondary = ContextualCondition(
            sensorTypeRaw: "lightSensor", direction: "below", threshold: 100,
            roomName: "Salotto+Cucina @ 2:piano"
        )
        let signature = ContextualCondition.signature(for: [primary, secondary])

        #expect(ContextualCondition.parseConditions(fromSignature: signature) == [primary, secondary])
        // parse() restituisce la primaria: contextualDecisionKey resta invariata
        // tra forma mono e multi dello stesso comportamento (anti flip-flop).
        #expect(ContextualCondition.parse(fromSignature: signature) == primary)
        // Mono-condizione senza stanza → formato legacy byte-identico a P2 v1:
        // le decision key utente persistite dipendono da questo.
        #expect(primary.signature == "context:temperature:above:27.5")
        // Una signature multi mezza-valida non degrada in silenzio.
        #expect(ContextualCondition.parseConditions(fromSignature: "context:temperature:above:27.5+rotto") == nil)
    }

    @Test("Condizioni WeatherKit non HomeKit-backed, fisiche sì")
    func homeKitBackedConditions() {
        #expect(ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27).isHomeKitBacked)
        #expect(!ContextualCondition(sensorTypeRaw: "outdoorTemperature", direction: "above", threshold: 30).isHomeKitBacked)
    }

    // MARK: - P2 v2: opportunità

    @Test("Pattern multi → scalari = primaria, lista completa in triggerConditionsRaw")
    func multiConditionPatternProducesSelfContainedOpportunity() {
        let primary = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5)
        let secondary = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 30, roomName: "Balcone")
        let signature = ContextualCondition.signature(for: [primary, secondary])
        let pattern = makeContextualPattern(causeSignature: signature)

        let opportunity = AutomationOpportunity(from: pattern)
        #expect(opportunity.triggerType == "characteristic")
        #expect(opportunity.triggerSensorType == "temperature")
        #expect(opportunity.triggerThreshold == 27.5)
        #expect(opportunity.triggerConditionsRaw == signature)
        #expect(opportunity.isStructurallyConvertibleToAutomation)
        #expect(opportunity.scheduleSummary?.contains("Balcone") == true)
    }

    @Test("Pattern mono-condizione → triggerConditionsRaw nil (comportamento P2 v1 invariato)")
    func singleConditionPatternKeepsLegacyShape() {
        let condition = ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5)
        let opportunity = AutomationOpportunity(from: makeContextualPattern(causeSignature: condition.signature))
        #expect(opportunity.triggerConditionsRaw == nil)
        #expect(opportunity.isStructurallyConvertibleToAutomation)
    }

    @Test("Condizione solo-WeatherKit → niente CTA (wizard fallirebbe sempre)")
    func weatherOnlyConditionIsNotConvertible() {
        let condition = ContextualCondition(sensorTypeRaw: "outdoorTemperature", direction: "above", threshold: 30)
        let opportunity = AutomationOpportunity(from: makeContextualPattern(causeSignature: condition.signature))
        #expect(opportunity.triggerType == "characteristic")
        #expect(!opportunity.isStructurallyConvertibleToAutomation)
    }

    // MARK: - P2 v2: correlatore a coppie

    @Test("Coppia genuina (entrambe restringono) → pattern con due condizioni")
    func genuinePairIsEmitted() {
        // Temp alta e lux bassa in FASI DIVERSE della baseline (mai insieme fuori
        // dagli eventi): l'AND restringe davvero.
        let (candidate, events, readings) = makePairScenario(correlatedBaselines: false)

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings
        )

        let conditions = patterns.first?.causeSignature.flatMap(ContextualCondition.parseConditions(fromSignature:))
        #expect(conditions?.count == 2)
        #expect(Set(conditions?.map(\.sensorTypeRaw) ?? []) == ["temperature", "lightSensor"])
    }

    @Test("Secondaria correlata alla primaria → resta la condizione singola")
    func correlatedPairIsRejected() {
        // Lux bassa ESATTAMENTE quando temp alta: l'AND non restringe nulla.
        let (candidate, events, readings) = makePairScenario(correlatedBaselines: true)

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings
        )

        let conditions = patterns.first?.causeSignature.flatMap(ContextualCondition.parseConditions(fromSignature:))
        #expect(conditions?.count == 1)
    }

    @Test("Stanza outdoor promossa: il Balcone spiega un effetto nello Studio")
    func outdoorRoomPromotion() {
        // Studio: temperatura piatta (nessuna correlazione possibile).
        // Balcone: calda solo agli eventi → condizione con stanza esplicita.
        var readings: [SensorReading] = []
        let now = Date()
        for hourOffset in stride(from: 1, to: 20 * 24, by: 1) {
            let t = now.addingTimeInterval(-Double(hourOffset) * 3600)
            readings.append(SensorReading(accessoryUUID: "studio-temp", serviceType: .temperature, roomName: "Studio", value: 22, timestamp: t))
            readings.append(SensorReading(accessoryUUID: "balcone-temp", serviceType: .temperature, roomName: "Balcone", value: 18, timestamp: t))
        }
        let (candidate, events) = makeEvents(count: 6)
        for event in events {
            readings.append(SensorReading(accessoryUUID: "studio-temp", serviceType: .temperature, roomName: "Studio", value: 22, timestamp: event.timestamp.addingTimeInterval(-120)))
            readings.append(SensorReading(accessoryUUID: "balcone-temp", serviceType: .temperature, roomName: "Balcone", value: 32, timestamp: event.timestamp.addingTimeInterval(-120)))
        }

        let patterns = ContextualCorrelationEngine.detect(
            candidates: [candidate],
            accessoryEvents: events,
            readings: readings,
            outdoorRoomName: "Balcone"
        )

        let conditions = patterns.first?.causeSignature.flatMap(ContextualCondition.parseConditions(fromSignature:))
        #expect(conditions?.first?.roomName == "Balcone")
        #expect(conditions?.first?.sensorTypeRaw == "temperature")
        // Convertibile end-to-end: stanza esplicita nell'opportunità autosufficiente.
        if let pattern = patterns.first {
            let opportunity = AutomationOpportunity(from: pattern)
            #expect(opportunity.triggerConditionsRaw != nil)
            #expect(opportunity.isStructurallyConvertibleToAutomation)
        }
    }

    // MARK: - Scenario builder

    private func makeContext(for timestamp: Date) -> BehavioralEventContext {
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: timestamp)
        let hour = comps.hour ?? 0
        return BehavioralEventContext(
            timeOfDay: TimeOfDay(hour: hour),
            dayType: DayType(weekday: comps.weekday ?? 1),
            hourOfDay: hour,
            minuteOfDay: hour * 60 + (comps.minute ?? 0),
            weekday: comps.weekday ?? 1
        )
    }

    /// Costruisce candidato + eventi (uno ogni 2 giorni alle ore alternate, così il gate
    /// orario li respingerebbe) + letture: baseline costante campionata ogni ora per 15
    /// giorni, con il valore-evento iniettato al momento di ogni evento.
    private func makeScenario(
        eventValues: [Double],
        baselineValue: Double
    ) -> (ContextualCandidate, [BehavioralEvent], [SensorReading]) {
        let calendar = Calendar.current
        let now = Date()
        var events: [BehavioralEvent] = []
        var readings: [SensorReading] = []

        // Baseline: una lettura l'ora per 15 giorni
        for hourOffset in stride(from: 1, to: 15 * 24, by: 1) {
            let t = now.addingTimeInterval(-Double(hourOffset) * 3600)
            readings.append(SensorReading(
                accessoryUUID: "test-sensor",
                serviceType: .temperature,
                roomName: "Studio",
                value: baselineValue,
                timestamp: t
            ))
        }

        // Eventi: orari sparsi (10, 13, 16, ...) per simulare il rigetto del gate orario
        for (index, value) in eventValues.enumerated() {
            let day = calendar.date(byAdding: .day, value: -(index * 2 + 1), to: now)!
            let hour = 10 + (index * 3) % 9
            let timestamp = calendar.date(bySettingHour: hour, minute: 15, second: 0, of: day)!

            events.append(BehavioralEvent(
                id: UUID(),
                timestamp: timestamp,
                source: .accessory,
                accessoryID: UUID(),
                accessoryName: "Tenda Studio",
                roomName: "Studio",
                eventTypeRaw: "blind",
                action: .close,
                numericValue: nil,
                context: makeContext(for: timestamp)
            ))
            // Lettura al momento dell'evento col valore "caldo"
            readings.append(SensorReading(
                accessoryUUID: "test-sensor",
                serviceType: .temperature,
                roomName: "Studio",
                value: value,
                timestamp: timestamp.addingTimeInterval(-120)
            ))
        }

        let candidate = ContextualCandidate(
            accessoryName: "Tenda Studio",
            action: BehavioralAction.close.rawValue,
            roomName: "Studio",
            occurrences: eventValues.count,
            stdDevMinutes: 150,
            distinctDays: eventValues.count,
            minMinuteOfDay: 10 * 60,
            maxMinuteOfDay: 18 * 60
        )

        return (candidate, events, readings)
    }

    // MARK: - P2 v2 builders

    private func makeContextualPattern(causeSignature: String) -> BehavioralPattern {
        BehavioralPattern(
            id: UUID(),
            patternType: .contextual,
            detectedAt: Date(),
            accessoryName: "Tenda Studio",
            accessoryID: UUID(),
            roomName: "Studio",
            eventTypeRaw: "blind",
            action: .close,
            numericValue: nil,
            avgMinuteOfDay: 14 * 60,
            timeDeviationMinutes: 120,
            weekdays: [],
            dayType: nil,
            causeSignature: causeSignature,
            causeName: "test",
            avgGapSeconds: nil,
            observations: 8,
            validations: 8,
            firstObservedAt: Date().addingTimeInterval(-12 * 24 * 3600),
            lastObservedAt: Date(),
            stabilityDays: 12,
            distinctActiveDays: 7,
            status: .active,
            dismissedAt: nil,
            approvedAt: nil,
            naturalLanguageDescription: "test"
        )
    }

    /// Eventi "Tenda Studio · close" a orari sparsi, uno ogni 2 giorni.
    private func makeEvents(count: Int) -> (ContextualCandidate, [BehavioralEvent]) {
        let calendar = Calendar.current
        let now = Date()
        var events: [BehavioralEvent] = []
        for index in 0..<count {
            let day = calendar.date(byAdding: .day, value: -(index * 2 + 1), to: now)!
            let hour = 10 + (index * 3) % 9
            let timestamp = calendar.date(bySettingHour: hour, minute: 15, second: 0, of: day)!
            events.append(BehavioralEvent(
                id: UUID(),
                timestamp: timestamp,
                source: .accessory,
                accessoryID: UUID(),
                accessoryName: "Tenda Studio",
                roomName: "Studio",
                eventTypeRaw: "blind",
                action: .close,
                numericValue: nil,
                context: makeContext(for: timestamp)
            ))
        }
        let candidate = ContextualCandidate(
            accessoryName: "Tenda Studio",
            action: BehavioralAction.close.rawValue,
            roomName: "Studio",
            occurrences: count,
            stdDevMinutes: 150,
            distinctDays: count,
            minMinuteOfDay: 10 * 60,
            maxMinuteOfDay: 18 * 60
        )
        return (candidate, events)
    }

    /// Due serie (temperatura e lux) nello Studio + 8 eventi con temp alta E lux bassa.
    /// `correlatedBaselines: false` → temp alta e lux bassa in fasi DISGIUNTE della
    /// baseline (l'AND restringe: jointBase ~0). `true` → sempre nelle stesse ore
    /// (l'AND non aggiunge nulla: jointBase = baseRate singolo).
    private func makePairScenario(
        correlatedBaselines: Bool
    ) -> (ContextualCandidate, [BehavioralEvent], [SensorReading]) {
        let now = Date()
        var readings: [SensorReading] = []

        for hourOffset in stride(from: 1, to: 20 * 24, by: 1) {
            let t = now.addingTimeInterval(-Double(hourOffset) * 3600)
            let tempHigh = hourOffset % 10 < 3
            let luxLow = correlatedBaselines ? tempHigh : ((hourOffset + 5) % 10 < 3)
            readings.append(SensorReading(
                accessoryUUID: "temp", serviceType: .temperature, roomName: "Studio",
                value: tempHigh ? 30 : 20, timestamp: t
            ))
            readings.append(SensorReading(
                accessoryUUID: "lux", serviceType: .lightSensor, roomName: "Studio",
                value: luxLow ? 50 : 300, timestamp: t
            ))
        }

        let (candidate, events) = makeEvents(count: 8)
        for event in events {
            let t = event.timestamp.addingTimeInterval(-120)
            readings.append(SensorReading(accessoryUUID: "temp", serviceType: .temperature, roomName: "Studio", value: 30, timestamp: t))
            readings.append(SensorReading(accessoryUUID: "lux", serviceType: .lightSensor, roomName: "Studio", value: 50, timestamp: t))
        }

        return (candidate, events, readings)
    }
}
