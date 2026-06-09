import Foundation
import SwiftUI
import SwiftData
import Observation

// MARK: - Raw transfer types (Sendable, safe across actor boundaries)

private struct RawSensorReading: Sendable {
    let accessoryUUID: String
    let serviceTypeRaw: String
    let roomName: String
    let value: Double
    let timestamp: Date
}

private struct RawSensorThreshold: Sendable {
    let serviceTypeRaw: String
    let roomName: String?
    let warningValue: Double
    let dangerValue: Double
}

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
        case .normal:  return String(localized: "urgency.normal",  defaultValue: "Normal")
        case .warning: return String(localized: "urgency.warning", defaultValue: "Warning")
        case .danger:  return String(localized: "urgency.danger",  defaultValue: "Critical")
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
            case 1: return String(localized: "airquality.excellent",  defaultValue: "Excellent")
            case 2: return String(localized: "airquality.good",       defaultValue: "Good")
            case 3: return String(localized: "airquality.fair",       defaultValue: "Fair")
            case 4: return String(localized: "airquality.poor",       defaultValue: "Poor")
            case 5: return String(localized: "airquality.veryPoor",   defaultValue: "Very Poor")
            default: return "—"
            }
        case .carbonMonoxide:
            return String(format: "%.1f ppm", currentValue)
        case .carbonDioxide:
            return String(format: "%.0f ppm", currentValue)
        case .smoke:
            return currentValue >= 1
                ? String(localized: "smoke.detected",     defaultValue: "Detected")
                : String(localized: "smoke.notDetected",  defaultValue: "Clear")
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

    /// Quality score 0.0–1.0 using the same weighted algorithm as `EnvironmentViewModel.globalScore`
    /// but scoped to this room's sensors.
    var qualityScore: Double {
        guard !sensors.isEmpty else { return 1.0 }
        var weightedScore = 0.0
        var totalWeight   = 0.0
        for sensor in sensors {
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
        return totalWeight > 0 ? weightedScore / totalWeight : 1.0
    }

    var qualityLabel: String {
        switch qualityScore {
        case 0.85...1.0:  return String(localized: "quality.excellent", defaultValue: "Excellent")
        case 0.60..<0.85: return String(localized: "quality.fair",      defaultValue: "Fair")
        case 0.35..<0.60: return String(localized: "quality.warning",   defaultValue: "Warning")
        default:          return String(localized: "quality.critical",  defaultValue: "Critical")
        }
    }

    var qualityColor: Color {
        switch qualityScore {
        case 0.85...1.0:  return .green
        case 0.60..<0.85: return .yellow
        case 0.35..<0.60: return .orange
        default:          return .red
        }
    }

    /// Classifica la stanza usando RoomClassifier.
    /// - Parameter outdoorRoomName: Nome stanza outdoor da AppStorage "outdoorRoomName".
    func roomType(outdoorRoomName: String = "") -> RoomType {
        RoomClassifier.classify(roomName: roomName, outdoorRoomName: outdoorRoomName)
    }
}

// MARK: - EnvironmentViewModel

/// ViewModel della Dashboard Ambientale.
/// Carica i dati da SwiftData e li prepara per la UI.
@Observable
@MainActor
final class EnvironmentViewModel {

    var rooms: [RoomEnvironmentData] = []
    var isLoading: Bool = false
    var lastRefresh: Date?

    private var modelContainer: ModelContainer?
    private var currentLoadTask: Task<Void, Never>?

    // MARK: - Ordinamento custom

    static let orderKey = "environmentRoomOrder"

