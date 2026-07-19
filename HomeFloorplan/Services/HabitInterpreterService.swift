import Foundation
import SwiftData
import HomeKit

/// Livello B del pivot Abitudini: l'interprete LLM.
///
/// Su richiesta (bottone in HabitsView) riassume l'uso reale della casa via
/// `HabitInterpreterCore`, chiede al modello poche proposte ad alta evidenza
/// e le espone come `RoutineSuggestion`; il tap dell'utente le trasforma in
/// proposte per il wizard esistente. Gated sulle impostazioni AI.
@MainActor
@Observable
final class HabitInterpreterService {

    private let aiSettings: AISettings
    private let modelContainer: ModelContainer
    private let homeKit: HomeKitService
    private let aiService: AIService

    private(set) var suggestions: [HabitInterpreterCore.RoutineSuggestion] = []
    private(set) var isAnalyzing = false
    private(set) var lastError: String?
    private(set) var lastRunAt: Date?

    init(aiSettings: AISettings,
         modelContainer: ModelContainer,
         homeKit: HomeKitService,
         aiService: AIService? = nil) {
        self.aiSettings = aiSettings
        self.modelContainer = modelContainer
        self.homeKit = homeKit
        self.aiService = aiService ?? AIService(settings: aiSettings)
    }

    var isAvailable: Bool {
        aiSettings.isOperational && aiSettings.suggestionsEnabled
    }

    /// Esegue un ciclo di interpretazione (su richiesta esplicita dell'utente).
    func interpret(days: Int = 14) async {
        guard isAvailable, !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let events = UsageEvidenceService.samples(modelContainer: modelContainer, days: days)
        let existing = ExistingAutomationSnapshot.snapshots(from: homeKit.currentHome)
            .map(\.name)

        let summary = HabitInterpreterCore.buildUsageSummary(
            events: events,
            existingAutomations: existing
        )

        guard !summary.isEmpty else {
            suggestions = []
            lastError = nil
            lastRunAt = Date()
            return
        }

        do {
            let response = try await aiService.sendPrompt(
                systemPrompt: HabitInterpreterCore.systemPrompt,
                userPrompt: summary
            )
            suggestions = HabitInterpreterCore.parseSuggestions(response)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastRunAt = Date()
    }

    /// Risolve il nome accessorio proposto dal modello in un UUID HomeKit
    /// (match per nome normalizzato — stesso criterio del sync CloudKit).
    func resolveAccessoryID(named name: String) -> UUID? {
        HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(),
            accessoryName: name,
            roomName: nil,
            in: homeKit.allAccessories.map {
                HomeKitEntityResolver.AccessoryRef(
                    uuid: $0.uniqueIdentifier,
                    name: $0.name,
                    roomName: $0.room?.name
                )
            }
        )
    }

    func dismiss(_ suggestion: HabitInterpreterCore.RoutineSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
    }
}
