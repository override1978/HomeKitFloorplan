import Foundation
import SwiftData
import SwiftUI
import HomeKit

// MARK: - FloorplanInsightActions

/// Azioni one-tap sulle situazioni AI mostrate sulla planimetria (fase 5).
///
/// Stessa semantica del dashboard Intelligence: eseguire la correttiva risolve
/// subito gli insight attivi dell'accessorio (resolve ottimistico — se il
/// comando non avesse avuto effetto reale, il ciclo successivo li ri-solleva);
/// lo snooze li silenzia per la finestra che l'upsert del ciclo preserva.
@MainActor
enum FloorplanInsightActions {

    /// La correttiva one-tap della situation, se il suo insight primario ne
    /// trasporta una eseguibile. Nil = nessuna CTA.
    static func correctiveAction(for situation: HomeSituation) -> AINextAction? {
        guard let action = situation.primary.suggestedActionJSON
            .flatMap({ $0.data(using: .utf8) })
            .flatMap({ try? JSONDecoder().decode(AINextAction.self, from: $0) }),
              action.actionType == "executeNow",
              action.accessoryID?.isEmpty == false else {
            return nil
        }
        return action
    }

    @discardableResult
    static func execute(
        _ action: AINextAction,
        homeKit: HomeKitService,
        executionService: ActionExecutionService,
        records: [PersistedHomeInsight],
        modelContext: ModelContext
    ) async -> Bool {
        guard let home = homeKit.currentHome else { return false }
        let success = await executionService.executeRaw(action, in: home)
        if success {
            resolveActive(records: records, accessoryID: action.accessoryID, modelContext: modelContext)
        }
        return success
    }

    private static func resolveActive(
        records: [PersistedHomeInsight],
        accessoryID: String?,
        modelContext: ModelContext
    ) {
        guard let accessoryID, !accessoryID.isEmpty else { return }
        let now = Date()
        for record in records where record.sourceEntityID == accessoryID {
            record.statusRaw = HomeInsightStatus.resolved.rawValue
            record.resolvedAt = now
            record.updatedAt = now
        }
        try? modelContext.save()
    }

    /// Silenzia tutti gli insight della situation (status snoozed, 24h come
    /// dal dashboard: l'upsert del ciclo lo preserva per la finestra di snooze).
    static func snooze(
        _ situation: HomeSituation,
        records: [PersistedHomeInsight],
        modelContext: ModelContext
    ) {
        let keys = Set(situation.insights.map(\.dedupeKey))
        let now = Date()
        for record in records where keys.contains(record.dedupeKey) {
            record.statusRaw = HomeInsightStatus.snoozed.rawValue
            record.updatedAt = now
        }
        try? modelContext.save()
    }
}

// MARK: - SecurityInPlaceAction

/// L'unica azione di sicurezza eseguibile per una stanza, quando esiste.
///
/// Sulla planimetria non compaiono azioni finte: un sensore contatto aperto si
/// risolve chiudendo la porta fisica, quindi non produce nessuna azione — la
/// stanza mostra solo lo stato e si spegne da sola quando il sensore riporta
/// chiuso. Le azioni reali: disattivare un allarme scattato, bloccare una
/// serratura sbloccata, chiudere un garage aperto, armare in Notte l'allarme
/// disarmato nelle ore notturne (le stesse quattro che gli insight già
/// suggerivano a parole — le etichette sono le loro). Regola del design: al
/// massimo UNA per stanza, la più urgente.
struct SecurityInPlaceAction: Identifiable {
    let id: UUID
    let label: String
    let symbol: String
    let color: Color
    let run: @MainActor () async throws -> Void
}

@MainActor
enum SecurityInPlaceActionResolver {

    /// L'azione più urgente per gli accessori di una stanza, o nil.
    /// Allarme scattato prima di tutto, poi serrature, garage e infine
    /// l'armamento notturno; gli accessori in transizione sono esclusi —
    /// l'azione è già in volo.
    static func action(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> SecurityInPlaceAction? {
        var lockAction: SecurityInPlaceAction? = nil
        var garageAction: SecurityInPlaceAction? = nil
        var armNightAction: SecurityInPlaceAction? = nil

        for accessory in accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)

            if let system = adapter as? SecuritySystemAdapter {
                if system.isTriggered {
                    return SecurityInPlaceAction(
                        id: accessory.uniqueIdentifier,
                        label: String(localized: "security.insight.action.disarm", defaultValue: "Disarm the system"),
                        symbol: "shield.slash.fill",
                        color: FloorplanTokens.Semantic.critical,
                        run: { try await system.setMode(.disarm) }
                    )
                }
                // Stessa finestra dell'insight "disarmato di notte" (22–06,
                // SecurityScoreService): fuori da lì un allarme disarmato è
                // normale vita in casa, non un'azione da suggerire.
                if armNightAction == nil, system.currentMode == .disarm {
                    let hour = Calendar.current.component(.hour, from: Date())
                    if hour >= 22 || hour < 6 {
                        armNightAction = SecurityInPlaceAction(
                            id: accessory.uniqueIdentifier,
                            label: String(localized: "security.insight.action.armNight", defaultValue: "Enable Night Mode"),
                            symbol: "moon.stars.fill",
                            color: FloorplanTokens.Mode.accent(.security),
                            run: { try await system.setMode(.night) }
                        )
                    }
                }
            }

            if lockAction == nil,
               let lock = adapter as? DoorLockAdapter,
               lock.currentState == .unsecured,
               !lock.isTransitioning {
                lockAction = SecurityInPlaceAction(
                    id: accessory.uniqueIdentifier,
                    label: String(localized: "security.insight.action.lockDoor", defaultValue: "Lock the door"),
                    symbol: "lock.fill",
                    color: FloorplanTokens.Semantic.warning,
                    run: { try await lock.setLocked(true) }
                )
            }

            if garageAction == nil,
               let garage = adapter as? GarageDoorAdapter,
               garage.currentState == .open || garage.currentState == .stopped,
               !garage.isTransitioning {
                garageAction = SecurityInPlaceAction(
                    id: accessory.uniqueIdentifier,
                    label: String(localized: "security.insight.action.closeGarage", defaultValue: "Close the garage"),
                    symbol: "door.garage.closed",
                    color: FloorplanTokens.Semantic.warning,
                    run: { try await garage.setOpen(false) }
                )
            }
        }

        return lockAction ?? garageAction ?? armNightAction
    }
}
