import Foundation
import CryptoKit

// MARK: - Indirizzamento

/// Gli `uniqueIdentifier` di HomeKit sono **generati per device** — misurato il
/// 2026-08-04 su iPad e iPhone della stessa casa: impronte diverse. Quindi in
/// uno snapshot vivono come cache veloce, mai come chiave.
///
/// L'identità vera, nell'ordine in cui va tentata:
/// 1. **numero di serie** — hardware, sopravvive a rinomina, spostamento e
///    ri-accoppiamento. Copre il 77% di un impianto reale da 128 accessori.
/// 2. **produttore + modello + stanza**, quando in quella stanza non c'è un
///    gemello identico. Copre un altro 20%.
/// 3. **il nome**, che l'utente può cambiare in qualsiasi momento. Resta il 3%.
struct AccessoryAddress: Codable, Hashable, Sendable {
    let serialNumber: String?
    let manufacturer: String?
    let model: String?
    let name: String
    let roomName: String?
    let category: String
    let isBridged: Bool
    let localUUID: String?
}

struct RoomAddress: Codable, Hashable, Sendable {
    let name: String
    let localUUID: String?
}

/// `serviceType` da solo non basta: un accessorio può esporre più servizi dello
/// stesso tipo — `MultiOutletAdapter` filtra proprio così le prese di una
/// multipresa — quindi serve l'ordinale fra quelli omonimi.
struct ServiceAddress: Codable, Hashable, Sendable {
    let serviceType: String
    let ordinal: Int
    let name: String?
    let isPrimary: Bool
    let localUUID: String?
}

/// HAP garantisce che un `characteristicType` sia unico **dentro** un servizio:
/// accessorio + servizio + tipo è quindi una chiave totale.
struct CharacteristicAddress: Codable, Hashable, Sendable {
    let accessory: AccessoryAddress
    let service: ServiceAddress
    let characteristicType: String
}

// MARK: - Valori

/// `HMCharacteristicWriteAction.targetValue` è `Any?`. Scrivere un `Double` dove
/// HomeKit aspetta un `UInt8` fallisce in scrittura, quindi il tipo va salvato
/// insieme al valore — e il formato serve a ricostruire l'`NSNumber` giusto.
enum SnapshotValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// Valore che l'app non sa rappresentare: si mostra, non si riscrive.
    case unsupported(description: String)
}

struct CharacteristicFormatHint: Codable, Hashable, Sendable {
    let format: String?
    let units: String?
    let minimumValue: Double?
    let maximumValue: Double?
    let stepValue: Double?
}

// MARK: - Elementi

struct RoomSnapshot: Codable, Sendable {
    let address: RoomAddress
    /// Ridondanza voluta: rende leggibile il confronto senza risolvere nulla.
    let accessoryNames: [String]
}

struct ZoneSnapshot: Codable, Sendable {
    let name: String
    let roomNames: [String]
    let localUUID: String?
}

struct ServiceGroupSnapshot: Codable, Sendable {
    let name: String
    let serviceCount: Int
    let localUUID: String?
}

struct CharacteristicSnapshot: Codable, Sendable {
    let characteristicType: String
    let properties: [String]
    let format: CharacteristicFormatHint?
}

struct ServiceSnapshot: Codable, Sendable {
    let address: ServiceAddress
    let characteristics: [CharacteristicSnapshot]
}

struct AccessorySnapshot: Codable, Sendable {
    let address: AccessoryAddress
    /// Sola lettura, ma è **il** dato di manutenzione: sapere che il firmware di
    /// un accessorio è cambiato il 3 agosto vale più del numero in sé.
    let firmwareVersion: String?
    let services: [ServiceSnapshot]
}

struct SceneActionSnapshot: Codable, Sendable {
    let target: CharacteristicAddress
    let value: SnapshotValue
    let format: CharacteristicFormatHint?
}

