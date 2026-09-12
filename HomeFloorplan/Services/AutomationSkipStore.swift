import Foundation
import Observation

// MARK: - AutomationSkipStore

/// «Stasera no»: salta il prossimo scatto di un'automazione senza spegnerla.
///
/// Serve perché il momento in cui si perde fiducia in una casa che si muove da
/// sola è quando fa una cosa che non volevi — e la reazione naturale è
/// disattivare l'automazione **per sempre**, buttando via anche tutte le volte
/// in cui andava bene. Un rifiuto che dura una sera sola salva l'automazione
/// invece di ucciderla.
///
/// HomeKit non ha un «salta la prossima volta»: si può solo disabilitare il
/// trigger e riabilitarlo dopo. Il ripristino quindi dipende da questa app, e
/// questa è la fragilità da guardare in faccia: se il pannello resta spento per
/// giorni, quell'automazione resta disattivata. Tre difese, in ordine di
/// importanza.
///
/// La prima: la scadenza è **persistita**, non tenuta in memoria, quindi
/// sopravvive a chiusure e riavvii. La seconda: il ripristino si tenta a ogni
/// avvio e a ogni ritorno in primo piano, non su un timer che può non scattare.
/// La terza, che è quella che conta davvero: l'interfaccia mostra il momento
/// saltato **come saltato** invece di farlo sparire, così uno stato anomalo che
/// duri resta visibile e non diventa un mistero silenzioso.
@Observable
@MainActor
final class AutomationSkipStore {

    /// Salti attivi: identificativo del trigger → istante oltre il quale
    /// l'automazione va riaccesa.
    private(set) var skips: [String: Date] = [:]

    private static let storageKey = "automations.skippedUntil"

    /// Margine oltre l'orario di scatto prima di riaccendere.
    ///
    /// Riabilitare esattamente all'istante previsto rischia di far partire
    /// comunque l'automazione: HomeKit valuta i trigger con una tolleranza, e
    /// un ripristino puntuale potrebbe cadere dentro quella finestra. Cinque
    /// minuti sono abbastanza per essere sicuri e abbastanza pochi perché la
    /// prossima occorrenza — che per una giornaliera è ventiquattro ore dopo —
    /// non venga mai persa.
    static let restoreGrace: TimeInterval = 5 * 60

    init() { load() }

    // MARK: - Lettura

    func isSkipped(_ triggerID: String, now: Date = Date()) -> Bool {
        guard let until = skips[triggerID] else { return false }
        return until > now
    }

    func skipExpiry(_ triggerID: String) -> Date? { skips[triggerID] }

    // MARK: - Scrittura

    /// Registra un salto fino a poco dopo l'orario indicato.
    ///
    /// Non tocca HomeKit: disabilitare il trigger è responsabilità del
    /// chiamante, che è l'unico a poterlo fare in modo asincrono e a poter
    /// gestire un errore. Qui si tiene solo la memoria di quando disfare.
    func recordSkip(_ triggerID: String, firingAt fire: Date) {
        skips[triggerID] = fire.addingTimeInterval(Self.restoreGrace)
        save()
    }

    /// Toglie un salto, dopo che il trigger è stato riacceso.
    func clearSkip(_ triggerID: String) {
        guard skips.removeValue(forKey: triggerID) != nil else { return }
        save()
    }

    /// Gli identificativi dei salti scaduti: vanno riaccesi.
    func expiredTriggerIDs(now: Date = Date()) -> [String] {
        skips.filter { $0.value <= now }.map(\.key)
    }

    // MARK: - Persistenza

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) else { return }
        skips = raw.compactMapValues { $0 as? Date }
    }

    private func save() {
        UserDefaults.standard.set(skips, forKey: Self.storageKey)
    }
}
