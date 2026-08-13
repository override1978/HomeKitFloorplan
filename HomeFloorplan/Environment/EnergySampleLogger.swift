import Foundation
import HomeKit
import SwiftData

// MARK: - EnergySampleLogger

/// Trasforma le letture live di energia in righe di storico.
///
/// Non legge niente da solo: si aggancia al punto in cui gli snapshot GIÀ
/// passano (`MatterEnergyLiveStore.refresh`, iniettato da AppServices), così
/// ogni lettura live — foreground, runtime, background task — diventa storia
/// gratis, senza un secondo giro di letture Matter.
///
/// Stessa filosofia di `SensorSampleGate`: le righe che non aggiungono
/// informazione non diventano righe.
@MainActor
final class EnergySampleLogger {

    static let shared = EnergySampleLogger()

    private init() {}

    /// Sotto questo scarto di potenza, a contatore fermo, la riga è rumore.
    private let powerNoiseWatts: Double = 0.5
    /// Due righe dello stesso device più vicine di così non servono a nessuna
    /// statistica giornaliera (e proteggono dai refresh ravvicinati).
    private let minimumInterval: TimeInterval = 5 * 60

    /// Persiste gli snapshot che portano informazione nuova.
    func log(snapshots: [MatterEnergyDeviceSnapshot], home: HMHome, modelContainer: ModelContainer) {
        guard !snapshots.isEmpty else { return }

        let context = ModelContext(modelContainer)
        var written = 0
        var skipped = 0

        for snapshot in snapshots {
            // Uno snapshot senza numeri (device irraggiungibile) non è storico.
            guard snapshot.cumulativeEnergyKilowattHours != nil
                    || snapshot.activePowerWatts != nil else {
                skipped += 1
                continue
            }

            if let last = lastSample(for: snapshot.id, in: context) {
                if snapshot.measuredAt.timeIntervalSince(last.timestamp) < minimumInterval {
                    skipped += 1
                    continue
                }
                let cumulativeUnchanged = last.cumulativeKilowattHours == snapshot.cumulativeEnergyKilowattHours
                let powerDelta = abs((last.activePowerWatts ?? 0) - (snapshot.activePowerWatts ?? 0))
                if cumulativeUnchanged && powerDelta < powerNoiseWatts {
                    skipped += 1
                    continue
                }
                if let previous = last.cumulativeKilowattHours,
                   let current = snapshot.cumulativeEnergyKilowattHours,
                   current < previous {
                    // Non si corregge e non si scarta: si annota. Il grezzo
                    // resta fedele al device, i segmenti li spezza chi legge.
                    dprint("⚡️ Energia: contatore ridotto per \(snapshot.accessoryName) (\(previous) → \(current) kWh) — reset/ri-pairing?")
                }
            }

            context.insert(EnergySample(
                deviceID: snapshot.id,
                accessoryUUID: snapshot.accessoryUUIDs.first?.uuidString ?? "",
                accessoryName: snapshot.accessoryName,
                roomName: roomName(for: snapshot, home: home),
                timestamp: snapshot.measuredAt,
                cumulativeKilowattHours: snapshot.cumulativeEnergyKilowattHours,
                activePowerWatts: snapshot.activePowerWatts,
                sourceRaw: snapshot.source.rawValue
            ))
            written += 1
        }

        guard written > 0 else {
            if skipped > 0 { dprint("⚡️ Energia: 0 righe nuove (\(skipped) senza informazione)") }
            return
        }

        do {
            try context.save()
            dprint("⚡️ Energia: \(written) righe salvate, \(skipped) saltate dal gate")
        } catch {
            dprint("❌ Energia: salvataggio fallito — \(error)")
        }
    }

    private func lastSample(for deviceID: String, in context: ModelContext) -> EnergySample? {
        var descriptor = FetchDescriptor<EnergySample>(
            predicate: #Predicate { $0.deviceID == deviceID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func roomName(for snapshot: MatterEnergyDeviceSnapshot, home: HMHome) -> String {
        for uuid in snapshot.accessoryUUIDs {
            if let room = home.accessories.first(where: { $0.uniqueIdentifier == uuid })?.room {
                return room.name
            }
        }
        return String(localized: "room.none", defaultValue: "No room")
    }
}
