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

}
