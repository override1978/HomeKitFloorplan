import Foundation
import UIKit

/// Chi è **questo** device, in modo stabile.
///
/// Serve al censimento degli accessori: gli `uniqueIdentifier` di HomeKit sono
/// generati per device, quindi una riga del censimento tiene una colonna di UUID
/// per device e ha bisogno di una chiave per indicizzarla.
///
/// Non si usa `identifierForVendor`: si azzera quando l'utente disinstalla tutte
/// le app dello stesso sviluppatore, e un cambio di chiave farebbe risultare
/// «mai visto» un device che invece conosciamo. Qui la chiave la generiamo noi e
/// resta finché resta l'installazione — che è esattamente la durata dei dati che
/// indicizza.
enum AppDeviceIdentity {

    private static let key = "app.deviceIdentity.v1"

    static let id: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }()

    /// Nome leggibile, per dire *«catturato su iPad di Maurizio»*. Cambia se
    /// l'utente rinomina il device: si mostra, non si indicizza.
    @MainActor
    static var displayName: String { UIDevice.current.name }
}
