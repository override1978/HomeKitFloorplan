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
/// chiuso. Le azioni reali sono due: bloccare una serratura sbloccata e
/// chiudere un garage aperto. Regola del design: al massimo UNA per stanza,
/// la più urgente.
struct SecurityInPlaceAction: Identifiable {
    let id: UUID
    let label: String
    let symbol: String
    let deviceName: String
    let run: @MainActor () async throws -> Void
}

@MainActor
enum SecurityInPlaceActionResolver {

    /// L'azione più urgente per gli accessori di una stanza, o nil.
    /// Serrature prima dei garage (una porta d'ingresso sbloccata pesa di più);
    /// gli accessori in transizione sono esclusi — l'azione è già in volo.
    static func action(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> SecurityInPlaceAction? {
        var garageAction: SecurityInPlaceAction? = nil

        for accessory in accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)

            if let lock = adapter as? DoorLockAdapter,
               lock.currentState == .unsecured,
               !lock.isTransitioning {
                return SecurityInPlaceAction(
                    id: accessory.uniqueIdentifier,
                    label: String(localized: "security.inPlace.lock", defaultValue: "Lock"),
                    symbol: "lock.fill",
                    deviceName: accessory.name,
                    run: { try await lock.setLocked(true) }
                )
            }

            if garageAction == nil,
               let garage = adapter as? GarageDoorAdapter,
               garage.currentState == .open || garage.currentState == .stopped,
               !garage.isTransitioning {
                garageAction = SecurityInPlaceAction(
                    id: accessory.uniqueIdentifier,
                    label: String(localized: "security.inPlace.close", defaultValue: "Close"),
                    symbol: "door.garage.closed",
                    deviceName: accessory.name,
                    run: { try await garage.setOpen(false) }
                )
            }
        }

        return garageAction
    }
}
