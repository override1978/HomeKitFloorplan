import Foundation
import HomeKit
import SwiftData

// MARK: - SensorLogger

/// Campiona tutti i sensori ambientali della casa e persiste le letture in SwiftData.
/// È @MainActor perché accede ai servizi HomeKit (che sono @MainActor), ma
/// la scrittura su SwiftData avviene su un ModelContext dedicato del background.
@MainActor
final class SensorLogger {

    // MARK: Singleton

    static let shared = SensorLogger()

    private init() {}

    // MARK: - Sprint 5B: follow-up hook

    /// Iniettato da HomeFloorplanApp.init() dopo la creazione del tracker condiviso.
    /// SensorLogger chiama recordOutcome() per ogni nuova lettura, consentendo
    /// ad ActionEffectivenessTracker di chiudere le misurazioni "pending".
    weak var effectivenessTracker: ActionEffectivenessTracker?

    // MARK: - Outdoor sampling rate-limit

    private var lastOutdoorSampleAt: Date?
    private let outdoorSampleInterval: TimeInterval = 3600  // 1 snapshot/hour

    // MARK: - Deduplica in scrittura

    /// Filtra le letture ripetute prima che diventino righe. Vedi
    /// `SensorSampleGate` per il ragionamento e le soglie.
    ///
    /// Non tocca `sampleOutdoor`, che ha già un limite di uno snapshot all'ora:
    /// due righe orarie non sono un problema di storage e passarle dal gate non
    /// cambierebbe nulla se non aggiungere un percorso di codice.
    private var sampleGate = SensorSampleGate()

    /// TEMPORANEO — vedi `SensorSampleGate.Stats`. Quando è stata scritta
    /// l'ultima riga di diagnostica sul log esportabile.
    private var lastGateStatsLoggedAt: Date?

    // MARK: - Campionamento principale

    /// Campiona tutti i sensori ambientali della casa e salva le letture.
    /// La generazione degli alert passa dal motore unificato di Home Intelligence.
    func sampleAllSensors(home: HMHome, modelContainer: ModelContainer) async {
        let accessories = home.accessories
        var readings: [(accessoryUUID: String, serviceType: SensorServiceType, roomName: String, value: Double)] = []

        for accessory in accessories {
            let roomName = accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room")
            let accessoryUUID = accessory.uniqueIdentifier.uuidString

            for serviceType in SensorServiceType.allCases where !serviceType.isWeatherKitSource {
                if let value = await readValue(for: serviceType, from: accessory) {
                    readings.append((accessoryUUID, serviceType, roomName, value))
                }
            }
        }

        guard !readings.isEmpty else { return }

        // Salva in background context per non bloccare la UI
        let backgroundContext = ModelContext(modelContainer)
        let now = Date()
        var stored = 0

        for reading in readings {
            guard sampleGate.shouldWrite(
                accessoryUUID: reading.accessoryUUID,
                type:          reading.serviceType,
                value:         reading.value,
                now:           now
            ) else { continue }

            backgroundContext.insert(SensorReading(
                accessoryUUID: reading.accessoryUUID,
                serviceType: reading.serviceType,
                roomName: reading.roomName,
                value: reading.value
            ))
            stored += 1
        }

        if stored > 0 {
            do {
                try backgroundContext.save()
                dprint("✅ SensorLogger: \(stored)/\(readings.count) letture archiviate — \(readings.count - stored) invariate")
            } catch {
                dprint("❌ SensorLogger save error: \(error)")
            }
        } else {
            dprint("✅ SensorLogger: \(readings.count) letture campionate, nessuna variazione da archiviare")
        }

        // TEMPORANEO — diagnostica per tarare le soglie della deduplica sui dati
        // veri. Una riga l'ora sul log esportabile, non a ogni giro: serve a
        // vedere il rapporto archiviate/campionate e quanto pesa la regola sui
        // sensori bloccati, che a tavolino non si può stimare.
        // Da togliere insieme a `SensorSampleGate.Stats`.
        if lastGateStatsLoggedAt == nil || now.timeIntervalSince(lastGateStatsLoggedAt!) >= 3600 {
            lastGateStatsLoggedAt = now
            let total = (try? backgroundContext.fetchCount(FetchDescriptor<SensorReading>())) ?? -1
            SyncDiagnosticsLogger.log(
                "📊 Campionamento: \(sampleGate.stats.summary) · righe in archivio \(total)"
            )
        }

        // Sprint 5B: notifica il tracker per chiudere le misurazioni "pending".
        // Riceve TUTTE le letture campionate, non solo quelle archiviate: misura
        // l'effetto reale di un'azione sulla casa, e quell'effetto esiste anche
        // quando il valore è troppo stabile per meritare una riga.
        if let tracker = effectivenessTracker {
            for reading in readings {
                tracker.recordOutcome(
                    roomName: reading.roomName,
                    sensorTypeRaw: reading.serviceType.rawValue,
                    followUpValue: reading.value,
                    readAt: now
                )
            }
        }
    }

