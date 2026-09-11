import Foundation

// MARK: - LocalDataProtection

enum LocalDataProtection {
    nonisolated static let preserveSwiftDataKey = "localData.preserveSwiftData"

    /// Se true, nessuna potatura tocca i record SwiftData locali.
    ///
    /// Il default era `true` — rete di sicurezza alzata durante una migrazione
    /// e mai riabbassata. Con quel valore il ciclo dati aggregava ma non potava
    /// mai, quindi l'archivio pagava contemporaneamente il grezzo e i summary:
    /// 166.555 letture misurate sul primario, in crescita indefinita.
    ///
    /// Ora il default è `false`, cioè il comportamento progettato — trenta
    /// giorni di grezzo, la conoscenza nei summary permanenti. La chiave
    /// assente significa "l'utente non ha mai scelto"; `@AppStorage` non
    /// scrive in lettura, quindi chi ha spostato l'interruttore a mano ha una
    /// chiave presente e la sua scelta viene rispettata.
    nonisolated static var shouldPreserveSwiftData: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: preserveSwiftDataKey) != nil else { return false }
        return defaults.bool(forKey: preserveSwiftDataKey)
    }
}
