import Foundation
import SwiftData

// MARK: - KnownAccessory

/// Il censimento: **cosa l'app ha visto in questa casa, e da quando**.
///
/// Esiste per una ragione che nessuna API può sostituire: HomeKit non dice
/// quando un accessorio è stato aggiunto. Senza una tabella che se lo ricordi
/// non è calcolabile la coincidenza temporale — *«questo è sparito il 1 agosto,
/// quello è comparso il 2»* — che è il segnale più discriminante per riconoscere
/// un accessorio rimosso e ri-accoppiato, più del nome e più del modello.
///
/// L'identità qui è **nostra** (`id`), non di HomeKit: gli `uniqueIdentifier`
/// sono generati per device — misurato su iPad e iPhone della stessa casa — e
/// quindi vivono in `deviceUUIDs` come una colonna per device, mai come chiave.
/// È anche ciò che rende la tabella un risolutore cross-device: la corrispondenza
/// fra i due device si scrive una volta invece di essere indovinata a ogni
/// accesso.
@Model
final class KnownAccessory {

    @Attribute(.unique) var id: UUID

    // MARK: Identità osservata

    /// HAP `00000030`. L'unica identità hardware: sopravvive a rinomina,
    /// spostamento e ri-accoppiamento. Sull'impianto di riferimento copre il 77%.
    var serialNumber: String?
    var manufacturer: String?
    var model: String?
    var name: String
    var roomName: String?
    var category: String
    var isBridged: Bool

    // MARK: Storia

    var firstSeenAt: Date
    var lastSeenAt: Date

    /// Riga creata censendo una casa già esistente, non osservandone la nascita.
    /// `firstSeenAt` allora **non è** una data di aggiunta, ed è una distinzione
    /// che va tenuta: su una funzione che si regge sulle date, spacciarne una
    /// inventata la avvelena. La UI dice «osservato da», non «aggiunto il».
    var isSeeded: Bool

    /// Valorizzato quando l'accessorio sparisce da HomeKit. Non è una
    /// cancellazione: una riga ritirata è esattamente ciò che serve per
    /// riconoscerlo se torna.
    var retiredAt: Date?

    // MARK: Dati serializzati

    /// `[deviceID: uuidString]` — l'`uniqueIdentifier` che **quel** device usa.
    var deviceUUIDsJSON: Data?

    init(name: String,
         serialNumber: String? = nil,
         manufacturer: String? = nil,
         model: String? = nil,
         roomName: String? = nil,
         category: String = "",
         isBridged: Bool = false,
         localUUID: UUID? = nil,
         isSeeded: Bool,
         now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.serialNumber = serialNumber
        self.manufacturer = manufacturer
        self.model = model
        self.roomName = roomName
        self.category = category
        self.isBridged = isBridged
        self.firstSeenAt = now
        self.lastSeenAt = now
        self.isSeeded = isSeeded
        self.retiredAt = nil
        if let localUUID {
            self.deviceUUIDs = [AppDeviceIdentity.id: localUUID]
        }
    }
}

// MARK: - Accessori calcolati

extension KnownAccessory {

    var isRetired: Bool { retiredAt != nil }

    var deviceUUIDs: [String: UUID] {
        get {
            guard let deviceUUIDsJSON,
                  let raw = try? JSONDecoder().decode([String: String].self, from: deviceUUIDsJSON)
            else { return [:] }
            return raw.compactMapValues(UUID.init(uuidString:))
        }
        set {
            deviceUUIDsJSON = try? JSONEncoder().encode(newValue.mapValues(\.uuidString))
        }
    }

    /// L'UUID HomeKit su questo device, se lo conosciamo.
    var localUUID: UUID? { deviceUUIDs[AppDeviceIdentity.id] }

    func recordLocalUUID(_ uuid: UUID) {
        var map = deviceUUIDs
        guard map[AppDeviceIdentity.id] != uuid else { return }
        map[AppDeviceIdentity.id] = uuid
        deviceUUIDs = map
    }

    /// Chiave del livello «stabile»: produttore + modello + stanza. Da usare
    /// come **disambiguatore**, non come chiave — è proprio quella che collide
    /// quando in una stanza ci sono due dispositivi identici.
    var stableKey: String {
        [manufacturer, model, roomName]
            .map { $0?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" }
            .joined(separator: "|")
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