struct SceneSnapshot: Codable, Sendable {
    let name: String
    let actionSetType: String
    let isBuiltIn: Bool
    let localUUID: String?
    let actions: [SceneActionSnapshot]
    /// Azioni che non sono scritture di caratteristica: si contano, non si
    /// possono catturare.
    let foreignActionCount: Int
}

/// Le automazioni si catturano come **documentazione**, non per ripristinarle.
///
/// Misurato sull'impianto di riferimento: su 78 automazioni, 39 eseguono
/// `HMShortcutAction` — una classe che non esiste nell'SDK pubblico, quindi
/// nessuna app di terze parti può leggerla, ricrearla o ripristinarla. Un
/// ripristino coprirebbe il 40%, e un ripristino di cui ci si fida per due
/// automazioni su cinque non verrebbe usato. Quindi qui si salva ciò che serve
/// a **ricostruirle a mano**: com'è fatto il trigger, cosa esegue, e perché.
struct AutomationSnapshot: Codable, Sendable {
    enum Content: String, Codable, Sendable {
        /// Esegue una scena vera: ripristinabile.
        case scene
        /// Azioni attaccate al trigger ma leggibili: migrabili a scena.
        case readableInlineActions
        /// Esegue uno Shortcut: fuori portata per chiunque.
        case shortcut
        /// Nessuna azione: il trigger scatta a vuoto.
        case empty
        /// Altro non identificato.
        case other
    }

    let name: String
    let localUUID: String?
    let isEnabled: Bool
    let triggerKind: String
    let content: Content
    /// Descrizione in lingua del trigger e delle sue condizioni. È ciò che
    /// rende utile lo snapshot anche quando il ripristino è impossibile.
    let humanSummary: String
    let conditionSummaries: [String]
    let actionSetNames: [String]
    let actions: [SceneActionSnapshot]
}

// MARK: - Lo snapshot

struct HomeConfigurationSnapshot: Codable, Sendable {

    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let capturedAt: Date
    let capturedOnDevice: String
    let appVersion: String

    let homeName: String
    let homeUUID: String?

    let rooms: [RoomSnapshot]
    let zones: [ZoneSnapshot]
    let serviceGroups: [ServiceGroupSnapshot]
    let accessories: [AccessorySnapshot]
    let scenes: [SceneSnapshot]
    let automations: [AutomationSnapshot]

    var counts: Counts {
        Counts(
            rooms: rooms.count,
            zones: zones.count,
            serviceGroups: serviceGroups.count,
            accessories: accessories.count,
            scenes: scenes.count,
            automations: automations.count
        )
    }

    struct Counts: Codable, Sendable, Equatable {
        let rooms: Int
        let zones: Int
        let serviceGroups: Int
        let accessories: Int
        let scenes: Int
        let automations: Int
    }

    /// Quota di accessori identificabili **senza dipendere dal nome**. Viaggia
    /// con lo snapshot perché è ciò che dice quanto è ripristinabile su un
    /// device diverso da quello che l'ha catturato.
    var reliableIdentityCoverage: Double {
        guard !accessories.isEmpty else { return 0 }
        var stableKeyCounts: [String: Int] = [:]
        for accessory in accessories where (accessory.address.serialNumber ?? "").isEmpty {
            stableKeyCounts[accessory.address.stableKey, default: 0] += 1
        }
        let reliable = accessories.filter { accessory in
            if !(accessory.address.serialNumber ?? "").isEmpty { return true }
            return stableKeyCounts[accessory.address.stableKey] == 1
        }
        return Double(reliable.count) / Double(accessories.count)
    }
}

extension AccessoryAddress {
    /// Chiave del livello «stabile»: produttore + modello + stanza.
    var stableKey: String {
        [manufacturer, model, roomName]
            .map { $0?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" }
            .joined(separator: "|")
    }
}

// MARK: - Impronta della configurazione

extension HomeConfigurationSnapshot {

