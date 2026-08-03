import Foundation
import HomeKit
import CryptoKit
import UIKit

// MARK: - HomeKitIdentityProbe

/// Misura su quali basi si può identificare un accessorio HomeKit **fra device
/// diversi**, che è la domanda da cui dipende tutta la sezione Mantenimento.
///
/// Il problema: `HMAccessory.uniqueIdentifier` è (si crede) generato per device,
/// quindi uno snapshot preso sull'iPad non saprebbe a quali accessori riferirsi
/// una volta aperto sull'iPhone. Questo progetto ci ha già sbattuto contro coi
/// marker delle planimetrie e ha costruito `HomeKitEntityResolver` per aggirarlo
/// abbinando per nome e stanza — che però è un ripiego: i nomi si cambiano.
///
/// Due misure, e vanno fatte **sullo stesso impianto da due device diversi**:
///
/// 1. **L'impronta degli UUID.** Se la stessa stringa esce su iPad e su iPhone,
///    gli identificatori sono stabili e il problema non esiste: ci si può
///    riferire agli accessori direttamente.
///
/// 2. **La copertura dei numeri di serie.** Se gli UUID differiscono, il seriale
///    è l'unica identità hardware vera — e sopravvive anche a una rimozione e
///    ri-accoppiamento, che è ciò che serve per riconoscere un dispositivo
///    ri-aggiunto. Ma non tutti lo espongono: gli accessori dietro un bridge
///    (Hue, Aqara) spesso no.
///
/// Il seriale **non è una proprietà**: va letto dalla caratteristica HAP
/// `00000030` del servizio AccessoryInformation, quindi serve una `readValue`
/// per accessorio. Su un impianto da 128 dispositivi sono ~128 andate e ritorno:
/// secondi, accettabile per una misura manuale.
@MainActor
@Observable
final class HomeKitIdentityProbe {

    /// UUID HAP del numero di serie. Si usa la stringa grezza e non
    /// `HMCharacteristicTypeSerialNumber` perché quella costante è deprecata da
    /// iOS 11 ("No longer supported") mentre la caratteristica funziona ancora —
    /// la stessa scelta già fatta in `HomeKitDebugView`.
    private static let serialNumberCharacteristicType = "00000030-0000-1000-8000-0026BB765291"

