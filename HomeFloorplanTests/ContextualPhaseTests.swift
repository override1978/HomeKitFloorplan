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
}
