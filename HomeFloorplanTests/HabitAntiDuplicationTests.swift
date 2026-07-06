import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("Motore abitudini — anti-duplicazione P0")
struct HabitAntiDuplicationTests {

    // MARK: - AutomationDuplicateChecker

    @Test("Timer-trigger stesso accessorio entro ±45 min → coperto")
    func timerTriggerWithinTolerance() {
        let accessory = UUID()
        let snapshots = [makeSnapshot(name: "Tramonto Luci", accessories: [accessory], fireMinute: 19 * 60 + 30)]

        // Pattern alle 19:50 (20 min di distanza) → coperto
        #expect(AutomationDuplicateChecker.automationCovering(
            accessoryID: accessory, avgMinuteOfDay: 19 * 60 + 50, in: snapshots
        ) == "Tramonto Luci")

        // Pattern alle 21:30 (120 min) → NON coperto
        #expect(AutomationDuplicateChecker.automationCovering(
            accessoryID: accessory, avgMinuteOfDay: 21 * 60 + 30, in: snapshots
        ) == nil)
    }

    @Test("Confronto orario circolare: 23:50 e 00:20 distano 30 minuti")
    func circularMidnightComparison() {
        let accessory = UUID()
        let snapshots = [makeSnapshot(name: "Buonanotte", accessories: [accessory], fireMinute: 23 * 60 + 50)]

        #expect(AutomationDuplicateChecker.automationCovering(
            accessoryID: accessory, avgMinuteOfDay: 20, in: snapshots
        ) == "Buonanotte")
    }

    @Test("Event-trigger sullo stesso accessorio → coperto a prescindere dall'orario")
    func eventTriggerAlwaysCovers() {
        let accessory = UUID()
        let snapshots = [makeSnapshot(name: "Movimento Ingresso", accessories: [accessory], fireMinute: nil)]

        #expect(AutomationDuplicateChecker.automationCovering(
            accessoryID: accessory, avgMinuteOfDay: 300, in: snapshots
        ) == "Movimento Ingresso")
    }

    @Test("Automazione disabilitata o accessorio diverso → non copre")
    func disabledOrUnrelatedDoesNotCover() {
        let accessory = UUID()
        let disabled = makeSnapshot(name: "Spenta", accessories: [accessory], fireMinute: 600, isEnabled: false)
        let other = makeSnapshot(name: "Altro", accessories: [UUID()], fireMinute: 600)

        #expect(AutomationDuplicateChecker.automationCovering(
            accessoryID: accessory, avgMinuteOfDay: 600, in: [disabled, other]
        ) == nil)
    }

    @Test("Scena già schedulata da un'automazione → coperta (case-insensitive)")
    func sceneTriggeredByExistingAutomation() {
        let snapshots = [ExistingAutomationSnapshot(
            name: "Sera Relax",
            isEnabled: true,
            targetAccessoryIDs: [],
            triggeredSceneNames: ["Buonanotte"],
            fireMinuteOfDay: 22 * 60
        )]

        #expect(AutomationDuplicateChecker.automationTriggering(sceneName: "buonanotte", in: snapshots) == "Sera Relax")
        #expect(AutomationDuplicateChecker.automationTriggering(sceneName: "Cinema", in: snapshots) == nil)
    }

    // MARK: - HabitNoiseFilter

    @Test("Eventi adiacenti a un'esecuzione scena esclusi, gli altri conservati")
    func sceneAdjacentEventsExcluded() {
        let sceneAt = Date()
        let events = [
            makeEvent(name: "Luce A", timestamp: sceneAt.addingTimeInterval(3)),    // scene-driven
            makeEvent(name: "Luce B", timestamp: sceneAt.addingTimeInterval(-6)),   // scene-driven
            makeEvent(name: "Luce C", timestamp: sceneAt.addingTimeInterval(120)),  // umano
            makeEvent(name: "Luce D", timestamp: sceneAt.addingTimeInterval(-3600)) // umano
        ]

        let kept = HabitNoiseFilter.excludingSceneDrivenEvents(events, sceneExecutionTimestamps: [sceneAt])
        #expect(kept.map(\.accessoryName).sorted() == ["Luce C", "Luce D"])
    }

    @Test("Nessuna esecuzione scena → tutti gli eventi conservati")
    func noScenesKeepsEverything() {
        let events = [makeEvent(name: "Luce A", timestamp: Date())]
        #expect(HabitNoiseFilter.excludingSceneDrivenEvents(events, sceneExecutionTimestamps: []).count == 1)
    }

    // MARK: - P1: sequenze A→B convertibili

    @Test("causeSignature → stato trigger: on/dim attivano, off disattiva, sconosciuto nil")
    func causeTriggerStateParsing() {
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "light:Faretti Cucina:on") == true)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "light:Lampada:dim") == true)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "switch:TV:off") == false)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "sensor:X:unknown-action") == nil)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "malformed") == nil)
    }

    @Test("Opportunità da pattern sequenziale: trigger accessoryState, strutturalmente convertibile")
    func sequentialPatternProducesConvertibleOpportunity() {
        let pattern = makeSequentialPattern(
            effectName: "Luce Corridoio",
            effectID: UUID(),
            causeName: "TV Soggiorno",
            causeSignature: "switch:TV Soggiorno:on"
        )

        let opportunity = AutomationOpportunity(from: pattern)
        #expect(opportunity.triggerType == "accessoryState")
        #expect(opportunity.isStructurallyConvertibleToAutomation)
    }

    // MARK: - Helper

    private func makeSnapshot(
        name: String,
        accessories: Set<UUID>,
        fireMinute: Int?,
        isEnabled: Bool = true
    ) -> ExistingAutomationSnapshot {
        ExistingAutomationSnapshot(
            name: name,
            isEnabled: isEnabled,
            targetAccessoryIDs: accessories,
            triggeredSceneNames: [],
            fireMinuteOfDay: fireMinute
        )
    }

    private func makeSequentialPattern(
        effectName: String,
        effectID: UUID,
        causeName: String,
        causeSignature: String
    ) -> BehavioralPattern {
        BehavioralPattern(
            id: UUID(),
            patternType: .sequential,
            detectedAt: Date(),
            accessoryName: effectName,
            accessoryID: effectID,
            roomName: "Corridoio",
            eventTypeRaw: "light",
            action: .on,
            numericValue: nil,
            avgMinuteOfDay: 21 * 60,
            timeDeviationMinutes: 5,
            weekdays: [],
            dayType: nil,
            causeSignature: causeSignature,
            causeName: causeName,
            avgGapSeconds: 120,
            observations: 12,
            validations: 12,
            firstObservedAt: Date().addingTimeInterval(-14 * 24 * 3600),
            lastObservedAt: Date(),
            stabilityDays: 14,
            distinctActiveDays: 10,
            status: .active,
            dismissedAt: nil,
            approvedAt: nil,
            naturalLanguageDescription: "Quando accendi TV Soggiorno, accendi Luce Corridoio"
        )
    }

    private func makeEvent(name: String, timestamp: Date) -> AccessoryEvent {
        AccessoryEvent(
            accessoryID: UUID(),
            accessoryName: name,
            roomName: "Stanza",
            state: true,
            timestamp: timestamp,
            eventType: AccessoryEventType.light.rawValue
        )
    }
}
