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
enum AutomationDuplicateChecker {

    /// Tolleranza per considerare "stesso orario" un timer-trigger esistente.
    static let timerToleranceMinutes = 45

    /// Nome dell'automazione esistente che copre già il pattern temporale, nil se nessuna.
    ///
    /// - Timer-trigger sullo stesso accessorio: coperto se l'orario dista ≤ tolleranza
    ///   (confronto circolare: 23:50 e 00:20 distano 30 minuti, non 1410).
    /// - Event-trigger sullo stesso accessorio: coperto a prescindere dall'orario —
    ///   l'accessorio è già automatizzato reattivamente e il pattern osservato
    ///   è quasi certamente l'eco di quell'automazione.
    static func automationCovering(
        accessoryID: UUID,
        avgMinuteOfDay: Int,
        in snapshots: [ExistingAutomationSnapshot]
    ) -> String? {
        for snapshot in snapshots where snapshot.isEnabled && snapshot.targetAccessoryIDs.contains(accessoryID) {
            guard let fireMinute = snapshot.fireMinuteOfDay else {
                return snapshot.name
            }
            let diff = abs(fireMinute - avgMinuteOfDay)
            let circularDiff = min(diff, 1440 - diff)
            if circularDiff <= timerToleranceMinutes {
                return snapshot.name
            }
        }
        return nil
    }

    /// Nome dell'automazione esistente che esegue già questa scena, nil se nessuna.
    /// Un burst-cluster che matcha una scena già schedulata non ha nulla da proporre.
    static func automationTriggering(
        sceneName: String,
        in snapshots: [ExistingAutomationSnapshot]
    ) -> String? {
        let normalized = sceneName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return snapshots.first { snapshot in
            snapshot.isEnabled && snapshot.triggeredSceneNames.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
            }
        }?.name
    }
}

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