    /// Su cosa si regge l'identità di un accessorio quando l'UUID non serve —
    /// e l'UUID non serve mai fra device diversi, misurato il 2026-08-03: due
    /// device sulla stessa casa producono impronte UUID diverse.
    enum IdentityTier: Int, Comparable, Sendable {
        /// Numero di serie: identità hardware. Sopravvive al cambio di nome,
        /// allo spostamento di stanza e anche al ri-accoppiamento.
        case hardware = 0
        /// Produttore + modello + stanza, e nessun altro accessorio uguale in
        /// quella stanza. Regge finché non lo si sposta.
        case stable = 1
        /// Solo il nome lo distingue da un gemello nella stessa stanza:
        /// due sensori identici in «Scala», due lampade identiche in «Soggiorno».
        /// Una rinomina lo rende irriconoscibile.
        case nameOnly = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Entry: Identifiable, Sendable {
        let id: UUID
        let name: String
        let roomName: String?
        let serialNumber: String?
        let manufacturer: String?
        let model: String?
        let isBridged: Bool
        var identityTier: IdentityTier = .nameOnly

        var hasSerial: Bool { !(serialNumber ?? "").isEmpty }

        /// Chiave del livello intermedio. Il modello da solo non basta: due
        /// SML001 in stanze diverse sono distinguibili, due nella stessa no.
        var stableKey: String {
            [manufacturer, model, roomName]
                .map { $0?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" }
                .joined(separator: "|")
        }
    }

    struct Report: Sendable {
        let capturedAt: Date
        let deviceName: String
        let homeName: String
        let entries: [Entry]

        var total: Int { entries.count }
        var withSerial: Int { entries.filter(\.hasSerial).count }
        var bridged: Int { entries.filter(\.isBridged).count }

        var serialCoverage: Double {
            guard total > 0 else { return 0 }
            return Double(withSerial) / Double(total)
        }

        /// Impronta dell'insieme degli UUID, ordinati per essere indipendenti
        /// dall'ordine in cui HomeKit li restituisce. **È il numero che si
        /// confronta fra due device**: se coincide, gli UUID sono gli stessi.
        var uuidFingerprint: String {
            let joined = entries.map(\.id.uuidString).sorted().joined(separator: "\n")
            let digest = SHA256.hash(data: Data(joined.utf8))
            return digest.map { String(format: "%02X", $0) }.prefix(12).joined()
        }

        func count(of tier: IdentityTier) -> Int {
            entries.filter { $0.identityTier == tier }.count
        }

        /// Quota di accessori identificabili **senza dipendere dal nome**, che è
        /// l'unico dato che l'utente può cambiare in qualsiasi momento. È il
        /// numero che dice se un ripristino fra device regge.
        var reliableCoverage: Double {
            guard total > 0 else { return 0 }
            return Double(count(of: .hardware) + count(of: .stable)) / Double(total)
        }

        /// Accessori senza seriale, per capire chi sono: tipicamente tutto ciò
        /// che sta dietro un bridge o su cloud.
        var withoutSerial: [Entry] {
            entries.filter { !$0.hasSerial }.sorted { $0.name < $1.name }
        }

        /// I casi che una rinomina renderebbe irriconoscibili: gemelli identici
        /// nella stessa stanza, senza seriale.
        var nameOnly: [Entry] {
            entries.filter { $0.identityTier == .nameOnly }.sorted { $0.name < $1.name }
        }
    }

    private(set) var report: Report?
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var elapsed: TimeInterval = 0

    func run(homeKit: HomeKitService) async {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        let started = Date()
        defer {
            isRunning = false
            elapsed = Date().timeIntervalSince(started)
        }

        let accessories = homeKit.allAccessories
        var entries: [Entry] = []
        entries.reserveCapacity(accessories.count)

        // In sequenza e non in parallelo: un impianto reale ha decine di
        // dispositivi su radio lente (Thread, Zigbee dietro bridge) e
        // bombardarli tutti insieme produce timeout invece che risposte.
        // Qui la lentezza non dà fastidio: è un'azione manuale con una barra.
        for (index, accessory) in accessories.enumerated() {
            let serial = await readSerialNumber(of: accessory)
            entries.append(
                Entry(
                    id: accessory.uniqueIdentifier,
                    name: accessory.name,
                    roomName: accessory.room?.name,
                    serialNumber: serial,
                    manufacturer: accessory.manufacturer,
                    model: accessory.model,
                    // `isBridged` = sta DIETRO un bridge. Un bridge in sé lo ha
                    // falso e popola invece `uniqueIdentifiersForBridgedAccessories`.
                    isBridged: accessory.isBridged
                )
            )
            progress = Double(index + 1) / Double(max(1, accessories.count))
        }

        report = Report(
            capturedAt: Date(),
            deviceName: UIDevice.current.name,
            homeName: homeKit.currentHome?.name ?? "—",
            entries: Self.assignIdentityTiers(to: entries)
        )
    }

    /// Assegna a ogni accessorio il livello su cui si regge la sua identità.
    /// Va fatto sull'insieme e non sul singolo, perché «stabile» dipende dal
    /// non avere gemelli: lo stesso modello nella stessa stanza declassa
    /// entrambi a «solo il nome».
    static func assignIdentityTiers(to entries: [Entry]) -> [Entry] {
        var occurrences: [String: Int] = [:]
        for entry in entries where !entry.hasSerial {
            occurrences[entry.stableKey, default: 0] += 1
        }
        return entries.map { entry in
            var copy = entry
            if entry.hasSerial {
                copy.identityTier = .hardware
            } else if occurrences[entry.stableKey] == 1 {
                copy.identityTier = .stable
            } else {
                copy.identityTier = .nameOnly
            }
            return copy
        }
    }

    private func readSerialNumber(of accessory: HMAccessory) async -> String? {
        guard let info = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
              let characteristic = info.characteristics.first(where: {
                  $0.characteristicType == Self.serialNumberCharacteristicType
              })
        else { return nil }

        // Il valore in cache va benissimo: il seriale non cambia mai, e leggerlo
        // di nuovo costerebbe un giro di rete per nulla.
        if let cached = characteristic.value.map({ "\($0)" }), !cached.isEmpty {
            return cached
        }

        let didRead = await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard didRead, let raw = characteristic.value else { return nil }
        let value = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Rapporto testuale

extension HomeKitIdentityProbe.Report {

    /// Testo da copiare e confrontare fra i due device. Le due impronte in cima
    /// rispondono da sole alla domanda; l'elenco serve solo se non tornano.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("HomeKit Identity Probe")
        lines.append("Device: \(deviceName)")
        lines.append("Casa: \(homeName)")
        lines.append("Data: \(capturedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("")
        lines.append("IMPRONTA UUID: \(uuidFingerprint)")
        lines.append("")
        lines.append("Accessori: \(total) · bridged: \(bridged)")
        lines.append("Identità hardware (seriale):        \(count(of: .hardware))")
        lines.append("Identità stabile (marca+modello+stanza): \(count(of: .stable))")
        lines.append("Solo il nome:                       \(count(of: .nameOnly))")
        lines.append("Affidabile senza il nome: \(Int((reliableCoverage * 100).rounded()))%")
        lines.append("")
        lines.append("— Elenco (nome | stanza | livello | uuid | seriale | produttore | modello) —")
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let tier = switch entry.identityTier {
            case .hardware: "hardware"
            case .stable:   "stabile"
            case .nameOnly: "SOLO NOME"
            }
            lines.append([
                entry.name,
                entry.roomName ?? "—",
                tier,
                entry.id.uuidString,
                entry.serialNumber ?? "—",
                entry.manufacturer ?? "—",
                entry.model ?? "—"
            ].joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}
