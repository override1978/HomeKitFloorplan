import Foundation
import HomeKit

// MARK: - ExistingAutomationSnapshot

/// Fotografia di un'automazione HomeKit esistente, ridotta ai campi necessari
/// per il confronto anti-duplicazione delle opportunità comportamentali.
struct ExistingAutomationSnapshot {
    let name: String
    let isEnabled: Bool
    /// Accessori toccati dalle action set dell'automazione.
    let targetAccessoryIDs: Set<UUID>
    /// Nomi delle scene (action set) eseguite dall'automazione.
    let triggeredSceneNames: Set<String>
    /// Minuto del giorno (0–1439) per i trigger orari; nil per gli event-trigger.
    let fireMinuteOfDay: Int?
}

// MARK: - AutomationDuplicateChecker

/// Confronto pattern ↔ automazioni HomeKit esistenti: il motore abitudini non deve
/// proporre ciò che l'utente ha già automatizzato. Senza questo controllo il motore
/// impara dagli eventi generati dalle automazioni stesse (perfettamente regolari)
/// e ripropone all'utente esattamente ciò che già possiede.
// MARK: - Snapshot builder (HomeKit)

extension ExistingAutomationSnapshot {

    /// Costruisce le fotografie da `HMHome.triggers` (MainActor: tocca oggetti HomeKit).
    /// Chiamata a ogni analisi comportamentale, così automazioni aggiunte/rimosse
    /// vengono sempre viste fresche.
    @MainActor
    static func snapshots(from home: HMHome?) -> [ExistingAutomationSnapshot] {
        guard let home else { return [] }

        return home.triggers.map { trigger in
            var accessoryIDs: Set<UUID> = []
            var sceneNames: Set<String> = []

            for actionSet in trigger.actionSets {
                sceneNames.insert(actionSet.name)
                for action in actionSet.actions {
                    if let write = action as? HMCharacteristicWriteAction<NSCopying>,
                       let accessory = write.characteristic.service?.accessory {
                        accessoryIDs.insert(accessory.uniqueIdentifier)
                    }
                }
            }

            var fireMinute: Int?
            if let timer = trigger as? HMTimerTrigger {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: timer.fireDate)
                fireMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }

            return ExistingAutomationSnapshot(
                name: trigger.name,
                isEnabled: trigger.isEnabled,
                targetAccessoryIDs: accessoryIDs,
                triggeredSceneNames: sceneNames,
                fireMinuteOfDay: fireMinute
            )
        }
    }
}
