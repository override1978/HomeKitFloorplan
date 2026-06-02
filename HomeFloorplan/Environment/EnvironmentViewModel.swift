import Foundation
import SwiftUI
import SwiftData
import Combine

// MARK: - SensorUrgency

/// Livello di urgenza di un sensore ambientale.
enum SensorUrgency: Int, Comparable {
    case normal  = 0
    case warning = 1
    case danger  = 2

    static func < (lhs: SensorUrgency, rhs: SensorUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .normal:  return .primary
        case .warning: return .orange
        case .danger:  return .red
        }
    }

    var cardBackground: Color {
        switch self {
        case .normal:  return Color(.secondarySystemGroupedBackground)
        case .warning: return .orange.opacity(0.12)
        case .danger:  return .red.opacity(0.15)
        }
    }

    var label: String {
        switch self {
        case .normal:  return String(localized: "urgency.normal",  defaultValue: "Normale")
        case .warning: return String(localized: "urgency.warning", defaultValue: "Attenzione")
        case .danger:  return String(localized: "urgency.danger",  defaultValue: "Critico")
        }
    }

    var sfSymbol: String {
        switch self {
        case .normal:  return ""
        case .warning: return "exclamationmark.triangle.fill"
        case .danger:  return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - SensorData

/// Dati di un singolo sensore (o gruppo aggregato) da mostrare nella UI.
struct SensorData: Identifiable {
    let id: UUID
    /// UUID di tutti gli accessori che contribuiscono a questo dato aggregato.
    let accessoryUUIDs: [String]
    let serviceType: SensorServiceType
    let roomName: String
    let currentValue: Double
    let lastUpdated: Date
    /// Threshold attivi per il calcolo urgency.
    let warningThreshold: Double
    let dangerThreshold: Double
    /// Numero di sensori fisici aggregati (> 1 quando ci sono duplicati per tipo/stanza).
    let sourceCount: Int

    /// Retrocompatibilità: primo UUID (o stringa vuota se lista vuota).
    var accessoryUUID: String { accessoryUUIDs.first ?? "" }

    var urgency: SensorUrgency {
        if currentValue >= dangerThreshold  { return .danger }
        if currentValue >= warningThreshold { return .warning }
        return .normal
    }

    var formattedValue: String {
        let unit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        ) ?? .celsius
        switch serviceType {
        case .temperature:
            return unit.format(currentValue)
        case .humidity:
            return String(format: "%.0f%%", currentValue)
        case .airQuality:
            switch Int(currentValue) {
            case 1: return String(localized: "airquality.excellent",  defaultValue: "Ottima")
            case 2: return String(localized: "airquality.good",       defaultValue: "Buona")
            case 3: return String(localized: "airquality.fair",       defaultValue: "Media")
            case 4: return String(localized: "airquality.poor",       defaultValue: "Scarsa")
            case 5: return String(localized: "airquality.veryPoor",   defaultValue: "Pessima")
            default: return "—"
            }
        case .carbonMonoxide:
            return String(format: "%.1f ppm", currentValue)
        case .carbonDioxide:
            return String(format: "%.0f ppm", currentValue)
        case .smoke:
            return currentValue >= 1
                ? String(localized: "smoke.detected",     defaultValue: "Rilevato")
                : String(localized: "smoke.notDetected",  defaultValue: "Assente")
        case .vocDensity:
            return String(format: "%.0f µg/m³", currentValue)
        }
    }
}

// MARK: - RoomEnvironmentData

/// Dati ambientali aggregati per una stanza.
struct RoomEnvironmentData: Identifiable {
    let id: UUID
    let roomName: String
    let sensors: [SensorData]

    var worstUrgency: SensorUrgency {
        sensors.map(\.urgency).max() ?? .normal
    }
}

// MARK: - EnvironmentViewModel

/// ViewModel della Dashboard Ambientale.
/// Carica i dati da SwiftData e li prepara per la UI.
@MainActor
final class EnvironmentViewModel: ObservableObject {

    @Published var rooms: [RoomEnvironmentData] = []
    @Published var isLoading: Bool = false
    @Published var lastRefresh: Date?

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Score globale

    /// Score qualità globale pesato da 0 a 1 (1 = tutto ottimo).
    ///
    /// Ogni sensore contribuisce con un punteggio moltiplicato per il suo peso:
    ///   .normal  → 1.0  (nessuna penalità)
    ///   .warning → 0.4  (penalità moderata)
    ///   .danger  → 0.0  (azzerato)
    ///
    /// Pesi per tipo (riflettono l'impatto sulla salute/sicurezza):
    ///   smoke, carbonMonoxide → 3.0  (pericolo vita)
    ///   airQuality, vocDensity → 2.0  (impatto salute)
    ///   temperature, humidity  → 1.0  (comfort)
    var globalScore: Double {
        let allSensors = rooms.flatMap(\.sensors)
        guard !allSensors.isEmpty else { return 1.0 }

        var weightedScore = 0.0
        var totalWeight   = 0.0

        for sensor in allSensors {
            let weight = sensor.serviceType.qualityWeight
            let score: Double
            switch sensor.urgency {
            case .normal:  score = 1.0
            case .warning: score = 0.4
            case .danger:  score = 0.0
            }
            weightedScore += weight * score
            totalWeight   += weight
        }

        guard totalWeight > 0 else { return 1.0 }
        return weightedScore / totalWeight
    }

    var globalLabel: String {
        switch globalScore {
        case 0.85...1.0:  return String(localized: "quality.excellent", defaultValue: "Ottima")
        case 0.60..<0.85: return String(localized: "quality.fair",      defaultValue: "Discreta")
        case 0.35..<0.60: return String(localized: "quality.warning",   defaultValue: "Attenzione")
        default:          return String(localized: "quality.critical",  defaultValue: "Critica")
        }
    }

    var globalColor: Color {
        switch globalScore {
        case 0.85...1.0:  return .green
        case 0.60..<0.85: return .yellow
        case 0.35..<0.60: return .orange
        default:          return .red
        }
    }

    // MARK: - Caricamento da SwiftData

    /// Legge le ultime letture per ogni accessoryUUID+serviceType, aggrega i sensori dello
    /// stesso tipo nella stessa stanza (media per numerici, worst-case per booleani/qualità aria),
    /// poi ordina per worstUrgency decrescente (stanze critiche prima).
    func loadFromCoreData() {
        guard let container = modelContainer else { return }
        isLoading = true

        let context = ModelContext(container)

        // 1. Tutte le letture, più recenti prima
        let allReadings = (try? context.fetch(FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        ))) ?? []

        // 2. Threshold attivi
        let allThresholds = (try? context.fetch(FetchDescriptor<SensorAlertThreshold>())) ?? []

        // 3. Ultima lettura per ogni coppia accessoryUUID+serviceType
        var latestByDevice: [String: SensorReading] = [:]
        for reading in allReadings {
            let key = "\(reading.accessoryUUID)-\(reading.serviceTypeRaw)"
            if latestByDevice[key] == nil {
                latestByDevice[key] = reading
            }
        }

        // 4. Raggruppa per (roomName, serviceType) — chiave di aggregazione
        var byRoomType: [String: [SensorReading]] = [:]
        for reading in latestByDevice.values {
            let key = "\(reading.roomName)|\(reading.serviceTypeRaw)"
            byRoomType[key, default: []].append(reading)
        }

        // 5. Costruisce SensorData aggregati per ogni gruppo
        var byRoom: [String: [SensorData]] = [:]
        for (_, groupReadings) in byRoomType {
            guard let first = groupReadings.first,
                  let serviceType = SensorServiceType(rawValue: first.serviceTypeRaw) else { continue }

            let roomName = first.roomName

            // Threshold: stanza specifica ha priorità sul globale
            let threshold = allThresholds.first(where: {
                $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == roomName
            }) ?? allThresholds.first(where: {
                $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == nil
            })
            let warning = threshold?.warningValue ?? serviceType.defaultWarning
            let danger  = threshold?.dangerValue  ?? serviceType.defaultDanger

            // Aggregazione del valore
            let aggregatedValue: Double
            if serviceType.isBooleanAlert || serviceType == .airQuality {
                // Worst-case: qualsiasi sensore triggered / livello peggiore vince
                aggregatedValue = groupReadings.map(\.value).max() ?? first.value
            } else {
                // Media per sensori numerici (temperatura, umidità, CO, VOC)
                let sum = groupReadings.reduce(0.0) { $0 + $1.value }
                aggregatedValue = sum / Double(groupReadings.count)
            }

            // Timestamp più recente del gruppo
            let latestDate = groupReadings.map(\.timestamp).max() ?? first.timestamp
            // UUID sintetico stabile: deterministico su roomName+serviceType
            let syntheticID = UUID(uuidString: stableUUID(room: roomName, type: serviceType.rawValue)) ?? UUID()

            let sensor = SensorData(
                id: syntheticID,
                accessoryUUIDs: groupReadings.map(\.accessoryUUID),
                serviceType: serviceType,
                roomName: roomName,
                currentValue: aggregatedValue,
                lastUpdated: latestDate,
                warningThreshold: warning,
                dangerThreshold: danger,
                sourceCount: groupReadings.count
            )
            byRoom[roomName, default: []].append(sensor)
        }

        // 6. Costruisce RoomEnvironmentData e ordina
        let roomData = byRoom.map { roomName, sensors -> RoomEnvironmentData in
            RoomEnvironmentData(
                id: UUID(),
                roomName: roomName,
                sensors: sensors.sorted { $0.urgency > $1.urgency }
            )
        }
        .sorted { $0.worstUrgency > $1.worstUrgency }

        rooms = roomData
        lastRefresh = Date()
        isLoading = false
    }

    /// Genera un UUID v5-like deterministico da una stringa composta.
    /// Usa SHA-256 dei byte UTF-8, tronca ai 16 byte necessari per UUID.
    private func stableUUID(room: String, type: String) -> String {
        let input = "\(room)|\(type)"
        // Semplice hash deterministico basato sui code point
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            h ^= UInt64(byte)
            h &*= 1_099_511_628_211
        }
        let h2 = h &+ 0xDEAD_BEEF_CAFE_1234
        // Forma UUID come 8-4-4-4-12 hex
        let a = String(format: "%08X", UInt32(h >> 32))
        let b = String(format: "%04X", UInt16(truncatingIfNeeded: h >> 16))
        let c = String(format: "%04X", UInt16(truncatingIfNeeded: h) | 0x5000)   // versione 5
        let d = String(format: "%04X", UInt16(truncatingIfNeeded: h2 >> 48) | 0x8000)
        let e = String(format: "%012X", h2 & 0x0000_FFFF_FFFF_FFFF)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    // MARK: - Storico sensore

    /// Restituisce le letture delle ultime 24 ore per un sensore aggregato.
    /// Recupera le letture di tutti gli accessori che compongono l'aggregato
    /// (stesso tipo + stessa stanza), poi le unisce e le ordina per timestamp.
    func loadHistory(for sensor: SensorData) -> [SensorReading] {
        guard let container = modelContainer else { return [] }
        let context = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let typeRaw = sensor.serviceType.rawValue
        let room    = sensor.roomName

        // Recupera tutte le letture della stanza+tipo nelle ultime 24h,
        // senza filtrare per UUID (include tutti i dispositivi del gruppo).
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.serviceTypeRaw == typeRaw &&
                $0.roomName == room &&
                $0.timestamp > cutoff
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Mock per Preview

    /// Crea un ViewModel con dati fittizi per Xcode Previews.
    static func mock() -> EnvironmentViewModel {
        let vm = EnvironmentViewModel()
        let now = Date()

        let kitchen = RoomEnvironmentData(
            id: UUID(),
            roomName: "Cucina",
            sensors: [
                SensorData(id: UUID(), accessoryUUIDs: ["a1"], serviceType: .temperature,
                           roomName: "Cucina", currentValue: 24.5, lastUpdated: now,
                           warningThreshold: 28, dangerThreshold: 32, sourceCount: 1),
                SensorData(id: UUID(), accessoryUUIDs: ["a2"], serviceType: .humidity,
                           roomName: "Cucina", currentValue: 68.0, lastUpdated: now,
                           warningThreshold: 65, dangerThreshold: 75, sourceCount: 1),
            ]
        )

        let living = RoomEnvironmentData(
            id: UUID(),
            roomName: "Soggiorno",
            sensors: [
                // Simulazione: 3 sensori temperatura aggregati in media
                SensorData(id: UUID(), accessoryUUIDs: ["b1", "b3", "b4"], serviceType: .temperature,
                           roomName: "Soggiorno", currentValue: 21.3, lastUpdated: now,
                           warningThreshold: 28, dangerThreshold: 32, sourceCount: 3),
                SensorData(id: UUID(), accessoryUUIDs: ["b2"], serviceType: .airQuality,
                           roomName: "Soggiorno", currentValue: 2.0, lastUpdated: now,
                           warningThreshold: 3, dangerThreshold: 4, sourceCount: 1),
            ]
        )

        let bedroom = RoomEnvironmentData(
            id: UUID(),
            roomName: "Camera da letto",
            sensors: [
                SensorData(id: UUID(), accessoryUUIDs: ["c1"], serviceType: .temperature,
                           roomName: "Camera da letto", currentValue: 33.0, lastUpdated: now,
                           warningThreshold: 28, dangerThreshold: 32, sourceCount: 1),
                SensorData(id: UUID(), accessoryUUIDs: ["c2"], serviceType: .carbonMonoxide,
                           roomName: "Camera da letto", currentValue: 26.0, lastUpdated: now,
                           warningThreshold: 10, dangerThreshold: 25, sourceCount: 1),
            ]
        )

        vm.rooms = [bedroom, kitchen, living]
        vm.lastRefresh = now
        return vm
    }
}