    /// Ordine personalizzato: array di roomName nell'ordine desiderato dall'utente.
    /// Vuoto = nessun ordine personalizzato (usa il default per urgency).
    private var customOrderNames: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.orderKey) }
    }

    /// Persiste l'ordine corrente. Passa un array vuoto per ripristinare il default.
    func saveOrder(_ orderedRooms: [RoomEnvironmentData]) {
        customOrderNames = orderedRooms.map(\.roomName)
    }

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
        case 0.85...1.0:  return String(localized: "quality.excellent", defaultValue: "Excellent")
        case 0.60..<0.85: return String(localized: "quality.fair",      defaultValue: "Fair")
        case 0.35..<0.60: return String(localized: "quality.warning",   defaultValue: "Warning")
        default:          return String(localized: "quality.critical",  defaultValue: "Critical")
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

    /// Distinct sensor types present in the current data, sorted by qualityWeight descending
    /// (highest-impact types first: smoke, CO, CO₂, air quality, temperature, humidity).
    var availableSensorTypes: [SensorServiceType] {
        let allTypes = Set(rooms.flatMap { $0.sensors.map(\.serviceType) })
        return allTypes.sorted { $0.qualityWeight > $1.qualityWeight }
    }

    // MARK: - Caricamento da SwiftData

    /// Legge le ultime letture per ogni accessoryUUID+serviceType, aggrega i sensori dello
    /// stesso tipo nella stessa stanza (media per numerici, worst-case per booleani/qualità aria),
    /// poi ordina per worstUrgency decrescente (stanze critiche prima).
    ///
    /// Fase 1 (background): SwiftData fetch — lento, I/O-bound.
    /// Fase 2 (main actor): elaborazione — veloce, in-memory.
    func loadFromCoreData() {
        currentLoadTask?.cancel()
        guard let container = modelContainer else { return }
        isLoading = true

        currentLoadTask = Task {
            #if DEBUG
            let _loadStart = ContinuousClock.now
            #endif
            // ── Fase 1: fetch off main thread ───────────────────────────────
            let (rawReadings, rawThresholds) = await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)

                // Limita alle 500 letture più recenti: copre tutti i dispositivi attivi
                // evitando di scansionare l'intera storia (fino a 30 giorni × N sensori).
                var desc = FetchDescriptor<SensorReading>(
                    sortBy: [SortDescriptor(\SensorReading.timestamp, order: .reverse)]
                )
                desc.fetchLimit = 500

                let fetchedReadings    = (try? context.fetch(desc)) ?? []
                let fetchedThresholds  = (try? context.fetch(FetchDescriptor<SensorAlertThreshold>())) ?? []

                // Estraiamo subito value-type Sendable per evitare di passare @Model tra attori
                let r = fetchedReadings.map { RawSensorReading(accessoryUUID: $0.accessoryUUID, serviceTypeRaw: $0.serviceTypeRaw, roomName: $0.roomName, value: $0.value, timestamp: $0.timestamp) }
                let t = fetchedThresholds.map { RawSensorThreshold(serviceTypeRaw: $0.serviceTypeRaw, roomName: $0.roomName, warningValue: $0.warningValue, dangerValue: $0.dangerValue) }
                return (r, t)
            }.value

            // ── Fase 2: elaborazione su main actor (veloce, in-memory) ──────

            // 1. Ultima lettura per ogni coppia accessoryUUID+serviceType
            var latestByDevice: [String: RawSensorReading] = [:]
            for r in rawReadings {
                let key = "\(r.accessoryUUID)-\(r.serviceTypeRaw)"
                if latestByDevice[key] == nil { latestByDevice[key] = r }
            }

            // 2. Raggruppa per (roomName, serviceType)
            var byRoomType: [String: [RawSensorReading]] = [:]
            for r in latestByDevice.values {
                byRoomType["\(r.roomName)|\(r.serviceTypeRaw)", default: []].append(r)
            }

            // 3. Costruisce SensorData aggregati
            var byRoom: [String: [SensorData]] = [:]
            for (_, group) in byRoomType {
                guard let first = group.first,
                      let serviceType = SensorServiceType(rawValue: first.serviceTypeRaw) else { continue }
                let roomName = first.roomName

                let threshold = rawThresholds.first(where: { $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == roomName })
                    ?? rawThresholds.first(where: { $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == nil })

                let aggregatedValue: Double
                if serviceType.isBooleanAlert || serviceType == .airQuality {
                    aggregatedValue = group.map(\.value).max() ?? first.value
                } else {
                    aggregatedValue = group.reduce(0.0) { $0 + $1.value } / Double(group.count)
                }

                let syntheticID = UUID(uuidString: stableUUID(room: roomName, type: serviceType.rawValue)) ?? UUID()

                byRoom[roomName, default: []].append(SensorData(
                    id: syntheticID,
                    accessoryUUIDs: group.map(\.accessoryUUID),
                    serviceType: serviceType,
                    roomName: roomName,
                    currentValue: aggregatedValue,
                    lastUpdated: group.map(\.timestamp).max() ?? first.timestamp,
                    warningThreshold: threshold?.warningValue ?? serviceType.defaultWarning,
                    dangerThreshold:  threshold?.dangerValue  ?? serviceType.defaultDanger,
                    sourceCount: group.count
                ))
            }

            // 4. Costruisce RoomEnvironmentData e ordina
            let roomData = byRoom.map { roomName, sensors -> RoomEnvironmentData in
                RoomEnvironmentData(id: UUID(), roomName: roomName, sensors: sensors.sorted { $0.urgency > $1.urgency })
            }
            .sorted { $0.worstUrgency > $1.worstUrgency }

            // 5. Applica ordinamento utente
            let orderNames = customOrderNames
            if orderNames.isEmpty {
                rooms = roomData
            } else {
                let orderMap = Dictionary(uniqueKeysWithValues: orderNames.enumerated().map { ($1, $0) })
                rooms = roomData.sorted { a, b in
                    (orderMap[a.roomName] ?? Int.max) < (orderMap[b.roomName] ?? Int.max)
                }
            }
            guard !Task.isCancelled else { return }
            lastRefresh = Date()
            isLoading   = false
            #if DEBUG
            dprint("⏱ [loadFromCoreData] \(ContinuousClock.now - _loadStart) | readings=\(rawReadings.count) rooms=\(rooms.count)")
            #endif
        }
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
