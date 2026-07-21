import Foundation
import Testing
@testable import HomeFloorplan

/// Test di `ContextualCondition` (encoding/parse/convertibilità delle condizioni
/// ambientali usate dal mapper automazioni). I test del `ContextualCorrelationEngine`
/// statistico sono stati rimossi col ritiro del motore comportamentale.
@MainActor
@Suite("P2 — Contextual Condition")
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
        #expect(ContextualCondition.parse(fromSignature: signature) == primary)
        #expect(primary.signature == "context:temperature:above:27.5")
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

    // MARK: - Builder

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
}