    // MARK: - Campionamento foreground lux (5 min)

    /// Campiona solo i sensori di luminosità (HMCharacteristicTypeCurrentLightLevel).
    /// Chiamato dalla foreground loop ogni ~5 min per ottenere campionamento denso.
    /// Non esegue threshold-check né recordOutcome — scopo puramente data-collection.
    func sampleLightSensors(home: HMHome, modelContainer: ModelContainer) async {
        var count = 0
        var sampled = 0
        let ctx = ModelContext(modelContainer)
        let now = Date()
        for accessory in home.accessories {
            let roomName = accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room")
            if let value = await readValue(for: .lightSensor, from: accessory) {
                sampled += 1
                let uuid = accessory.uniqueIdentifier.uuidString
                guard sampleGate.shouldWrite(accessoryUUID: uuid, type: .lightSensor, value: value, now: now)
                else { continue }
                ctx.insert(SensorReading(
                    accessoryUUID: uuid,
                    serviceType:   .lightSensor,
                    roomName:      roomName,
                    value:         value
                ))
                count += 1
            }
        }
        guard count > 0 else {
            if sampled > 0 { dprint("💡 SensorLogger: \(sampled) lux letti, nessuna variazione da archiviare") }
            return
        }
        do {
            try ctx.save()
            dprint("💡 SensorLogger: lux archiviati — \(count)/\(sampled) sensore/i")
        } catch {
            dprint("❌ SensorLogger lux save error: \(error)")
        }
    }

    // MARK: - Outdoor snapshot (WeatherKit)

    /// Persists a WeatherKit snapshot as SensorReadings (outdoor temperature + humidity).
    /// Rate-limited to one call per hour regardless of how often it is invoked.
    func sampleOutdoor(snapshot: WeatherSnapshot, modelContainer: ModelContainer) async {
        if let last = lastOutdoorSampleAt,
           Date().timeIntervalSince(last) < outdoorSampleInterval { return }
        lastOutdoorSampleAt = Date()

        let ctx = ModelContext(modelContainer)
        let pairs: [(SensorServiceType, Double)] = [
            (.outdoorTemperature, snapshot.outdoorTemperature),
            (.outdoorHumidity,    snapshot.outdoorHumidity * 100), // WeatherKit 0–1 → %
        ]
        for (type, value) in pairs {
            ctx.insert(SensorReading(
                accessoryUUID: "weather.outdoor",
                serviceType:   type,
                roomName:      String(localized: "outdoor.roomName", defaultValue: "Outdoor"),
                value:         value
            ))
        }
        do {
            try ctx.save()
            dprint("☁️ SensorLogger: outdoor saved — temp=\(String(format: "%.1f", snapshot.outdoorTemperature))°C hum=\(Int(snapshot.outdoorHumidity * 100))%")
        } catch {
            dprint("❌ SensorLogger outdoor save error: \(error)")
        }
    }

    // MARK: - Pulizia vecchie letture

    /// Elimina le letture più vecchie del numero di giorni specificato.
    func pruneOldReadings(olderThan days: Int = 30, modelContainer: ModelContainer) async {
        guard !LocalDataProtection.shouldPreserveSwiftData else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let backgroundContext = ModelContext(modelContainer)

        do {
            try backgroundContext.delete(
                model: SensorReading.self,
                where: #Predicate { $0.timestamp < cutoff }
            )
            try backgroundContext.save()
            dprint("🧹 SensorLogger: pulizia letture precedenti al \(cutoff)")
        } catch {
            dprint("❌ SensorLogger prune error: \(error)")
        }
    }

    // MARK: - Lettura valore da caratteristica HomeKit

    private func readValue(for serviceType: SensorServiceType, from accessory: HMAccessory) async -> Double? {
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.characteristicType == serviceType.hmCharacteristicType {
                return await withCheckedContinuation { continuation in
                    characteristic.readValue { error in
                        // Se HomeKit segnala un errore, non usare il valore in cache
                        // (potrebbe essere 0 o nil non aggiornato).
                        if let error {
                            dprint("⚠️ readValue error [\(accessory.name)/\(serviceType.rawValue)]: \(error.localizedDescription)")
                            continuation.resume(returning: nil)
                            return
                        }
                        if let raw = characteristic.value {
                            let parsed = Self.parseDouble(raw)
                            dprint("📡 [\(accessory.name)/\(serviceType.rawValue)] raw=\(raw) parsed=\(String(describing: parsed))")
                            continuation.resume(returning: parsed)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func parseDouble(_ raw: Any) -> Double? {
        if let d = raw as? Double { return d }
        if let f = raw as? Float  { return Double(f) }
        if let i = raw as? Int    { return Double(i) }
        if let b = raw as? Bool   { return b ? 1.0 : 0.0 }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

}
