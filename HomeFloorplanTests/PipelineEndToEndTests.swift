import Testing
import Foundation
import SwiftData
@testable import HomeFloorplan

// MARK: - Pipeline End-to-End
//
// Il contratto dell'intera catena abitudini → automazioni:
//
//   AccessoryEvent/SensorReading (seed sintetico)
//     → BehavioralAnalysisService.analyze()
//     → BehavioralPattern → AutomationSemanticPolicy → AutomationOpportunity
//     → AutomationProposalMapper → AutomationProposal
//
// Ogni test asserisce l'ESITO FINALE (la proposal che il builder riceve),
// non gli stadi intermedi: i bug storici della pipeline vivevano tutti nelle
// giunture tra stadi che i test unitari non attraversavano.
//
// I dati arrivano da HabitScenarioFactory: stessa forma dei dati reali
// (passano da BehavioralEventPreprocessor), soglie dei gate rispettate.

@MainActor
@Suite("Pipeline End-to-End", .serialized)
struct PipelineEndToEndTests {

    // MARK: - Harness

    private func makeService(
        seeding scenarios: [HabitScenarioFactory.Scenario]
    ) throws -> BehavioralAnalysisService {
        // Riusa il container dell'app host: nel processo di test la creazione di
        // un nuovo ModelContainer fallisce sempre (loadIssueModelContainer,
        // simulatore iOS 26 — vedi DebugSupport). La suite è .serialized e ogni
        // test parte da uno store ripulito dai dati pipeline.
        let container = try #require(
            DebugSupport.modelContainer,
            "il container dell'app host deve essere esposto da HomeFloorplanApp.init"
        )
        let context = ModelContext(container)
        try resetPipelineData(in: context)
        for scenario in scenarios {
            try scenario.seed(into: context)
        }
        return BehavioralAnalysisService(modelContainer: container)
    }

    /// Azzera i dati della pipeline nello store del test host: eventi, letture,
    /// scene, pattern persistiti e opportunity — ogni test parte pulito.
    private func resetPipelineData(in context: ModelContext) throws {
        try context.delete(model: AccessoryEvent.self)
        try context.delete(model: SensorReading.self)
        try context.delete(model: ActivityEvent.self)
        try context.delete(model: AutomationOpportunity.self)
        try context.delete(model: PersistedBehavioralPattern.self)
        try context.save()
    }

    private func proposal(
        for opportunity: AutomationOpportunity,
        in service: BehavioralAnalysisService
    ) -> AutomationProposal {
        AutomationProposalMapper.proposal(
            from: opportunity,
            capabilities: HabitScenarioFactory.demoCapabilityDescriptors(),
            scenes: [],
            sourcePattern: service.patterns.first { $0.id == opportunity.patternID }
        )
    }

    /// L'opportunity pendente per un accessorio, con messaggio di fallimento parlante.
    private func pendingOpportunity(
        named accessoryName: String,
        in service: BehavioralAnalysisService
    ) -> AutomationOpportunity? {
        service.pendingOpportunities.first {
            $0.title.localizedCaseInsensitiveContains(accessoryName) ||
            $0.naturalLanguage.localizedCaseInsensitiveContains(accessoryName)
        }
    }

    /// Fotografia di pattern e opportunity per messaggi di fallimento parlanti.
    private func diagnostics(_ service: BehavioralAnalysisService) -> Comment {
        let patterns = service.patterns.map {
            "\($0.accessoryName) [\($0.patternType.rawValue)] conf=\(String(format: "%.2f", $0.confidence)) obs=\($0.observations) tier=\(String(describing: $0.tier)) status=\(String(describing: $0.status))"
        }.joined(separator: " · ")
        let opportunities = service.opportunities.map {
            "\($0.title) status=\(String(describing: $0.status)) convertible=\($0.isStructurallyConvertibleToAutomation)"
        }.joined(separator: " · ")
        return "PATTERNS: [\(patterns)] OPPORTUNITIES: [\(opportunities)]"
    }

    // MARK: - Positivi: condizione ambientale → azione coerente

    @Test("Caldo → clima acceso: proposal completa e pronta per il builder")
    func coolingHabitProducesCompleteProposal() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.coolingHabit()])
        await service.analyze()

        let pattern = service.patterns.first {
            $0.patternType == .contextual && $0.accessoryName == "Demo Clima Soggiorno"
        }
        #expect(pattern != nil, "il motore contestuale deve derivare il pattern temp→clima")

        let opportunity = try #require(
            pendingOpportunity(named: "Clima", in: service),
            diagnostics(service)
            )
        #expect(opportunity.triggerType == "characteristic")
        #expect(opportunity.triggerSensorType == SensorServiceType.temperature.rawValue)
        #expect(opportunity.triggerDirection == "above")

        let proposal = proposal(for: opportunity, in: service)
        #expect(!proposal.startEvents.isEmpty, "trigger a soglia risolto sulle capability")
        #expect(!proposal.actions.isEmpty, "l'azione sul clima non deve andare persa")
        #expect(proposal.unsupportedReason == nil)
        #expect(proposal.isReadyForBuilder, "la proposal deve arrivare al builder completa")
        #expect(proposal.limitations.isEmpty,
                "uno scenario pulito non deve produrre avvisi nel builder: \(proposal.limitations)")
    }

    @Test("Freddo → riscaldamento: proposal completa")
    func heatingHabitProducesCompleteProposal() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.heatingHabit()])
        await service.analyze()

        let opportunity = try #require(pendingOpportunity(named: "Termosifone", in: service), diagnostics(service))
        #expect(opportunity.triggerDirection == "below")

        let proposal = proposal(for: opportunity, in: service)
        #expect(!proposal.startEvents.isEmpty)
        #expect(!proposal.actions.isEmpty)
        #expect(proposal.isReadyForBuilder)
    }

    @Test("Poca luce → luci accese: proposal completa")
    func lowLuxLightsProducesCompleteProposal() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.lightsAtLowLux()])
        await service.analyze()

        let opportunity = try #require(pendingOpportunity(named: "Luce Soggiorno", in: service), diagnostics(service))
        #expect(opportunity.triggerSensorType == SensorServiceType.lightSensor.rawValue)

        let proposal = proposal(for: opportunity, in: service)
        #expect(!proposal.startEvents.isEmpty)
        #expect(!proposal.actions.isEmpty)
        #expect(proposal.isReadyForBuilder)
    }

    // MARK: - Negativo: correlazione vera ma incoerente

    @Test("Umidità → luci: correlazione osservata ma MAI promossa ad automazione")
    func spuriousCorrelationIsBlockedBySemanticPolicy() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.spuriousHumidityLights()])
        await service.analyze()

        // La correlazione può legittimamente esistere come pattern osservato…
        let pattern = service.patterns.first {
            $0.patternType == .contextual && $0.accessoryName == "Demo Luce Bagno"
        }

        // …ma la policy semantica deve bloccarla e nessuna opportunity deve nascere.
        if let pattern {
            #expect(!AutomationSemanticPolicy.allowsPromotion(pattern),
                    "umidità→luce non è semanticamente coerente")
            #expect(AutomationSemanticPolicy.reasonBlockingPromotion(pattern) != nil,
                    "il blocco deve avere un motivo mostrabile all'utente")
        }
        #expect(pendingOpportunity(named: "Luce Bagno", in: service) == nil,
                "una correlazione incoerente non deve mai diventare un'opportunity")
    }

    // MARK: - P2 v2: coppia di condizioni

    @Test("Caldo E luce alta → tenda chiusa: proposal con condizioni multiple")
    func pairConditionProducesMultiConditionProposal() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.blindPairCondition()])
        await service.analyze()

        let opportunity = try #require(pendingOpportunity(named: "Tenda", in: service), diagnostics(service))

        let proposal = proposal(for: opportunity, in: service)
        #expect(!proposal.startEvents.isEmpty)
        #expect(!proposal.actions.isEmpty)
        #expect(proposal.isReadyForBuilder)

        // Se l'opportunity porta davvero una coppia, la proposal deve conservarla:
        // entrambe le condizioni (secondaria + primaria) presenti, in AND.
        if opportunity.triggerConditionsRaw != nil {
            let accessoryConditions = proposal.conditions.filter {
                if case .accessory = $0 { return true } else { return false }
            }
            #expect(accessoryConditions.count >= 2,
                    "la coppia P2v2 non deve perdere la condizione primaria (bug A)")
            #expect(proposal.conditionJoinMode == .all)
        }
    }

    // MARK: - Regressione: percorso temporale

    @Test("Routine mattutina: il percorso temporale resta intatto")
    func morningRoutineProducesCalendarProposal() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.morningRoutine()])
        await service.analyze()

        let pattern = service.patterns.first {
            $0.patternType == .temporal && $0.accessoryName == "Demo Luce Ingresso"
        }
        #expect(pattern != nil, "orari compatti → pattern temporale, non contestuale")

        let opportunity = try #require(pendingOpportunity(named: "Luce Ingresso", in: service), diagnostics(service))
        #expect(opportunity.triggerType == "calendar")

        let proposal = proposal(for: opportunity, in: service)
        let hasSchedule = proposal.startEvents.contains {
            if case .schedule = $0 { return true } else { return false }
        }
        #expect(hasSchedule)
        #expect(!proposal.actions.isEmpty)
        #expect(proposal.isReadyForBuilder)
        // Le condizioni sono opzionali: una routine temporale senza sensori non
        // deve produrre l'avviso "does not include a complete sensor condition".
        #expect(proposal.limitations.isEmpty,
                "una routine calendar pulita non deve avere avvisi: \(proposal.limitations)")
    }

    // MARK: - Device ricco di dati (il caso reale)

    @Test("Casa con molti sensori: il rumore recente non affama la correlazione")
    func dataRichDeviceStillDerivesContextualHabits() async throws {
        let service = try makeService(seeding: [HabitScenarioFactory.coolingHabit()])

        // 7000 letture recentissime in un'altra stanza: con il vecchio limite
        // globale (6000 più recenti) espellevano l'intera baseline demo dal
        // fetch e la correlazione non trovava nulla — il sintomo osservato sul
        // device reale, dove si campiona ogni 15 minuti.
        let container = try #require(DebugSupport.modelContainer)
        let context = ModelContext(container)
        let now = Date()
        for index in 0..<7000 {
            context.insert(SensorReading(
                accessoryUUID: "filler-cucina",
                serviceType: .temperature,
                roomName: "Cucina",
                value: 22,
                timestamp: now.addingTimeInterval(-Double(index) * 20)
            ))
        }
        try context.save()

        await service.analyze()

        let opportunity = pendingOpportunity(named: "Clima", in: service)
        #expect(opportunity != nil, diagnostics(service))
    }

    // MARK: - Il percorso del bottone in-app: TUTTI gli scenari insieme

    @Test("Seed completo: gli scenari non collidono nei burst e derivano tutti")
    func allScenariosTogetherDeriveIndependentHabits() async throws {
        // Riproduce "Inietta scenari demo": senza sfasamento orario per scenario,
        // gli accessori contestuali scattavano nello stesso istante e il burst
        // detector li assorbiva come cluster-scena (osservato sul device reale).
        let service = try makeService(seeding: HabitScenarioFactory.allScenarios())
        await service.analyze()

        #expect(pendingOpportunity(named: "Clima", in: service) != nil, diagnostics(service))
        #expect(pendingOpportunity(named: "Termosifone", in: service) != nil, diagnostics(service))
        #expect(pendingOpportunity(named: "Luce Soggiorno", in: service) != nil, diagnostics(service))
        #expect(pendingOpportunity(named: "Tenda", in: service) != nil, diagnostics(service))
        #expect(pendingOpportunity(named: "Luce Ingresso", in: service) != nil, diagnostics(service))
        #expect(pendingOpportunity(named: "Luce Bagno", in: service) == nil,
                "lo spurio resta bloccato anche nel seed completo")
    }

    // MARK: - Collisione di nomi con la casa reale

    @Test("Accessorio reale omonimo: i gruppi demo non si contaminano")
    func realAccessoryWithCollidingNameDoesNotPolluteDemo() async throws {
        // Sul device reale esisteva un "Clima Soggiorno" vero: il motore raggruppa
        // per NOME, quindi i suoi eventi si mescolavano a quelli demo sporcando
        // statistiche e stanza del candidato. Il prefisso "Demo " rende la
        // collisione impossibile — questo test la ricrea e lo dimostra.
        let service = try makeService(seeding: HabitScenarioFactory.allScenarios())

        let container = try #require(DebugSupport.modelContainer)
        let context = ModelContext(container)
        let realClima = UUID()
        let now = Date()
        for index in 0..<60 {
            context.insert(AccessoryEvent(
                accessoryID: realClima,
                accessoryName: "Clima Soggiorno",
                roomName: "Soggiorno",
                state: index % 2 == 0,
                timestamp: now.addingTimeInterval(-Double(index) * 7200 - 300),
                eventType: "thermostat"
            ))
        }
        try context.save()

        await service.analyze()

        #expect(pendingOpportunity(named: "Demo Clima", in: service) != nil, diagnostics(service))
    }

    // MARK: - Isolamento: scenari combinati

    @Test("Scenari combinati: il positivo passa, lo spurio resta bloccato")
    func combinedScenariosKeepIndependentVerdicts() async throws {
        let service = try makeService(seeding: [
            HabitScenarioFactory.coolingHabit(),
            HabitScenarioFactory.spuriousHumidityLights()
        ])
        await service.analyze()

        #expect(pendingOpportunity(named: "Clima", in: service) != nil)
        #expect(pendingOpportunity(named: "Luce Bagno", in: service) == nil)
    }
}
