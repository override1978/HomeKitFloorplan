import Foundation
import SwiftData

// MARK: - HouseMeterImport

/// Porta i punti del contatore generale (export Vimar) dentro lo storico
/// `EnergySample`, con la stessa disciplina del logger live: mai doppioni.
///
/// La dedup è per timestamp esatto sul deviceID del contatore: reimportare
/// lo stesso file — o un export più aggiornato che contiene tutto il
/// passato — aggiunge SOLO i giorni nuovi. È il flusso pensato per l'uso
/// reale: esporti dal Vimar quando ti ricordi, importi, e la sezione Casa
/// si allunga da sola.
@MainActor
enum HouseMeterImport {

    struct Outcome {
        let inserted: Int
        let skipped: Int
        let firstDay: Date?
        let lastDay: Date?
    }

    static func importArchive(_ data: Data, modelContainer: ModelContainer) throws -> Outcome {
        let points = try VimarMeterImporter.dailyPoints(from: data)

        let context = ModelContext(modelContainer)
        let deviceID = EnergySample.houseMeterDeviceID
        let existing = (try? context.fetch(
            FetchDescriptor<EnergySample>(predicate: #Predicate { $0.deviceID == deviceID })
        )) ?? []
        let existingTimestamps = Set(existing.map(\.timestamp))

        var inserted = 0
        var skipped = 0
        for point in points {
            guard !existingTimestamps.contains(point.timestamp) else {
                skipped += 1
                continue
            }
            context.insert(EnergySample(
                deviceID: deviceID,
                accessoryUUID: "",
                accessoryName: String(localized: "energy.house.meterName", defaultValue: "House meter"),
                roomName: "",
                timestamp: point.timestamp,
                cumulativeKilowattHours: point.cumulativeKilowattHours,
                activePowerWatts: nil,
                sourceRaw: "Vimar"
            ))
            inserted += 1
        }

        if inserted > 0 {
            try context.save()
        }
        dprint("⚡️ Import contatore: \(inserted) campioni nuovi, \(skipped) già presenti")
        return Outcome(
            inserted: inserted,
            skipped: skipped,
            firstDay: points.first?.timestamp,
            lastDay: points.last?.timestamp
        )
    }
}
