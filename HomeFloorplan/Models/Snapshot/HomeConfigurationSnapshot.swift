import Foundation
import CryptoKit
import HomeKit

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
    /// Come la chiama il sistema — «Luminosità», «Stato antifurto» — già
    /// tradotta. Meglio di una mappa di UUID scritta a mano: quella copre
    /// dodici casi e sbaglia sui restanti, questa arriva da HomeKit ed è giusta
    /// per definizione. Solo presentazione: l'identità resta il tipo.
    let characteristicName: String?
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

/// Quale servizio sta dentro un gruppo, non solo quanti.
struct ServiceGroupMemberSnapshot: Codable, Sendable {
    let accessoryName: String
    let accessorySerialNumber: String?
    let serviceType: String
    let ordinal: Int
    let serviceName: String?
}

struct ServiceGroupSnapshot: Codable, Sendable {
    let name: String
    let serviceCount: Int
    let localUUID: String?
    let members: [ServiceGroupMemberSnapshot]
}

struct CharacteristicSnapshot: Codable, Sendable {
    let characteristicType: String
    let properties: [String]
    let format: CharacteristicFormatHint?
}

struct ServiceSnapshot: Codable, Sendable {
    let address: ServiceAddress
    let characteristics: [CharacteristicSnapshot]
    /// È ciò che fa mostrare una presa come luce: senza, un accessorio
    /// ripristinato si presenta diverso da com'era.
    let associatedServiceType: String?
    let isUserInteractive: Bool
}

struct AccessorySnapshot: Codable, Sendable {
    let address: AccessoryAddress
    /// Da quale bridge è esposto. Serve al caso che rende un ri-accoppiamento
    /// incomprensibile: trenta accessori spariti tutti insieme, e senza questo
    /// non c'è modo di sapere che erano dello stesso.
    let bridgeName: String?
    let bridgeSerialNumber: String?
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
    /// Contenitore creato da un trigger — `HF Actions - …` — non una scena che
    /// qualcuno ha fatto. Porta un suffisso casuale nel nome, quindi non va né
    /// mostrato né confrontato: risulterebbe diverso a ogni ricreazione.
    ///
    let isTriggerOwned: Bool
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
    /// Presente **solo** per le automazioni che l'app sa davvero ricreare.
    /// Il resto di questa struttura è documentazione; questo è materiale.
    let restorable: RestorableAutomation?
    /// Perché non è ricreabile, registrato al momento della cattura. Dedurlo
    /// dopo, guardando il tipo di contenuto, produce spiegazioni false.
    let notRestorableReason: String?
}

// MARK: - Lo snapshot

struct HomeConfigurationSnapshot: Codable, Sendable {

    /// 2 — nomi delle caratteristiche dal sistema, membri dei gruppi di
    /// servizi, bridge di ogni accessorio, forma ricreabile delle automazioni.
    ///
    /// Uno snapshot più vecchio si apre lo stesso, ma di quei campi non ha
    /// niente: al posto dei nomi mostra identificatori grezzi, e senza saperlo
    /// sembra un difetto invece che una cattura fatta prima.
    static let currentFormatVersion = 2

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

    /// Le scene **che qualcuno ha creato**. Fuori i contenitori generati dai
    /// trigger per tenere le azioni dirette: non sono scene, non compaiono
    /// nemmeno in app Casa, e contarle gonfierebbe il numero con roba interna.
    var userScenes: [SceneSnapshot] { scenes.filter { !$0.isTriggerOwned } }

