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

    struct Entry: Identifiable, Sendable {
        let id: UUID
        let name: String
        let roomName: String?
        let serialNumber: String?
        let manufacturer: String?
        let model: String?
        let isBridged: Bool

        var hasSerial: Bool { !(serialNumber ?? "").isEmpty }
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

        /// Impronta dei soli seriali, per lo stesso confronto su base hardware.
        /// Se gli UUID divergono ma questa coincide, il seriale è la strada.
        var serialFingerprint: String {
            let serials = entries.compactMap(\.serialNumber).filter { !$0.isEmpty }.sorted()
            guard !serials.isEmpty else { return "—" }
            let digest = SHA256.hash(data: Data(serials.joined(separator: "\n").utf8))
            return digest.map { String(format: "%02X", $0) }.prefix(12).joined()
        }

        /// Accessori senza seriale: sono quelli per cui, se gli UUID non sono
        /// stabili, non esisterebbe alcuna identità affidabile.
        var withoutSerial: [Entry] {
            entries.filter { !$0.hasSerial }.sorted { $0.name < $1.name }
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
            entries: entries
        )
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
        lines.append("IMPRONTA UUID:    \(uuidFingerprint)")
        lines.append("IMPRONTA SERIALI: \(serialFingerprint)")
        lines.append("")
        lines.append("Accessori: \(total)")
        lines.append("Con seriale: \(withSerial) (\(Int((serialCoverage * 100).rounded()))%)")
        lines.append("Senza seriale: \(total - withSerial)")
        lines.append("Bridged: \(bridged)")
        lines.append("")
        lines.append("— Elenco (nome | stanza | uuid | seriale | produttore | modello) —")
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            lines.append([
                entry.name,
                entry.roomName ?? "—",
                entry.id.uuidString,
                entry.serialNumber ?? "—",
                entry.manufacturer ?? "—",
                entry.model ?? "—"
            ].joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}