    /// Impronta di **ciò che è configurazione**, e di nient'altro.
    ///
    /// Serve a non creare uno snapshot nuovo quando in casa non è cambiato
    /// niente. Non si può calcolare sul JSON dello snapshot: quello contiene
    /// `id` e `capturedAt`, che cambiano sempre, ed è risultato variare anche
    /// per conto suo — catture della stessa casa immutata hanno prodotto 68, 70
    /// e 93 KB compressi. Bastava quello a impedire per sempre alla deduplica
    /// di scattare.
    ///
    /// Qui invece si costruisce una proiezione testuale **canonica**: solo i
    /// campi che descrivono la configurazione, ogni raccolta ordinata, niente
    /// UUID locali (cambiano da device a device) e niente metadati delle
    /// caratteristiche, che HomeKit popola man mano che legge e che quindi
    /// dipendono da cosa è successo prima.
    var configurationFingerprint: String {
        var lines: [String] = []

        lines.append("home|\(homeName)")

        for room in rooms.sorted(by: { $0.address.name < $1.address.name }) {
            lines.append("room|\(room.address.name)|\(room.accessoryNames.sorted().joined(separator: ","))")
        }
        for zone in zones.sorted(by: { $0.name < $1.name }) {
            lines.append("zone|\(zone.name)|\(zone.roomNames.sorted().joined(separator: ","))")
        }
        for group in serviceGroups.sorted(by: { $0.name < $1.name }) {
            lines.append("group|\(group.name)|\(group.serviceCount)")
        }

        for accessory in accessories.sorted(by: { $0.address.name < $1.address.name }) {
            let a = accessory.address
            lines.append([
                "acc", a.name, a.roomName ?? "", a.serialNumber ?? "",
                a.manufacturer ?? "", a.model ?? "", a.category,
                accessory.firmwareVersion ?? ""
            ].joined(separator: "|"))
            // Dei servizi conta la forma, non i metadati: tipo, ordinale e quali
            // caratteristiche espone.
            for service in accessory.services.sorted(by: { ($0.address.serviceType, $0.address.ordinal) < ($1.address.serviceType, $1.address.ordinal) }) {
                lines.append("svc|\(a.name)|\(service.address.serviceType)|\(service.address.ordinal)|"
                             + service.characteristics.map(\.characteristicType).sorted().joined(separator: ","))
            }
        }

        for scene in scenes.sorted(by: { $0.name < $1.name }) {
            lines.append("scene|\(scene.name)|\(scene.actionSetType)|\(scene.foreignActionCount)")
            for action in scene.actions.sorted(by: { $0.sortKey < $1.sortKey }) {
                lines.append("act|\(scene.name)|\(action.sortKey)|\(action.value.canonicalText)")
            }
        }

        for automation in automations.sorted(by: { $0.name < $1.name }) {
            lines.append([
                "auto", automation.name, automation.triggerKind,
                automation.content.rawValue, String(automation.isEnabled),
                automation.humanSummary,
                automation.conditionSummaries.sorted().joined(separator: ";"),
                automation.actionSetNames.sorted().joined(separator: ";")
            ].joined(separator: "|"))
        }

        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SceneActionSnapshot {
    /// Ordinamento e identità dell'azione senza UUID locali.
    var sortKey: String {
        [target.accessory.name, target.service.serviceType,
         String(target.service.ordinal), target.characteristicType].joined(separator: "/")
    }
}

extension SnapshotValue {
    var canonicalText: String {
        switch self {
        case .bool(let value):   "b:\(value)"
        case .int(let value):    "i:\(value)"
        // Arrotondato: HomeKit restituisce a volte 45.0 e a volte 45.000001 per
        // lo stesso valore, e una differenza invisibile non deve far risultare
        // cambiata una scena.
        case .double(let value): "d:\(String(format: "%.4f", value))"
        case .string(let value): "s:\(value)"
        case .unsupported(let description): "u:\(description)"
        }
    }
}