    var counts: Counts {
        Counts(
            rooms: rooms.count,
            zones: zones.count,
            serviceGroups: serviceGroups.count,
            accessories: accessories.count,
            scenes: userScenes.count,
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
        let ambiguous = ambiguousStableKeys
        let reliable = accessories.filter { $0.isReliablyIdentifiable(ambiguousStableKeys: ambiguous) }
        return Double(reliable.count) / Double(accessories.count)
    }

    /// Le combinazioni produttore+modello+stanza che in questa casa toccano a
    /// più di un accessorio: là il livello «stabile» non identifica niente.
    ///
    /// Si calcola una volta e si passa in giro, così il segno sulla singola riga
    /// e la percentuale complessiva non possono raccontare cose diverse.
    var ambiguousStableKeys: Set<String> {
        var counts: [String: Int] = [:]
        for accessory in accessories where (accessory.address.serialNumber ?? "").isEmpty {
            counts[accessory.address.stableKey, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}

extension AccessorySnapshot {
    /// Riconoscibile **senza dipendere dal nome**, che l'utente può cambiare in
    /// qualsiasi momento. Non conta *come* ci si riesce: numero di serie o
    /// combinazione produttore+modello+stanza sono due strade allo stesso
    /// risultato, e all'utente interessa il risultato.
    func isReliablyIdentifiable(ambiguousStableKeys: Set<String>) -> Bool {
        if !(address.serialNumber ?? "").isEmpty { return true }
        return !ambiguousStableKeys.contains(address.stableKey)
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
            // ⚠️ `humanSummary` **non** entra qui. Per un trigger a orario
            // contiene la prossima data di scatto, che si sposta da sola: con
            // dentro quella, due catture della stessa casa immutata non
            // sarebbero mai risultate uguali e la deduplica non avrebbe mai
            // potuto scattare. Al suo posto la forma strutturata, che descrive
            // la regola invece del prossimo evento.
            lines.append([
                "auto", automation.name, automation.triggerKind,
                automation.content.rawValue, String(automation.isEnabled),
                automation.restorable.map(Self.canonicalText) ?? "",
                automation.conditionSummaries.sorted().joined(separator: ";"),
                automation.actionSetNames.sorted().joined(separator: ";")
            ].joined(separator: "|"))
        }

        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Proiezione stabile di un'automazione ricreabile: descrive **la regola**,
    /// senza date che si spostano.
    static func canonicalText(_ plan: RestorableAutomation) -> String {
        var parts: [String] = [plan.sceneName ?? "", plan.conditionJoinMode, String(plan.isEnabled)]
        // Le azioni dirette contano quanto una scena: sono ciò che l'automazione
        // esegue, e cambiarle è un cambiamento di configurazione.
        for action in plan.inlineActions.sorted(by: { $0.sortKey < $1.sortKey }) {
            parts.append("i:\(action.sortKey):\(action.value.canonicalText)")
        }
        for event in plan.startEvents {
            switch event {
            case .schedule(let s):
                parts.append("t:\(s.kind):\(s.hour):\(s.minute):\(s.offsetMinutes):"
                             + s.weekdays.sorted().map(String.init).joined(separator: ","))
            case .accessory(let ref):
                parts.append("a:\(ref.accessory.name):\(ref.characteristicType):\(ref.comparisonOperator)")
            case .presence(let kind, let scope):
                parts.append("p:\(kind):\(scope)")
            }
        }
        for condition in plan.conditions.sorted(by: { $0.accessory.name < $1.accessory.name }) {
            parts.append("c:\(condition.accessory.name):\(condition.characteristicType):\(condition.comparisonOperator)")
        }
        for condition in plan.timeConditions {
            parts.append("ct:\(condition.kind):\(condition.relation):\(condition.hour):\(condition.minute)"
                         + ":\(condition.offsetMinutes):\(condition.endKind):\(condition.endHour)"
                         + ":\(condition.endMinute):\(condition.endOffsetMinutes)")
        }
        for condition in plan.presenceConditions {
            parts.append("cp:\(condition.kind):\(condition.userScope)")
        }
        return parts.joined(separator: "/")
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

// MARK: - Presentazione dei valori
//
// Vivono col modello e non con la vista: le usa anche il confronto fra due
// snapshot, che è puro e non importa SwiftUI.

extension SnapshotValue {
    /// Col simbolo dell'unità quando HomeKit lo dichiara: «55 %» dice qualcosa
    /// che «55» non dice.
    func displayText(unit: String?) -> String {
        guard let symbol = Self.unitSymbol(unit) else { return displayText }
        // L'unità vale sui numeri. Un interruttore non è «acceso %».
        switch self {
        case .int, .double: return "\(displayText) \(symbol)"
        default:            return displayText
        }
    }

    private static func unitSymbol(_ unit: String?) -> String? {
        switch unit {
        case HMCharacteristicMetadataUnitsPercentage: "%"
        case HMCharacteristicMetadataUnitsCelsius:    "°C"
        case HMCharacteristicMetadataUnitsFahrenheit: "°F"
        case HMCharacteristicMetadataUnitsArcDegree:  "°"
        case HMCharacteristicMetadataUnitsSeconds:    "s"
        case HMCharacteristicMetadataUnitsLux:        "lux"
        default: nil
        }
    }

    var displayText: String {
        switch self {
        case .bool(let value):
            value ? String(localized: "snapshot.value.on", defaultValue: "on")
                  : String(localized: "snapshot.value.off", defaultValue: "off")
        case .int(let value):   "\(value)"
        case .double(let value): value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
        case .string(let value): value
        case .unsupported:       "—"
        }
    }
}

/// Nomi leggibili per le caratteristiche HAP più comuni. Non serve la lista
/// completa: quelle che compaiono davvero nelle scene sono una manciata, e per
/// tutte le altre l'UUID grezzo è comunque meglio di niente.
enum SnapshotCharacteristicNames {
    private static let names: [String: String] = [
        "00000025": "Acceso",
        "00000008": "Luminosità",
        "00000013": "Tonalità",
        "0000002F": "Saturazione",
        "000000CE": "Temperatura colore",
        "0000007C": "Posizione",
        "00000033": "Modalità",
        "00000035": "Temperatura",
        "0000001D": "Serratura",
        "00000032": "Stato allarme",
        "000000B0": "Attivo",
        "00000029": "Velocità"
    ]

    /// Ripiego quando il nome di sistema non c'è.
    static func readable(_ characteristicType: String) -> String {
        let prefix = String(characteristicType.prefix(8)).uppercased()
        if let name = names[prefix] { return name }
        // Fuori dall'elenco resta un identificatore, ma accorciato: dentro una
        // riga che ne unisce diversi, un UUID intero la rende illeggibile e
        // nasconde quelli che invece un nome ce l'hanno.
        return "0x" + prefix.drop(while: { $0 == "0" })
    }
}

// MARK: - Valori enumerati

/// I valori enumerati detti in parole: «Inserito (fuori casa)» invece di `1`.
///
/// ⚠️ **Nessun servizio lo fa per noi.** `HMCharacteristicMetadata.validValues`
/// dichiara quali numeri sono ammessi, non cosa significano: il significato sta
/// nella specifica HAP, non nel framework. Quindi una tabella è inevitabile.
///
/// ⚠️ **E questa è la seconda in casa.** `AutomationCapabilityCatalog` ne ha già
/// una equivalente per il builder automazioni. Le chiavi di traduzione qui sono
/// deliberatamente **le stesse**, così le due dicono almeno le stesse parole
/// finché non verranno unificate — che è la cosa giusta da fare e non è questa.
///
/// Sono poche perché una scena scrive quasi sempre booleani e numeri: gli
/// enumerati sono la minoranza, e con questi sono coperti. Le tredici del
/// catalogo automazioni riguardano un'altra superficie — gli **stati correnti**
/// su cui scatta un trigger — e non vanno confuse con queste.
///
/// Coperte solo le caratteristiche che una scena scrive davvero, e nella loro
/// variante `Target`: la `Current` dell'antifurto ha un valore in più
/// («allarme in corso») che una scena non può impostare, e trattarle come
/// uguali darebbe un'etichetta sbagliata proprio lì.
enum SnapshotCharacteristicValues {

    private static let targetSecuritySystemState = "00000067-0000-1000-8000-0026BB765291"

    static func readable(_ value: SnapshotValue, characteristicType: String) -> String? {
        guard case .int(let raw) = value else { return nil }
        return table(for: characteristicType)?[raw]
    }

    private static func table(for characteristicType: String) -> [Int: String]? {
        switch characteristicType {
        case HMCharacteristicTypeTargetLockMechanismState:
            [0: String(localized: "accessory.lock.unsecured", defaultValue: "Unlocked"),
             1: String(localized: "accessory.lock.secured", defaultValue: "Locked")]

        case HMCharacteristicTypeTargetDoorState:
            [0: String(localized: "accessory.garage.open", defaultValue: "Open"),
             1: String(localized: "accessory.garage.closed", defaultValue: "Closed")]

        case targetSecuritySystemState:
            [0: String(localized: "security.state.stayArm", defaultValue: "Stay arm"),
             1: String(localized: "security.state.awayArm", defaultValue: "Away arm"),
             2: String(localized: "security.state.nightArm", defaultValue: "Night arm"),
             3: String(localized: "security.state.disarmed", defaultValue: "Disarmed")]

        case HMCharacteristicTypeTargetHeatingCooling:
            [0: String(localized: "thermostat.mode.off", defaultValue: "Off"),
             1: String(localized: "thermostat.mode.heat", defaultValue: "Heat"),
             2: String(localized: "thermostat.mode.cool", defaultValue: "Cool"),
             3: String(localized: "thermostat.mode.auto", defaultValue: "Auto")]

        case HMCharacteristicTypeTargetHeaterCoolerState:
            [0: String(localized: "thermostat.mode.auto", defaultValue: "Auto"),
             1: String(localized: "thermostat.mode.heat", defaultValue: "Heat"),
             2: String(localized: "thermostat.mode.cool", defaultValue: "Cool")]

        case HMCharacteristicTypeTargetFanState,
             HMCharacteristicTypeTargetAirPurifierState:
            [0: String(localized: "mode.manual", defaultValue: "Manual"),
             1: String(localized: "thermostat.mode.auto", defaultValue: "Auto")]

        case HMCharacteristicTypeTargetHumidifierDehumidifierState:
            [0: String(localized: "thermostat.mode.auto", defaultValue: "Auto"),
             1: String(localized: "humidity.mode.humidify", defaultValue: "Humidify"),
             2: String(localized: "humidity.mode.dehumidify", defaultValue: "Dehumidify")]

        case HMCharacteristicTypeActive:
            [0: String(localized: "state.inactive", defaultValue: "Off"),
             1: String(localized: "state.active", defaultValue: "On")]

        case HMCharacteristicTypeTargetMediaState:
            [0: String(localized: "media.play", defaultValue: "Play"),
             1: String(localized: "media.pause", defaultValue: "Pause"),
             2: String(localized: "media.stop", defaultValue: "Stop")]

        case HMCharacteristicTypeTargetVisibilityState:
            [0: String(localized: "visibility.shown", defaultValue: "Shown"),
             1: String(localized: "visibility.hidden", defaultValue: "Hidden")]

        case HMCharacteristicTypeRotationDirection:
            [0: String(localized: "rotation.clockwise", defaultValue: "Clockwise"),
             1: String(localized: "rotation.counterClockwise", defaultValue: "Counter-clockwise")]

        case HMCharacteristicTypeSwingMode:
            [0: String(localized: "swing.disabled", defaultValue: "Off"),
             1: String(localized: "swing.enabled", defaultValue: "On")]

        case HMCharacteristicTypeLockPhysicalControls:
            [0: String(localized: "childLock.disabled", defaultValue: "Unlocked"),
             1: String(localized: "childLock.enabled", defaultValue: "Locked")]

        default:
            nil
        }
    }
}

extension SceneActionSnapshot {
    /// Nome e valore come li leggerebbe una persona.
    var readableName: String {
        target.characteristicName
            ?? SnapshotCharacteristicNames.readable(target.characteristicType)
    }

    var readableValue: String {
        SnapshotCharacteristicValues.readable(value, characteristicType: target.characteristicType)
            ?? value.displayText(unit: format?.units)
    }
}
