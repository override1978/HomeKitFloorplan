import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeSituationResolver — classificazione e aggregazione")
struct HomeSituationResolverTests {

    // MARK: - Dominio strutturato (signalType)

    @Test("signalType .contact → dominio security")
    func contactDomain() {
        let insight = makeInsight(signalType: .contact, category: .presence)
        #expect(HomeSituationResolver.domain(for: insight) == .security)
    }

    @Test("signalType .temperature → dominio climate")
    func temperatureDomain() {
        let insight = makeInsight(signalType: .temperature)
        #expect(HomeSituationResolver.domain(for: insight) == .climate)
    }

    @Test("signalType .carbonDioxide → dominio air")
    func co2Domain() {
        let insight = makeInsight(signalType: .carbonDioxide)
        #expect(HomeSituationResolver.domain(for: insight) == .air)
    }

    @Test("signalType .power con categoria lighting → lights, altrimenti loads")
    func powerDomainDependsOnCategory() {
        #expect(HomeSituationResolver.domain(for: makeInsight(signalType: .power, category: .lighting)) == .lights)
        #expect(HomeSituationResolver.domain(for: makeInsight(signalType: .power, category: .deviceHealth)) == .loads)
    }

    @Test("signalType .smoke → security anche con categoria environment")
    func smokeDomainIsSecurity() {
        let insight = makeInsight(signalType: .smoke, category: .environment)
        #expect(HomeSituationResolver.domain(for: insight) == .security)
    }

    @Test("Titolo italiano heating con signalType .active → climate (il testo da solo fallirebbe)")
    func italianHeatingTitleClassifiedStructurally() {
        let insight = makeInsight(
            signalType: .active,
            category: .environment,
            title: "Riscaldamento inatteso",
            message: "Termostato Soggiorno è in riscaldamento."
        )
        #expect(HomeSituationResolver.domain(for: insight) == .climate)
    }

    // MARK: - Fallback testuale (signalType nil)

    @Test("Fallback testuale: 'Clima acceso con finestra aperta' → climate")
    func textFallbackClimate() {
        let insight = makeInsight(
            signalType: nil,
            category: .environment,
            title: "Clima acceso con finestra aperta",
            message: "Soggiorno: Clima è attivo mentre Finestra risulta aperta."
        )
        #expect(HomeSituationResolver.domain(for: insight) == .climate)
    }

    @Test("Fallback su categoria: security senza token testuali → security")
    func textFallbackSecurityCategory() {
        let insight = makeInsight(
            signalType: nil,
            category: .security,
            title: "Ingresso",
            message: "Serratura sbloccata"
        )
        #expect(HomeSituationResolver.domain(for: insight) == .security)
    }

    // MARK: - Granularità

    @Test("Due dispositivi stesso problema/stanza: 2 card a .device, 1 push a .situation")
    func deviceGranularitySplitsDistinctDevices() {
        let valveA = makeInsight(
            signalType: .active,
            category: .environment,
            sourceEntityID: "AAAA",
            sourceRecordType: "HomeStateInterval",
            roomName: "Soggiorno"
        )
        let valveB = makeInsight(
            signalType: .active,
            category: .environment,
            sourceEntityID: "BBBB",
            sourceRecordType: "HomeStateInterval",
            roomName: "Soggiorno"
        )

        let deviceLevel = HomeSituationResolver.resolve([valveA, valveB], granularity: .device)
        let situationLevel = HomeSituationResolver.resolve([valveA, valveB], granularity: .situation)

        #expect(deviceLevel.count == 2)
        #expect(situationLevel.count == 1)
        #expect(situationLevel.first?.sourceCount == 2)
    }

    @Test("Misure ambientali multi-sensore restano aggregate anche a .device")
    func environmentalMeasuresStayMergedAtDeviceGranularity() {
        let sensorA = makeInsight(
            signalType: .temperature,
            sourceEntityID: "S1",
            sourceRecordType: "HomeSignalEvent",
            roomName: "Cucina"
        )
        let sensorB = makeInsight(
            signalType: .temperature,
            sourceEntityID: "S2",
            sourceRecordType: "HomeSignalEvent",
            roomName: "Cucina"
        )

        let deviceLevel = HomeSituationResolver.resolve([sensorA, sensorB], granularity: .device)
        #expect(deviceLevel.count == 1)
        #expect(deviceLevel.first?.sourceCount == 2)
    }

    @Test("Anomalia heating + incoerenza hvac sullo stesso dispositivo → una sola situation")
    func anomalyAndIncoherenceSameDeviceMerge() {
        let anomaly = makeInsight(
            kind: .anomaly,
            signalType: .active,
            category: .environment,
            sourceEntityID: "CLIMA1",
            sourceRecordType: "HomeStateInterval",
            roomName: "Studio",
            severity: .medium
        )
        let incoherence = makeInsight(
            kind: .incoherence,
            signalType: .active,
            category: .environment,
            sourceEntityID: "CLIMA1",
            sourceRecordType: "HomeIncoherenceDetector",
            roomName: "Studio",
            severity: .high,
            dedupeKey: "incoherence|hvacWindowOpen|studio"
        )

        let situations = HomeSituationResolver.resolve([anomaly, incoherence], granularity: .device)
        #expect(situations.count == 1)
        // La primary è quella a severity più alta.
        #expect(situations.first?.primary.kind == .incoherence)
    }

    @Test("Ordinamento: severity più alta prima")
    func sortBySeverity() {
        let low = makeInsight(signalType: .power, category: .lighting, roomName: "A", severity: .low)
        let high = makeInsight(signalType: .contact, category: .security, roomName: "B", severity: .high)

        let situations = HomeSituationResolver.resolve([low, high])
        #expect(situations.first?.primary.severity == .high)
    }

    // MARK: - Helper

    private func makeInsight(
        kind: HomeInsightKind = .anomaly,
        signalType: HomeSignalType? = nil,
        category: HomeInsightCategory = .environment,
        title: String = "Titolo",
        message: String = "Messaggio",
        sourceEntityID: String? = nil,
        sourceRecordType: String? = nil,
        roomName: String? = "Stanza",
        severity: HomeInsightSeverity = .medium,
        dedupeKey: String? = nil
    ) -> HomeInsight {
        HomeInsight(
            kind: kind,
            category: category,
            signalType: signalType,
            severity: severity,
            title: title,
            message: message,
            sourceEntityID: sourceEntityID,
            roomName: roomName,
            dedupeKey: dedupeKey ?? "test|\(sourceEntityID ?? UUID().uuidString)",
            sourceRecordType: sourceRecordType
        )
    }
}
