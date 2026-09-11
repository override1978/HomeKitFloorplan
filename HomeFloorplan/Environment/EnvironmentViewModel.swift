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
    let isEnabled: Bool
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
        case .warning: return FloorplanTokens.Semantic.warning
        case .danger:  return FloorplanTokens.Semantic.critical
        }
    }

    var cardBackground: Color {
        switch self {
        case .normal:  return Color(.secondarySystemGroupedBackground)
        case .warning: return FloorplanTokens.Semantic.warning.opacity(0.12)
        case .danger:  return FloorplanTokens.Semantic.critical.opacity(0.15)
        }
    }

    var label: String {
        switch self {
        case .normal:  return String(localized: "urgency.normal",  defaultValue: "Normal")
        case .warning: return String(localized: "urgency.warning", defaultValue: "Attention")
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
/// Direzione di un valore sensore rispetto a ~45+ minuti fa.
enum SensorTrend {
    case rising, falling, steady

    var symbolName: String? {
        switch self {
        case .rising:  return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .steady:  return nil
        }
    }
}

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

    /// Direzione rispetto alla lettura di ~45+ minuti fa (default per i mock).
    var trend: SensorTrend = .steady

    /// Da quanto il sensore non si fa sentire. `nil` quando è vivo.
    ///
    /// Un sensore muto non è un sensore a posto. Finché questo campo non
    /// esisteva l'ultima lettura restava in scena travestita da attuale: una
    /// stanza col termometro spento da tre giorni continuava a colorarsi
    /// secondo un numero di tre giorni prima. Qui il valore resta visibile —
    /// buttarlo via perderebbe l'unica informazione disponibile — ma smette di
    /// contare per l'urgenza e per il punteggio.
    var staleFor: TimeInterval?

    var isStale: Bool { staleFor != nil }

    /// Retrocompatibilità: primo UUID (o stringa vuota se lista vuota).
    var accessoryUUID: String { accessoryUUIDs.first ?? "" }

    var urgency: SensorUrgency {
        guard serviceType != .lightSensor else { return .normal }
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
            case 5: return String(localized: "airquality.veryPoor",   defaultValue: "Very poor")
            default: return "—"
            }
        case .carbonMonoxide:
            return String(format: "%.1f ppm", currentValue)
        case .carbonDioxide:
            return String(format: "%.0f ppm", currentValue)
        case .smoke:
            return currentValue >= 1
                ? String(localized: "smoke.detected",     defaultValue: "Rilevato")
                : String(localized: "smoke.notDetected",  defaultValue: "Libero")
        case .vocDensity:
            return String(format: "%.0f µg/m³", currentValue)
        case .pm25, .pm10:
            return String(format: "%.0f µg/m³", currentValue)
        case .lightSensor:
            return String(format: "%.0f lux", currentValue)
        case .outdoorTemperature:
            return unit.format(currentValue)
        case .outdoorHumidity:
            return String(format: "%.0f%%", currentValue)
        }
    }
}

// MARK: - RoomEnvironmentData

/// Dati ambientali aggregati per una stanza.
struct RoomEnvironmentData: Identifiable {
    let id: UUID
    let roomName: String
    let sensors: [SensorData]

    /// I soli sensori che stanno ancora parlando.
    var liveSensors: [SensorData] { sensors.filter { !$0.isStale } }

    /// Vero quando la stanza ha sensori ma tacciono tutti.
    ///
    /// È lo stato che mancava, e la ragione per cui serviva: senza, «non lo
    /// so» e «va bene» finiscono dipinti dello stesso verde.
    var isSilent: Bool { !sensors.isEmpty && liveSensors.isEmpty }

    /// Da quanto la stanza non dice niente: il più recente fra i suoi silenzi.
    var silentFor: TimeInterval? {
        sensors.compactMap(\.staleFor).min()
    }

    var worstUrgency: SensorUrgency {
        liveSensors.map(\.urgency).max() ?? .normal
    }

    /// Quality score 0.0–1.0 using the same weighted algorithm as `EnvironmentViewModel.globalScore`
    /// but scoped to this room's sensors.
    var qualityScore: Double {
        let scored = liveSensors
        guard !scored.isEmpty else { return 1.0 }
        var weightedScore = 0.0
        var totalWeight   = 0.0
        for sensor in scored {
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

    /// Stesse bande delle soglie colore uniche (v3): l'etichetta non può dire
    /// "Attenzione" dove il colore dice critico — un 40% È critico.
    var qualityLabel: String {
        // Una stanza muta non è una stanza eccellente: senza questo ramo il
        // punteggio neutro di partenza la farebbe apparire perfetta.
        if isSilent { return String(localized: "quality.silent", defaultValue: "No data") }
        switch qualityScore {
        case 0.85...1.0:  return String(localized: "quality.excellent", defaultValue: "Excellent")
        case 0.60..<0.85: return String(localized: "quality.fair",      defaultValue: "Fair")
        default:          return String(localized: "quality.critical",  defaultValue: "Critical")
        }
    }

    /// Soglie colore uniche del design v3: verde ≥85, arancio 60–84,
    /// rosso <60 — le stesse ovunque, mai un 66% rosso e un 70% arancio
    /// nella stessa schermata.
    var qualityColor: Color {
        if isSilent { return .secondary }
        return FloorplanTokens.Semantic.forScore(Int((qualityScore * 100).rounded()))
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

    var rooms: [RoomEnvironmentData] = [] {
        didSet { updateDerivedCache() }
    }
    var isLoading: Bool = false
    var lastRefresh: Date?

    private var modelContainer: ModelContainer?
    private var currentLoadTask: Task<Void, Never>?

    // MARK: - Cache per il percorso vivo

    /// Soglie utente, tenute da parte dopo il primo caricamento.
    ///
    /// Cambiano forse una volta al mese, e finora venivano rilette per intero
    /// a ogni ricarica insieme alle 500 letture. Il percorso vivo le legge da
    /// qui, così non deve toccare l'archivio per sapere quando un valore è
    /// fuori soglia.
    private var cachedThresholds: [RawSensorThreshold] = []

    /// Direzione a 45 minuti, per «stanza|tipo».
    ///
    /// Il trend è l'unica cosa nella schermata che ha davvero bisogno dello
    /// storico: un valore corrente non sa da dove viene. Resta quindi un
    /// prodotto dell'archivio, ma smette di stare sul percorso critico —
    /// arriva dopo il primo disegno e il percorso vivo lo riusa così com'è.
    private var cachedTrends: [String: SensorTrend] = [:]

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

    /// Lo stato vivo, quando il chiamante ne ha uno.
    ///
    /// Opzionale perché le altre istanze di questo ViewModel non lo passano
    /// ancora: senza, tutto continua a funzionare come prima, dall'archivio.
    private var liveState: HomeState?

    func configure(modelContainer: ModelContainer, homeState: HomeState? = nil) {
        self.modelContainer = modelContainer
        if let homeState { self.liveState = homeState }
    }

    // MARK: - Score globale (cached — recomputed only when rooms changes)

    /// Cached quality score 0–1. Updated via `rooms.didSet` → `updateDerivedCache()`.
    private(set) var globalScore: Double = 1.0

    /// Cached sensor type list, sorted by qualityWeight descending. Updated with globalScore.
    private(set) var availableSensorTypes: [SensorServiceType] = []

    private func updateDerivedCache() {
        let allSensors = rooms.flatMap(\.sensors)
        guard !allSensors.isEmpty else {
            globalScore = 1.0
            availableSensorTypes = []
            return
        }
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
        globalScore = totalWeight > 0 ? weightedScore / totalWeight : 1.0
        let allTypes = Set(allSensors.map(\.serviceType))
        availableSensorTypes = allTypes.sorted { $0.qualityWeight > $1.qualityWeight }
    }

    var globalLabel: String {
        switch globalScore {
        case 0.85...1.0:  return String(localized: "quality.excellent", defaultValue: "Excellent")
        case 0.60..<0.85: return String(localized: "quality.fair",      defaultValue: "Fair")
        case 0.35..<0.60: return String(localized: "quality.warning",   defaultValue: "Attention")
        default:          return String(localized: "quality.critical",  defaultValue: "Critical")
        }
    }

    /// Stesse soglie uniche di `qualityColor` (design v3).
    var globalColor: Color {
        FloorplanTokens.Semantic.forScore(Int((globalScore * 100).rounded()))
    }

    // MARK: - Percorso vivo (HomeState)

    /// Ricostruisce `rooms` dallo stato in memoria. Sincrono, nessun fetch.
    ///
    /// È la differenza fra aprire la schermata e aspettarla. Il percorso da
    /// archivio fa un fetch di 500 letture più tutte le soglie, le mappa in
    /// DTO e poi le rimastica in sei passaggi — per mostrare un numero che nel
    /// frattempo ha già fino a quindici minuti. Qui i valori correnti arrivano
    /// dalle notifiche che HomeKit consegna in tempo reale, e leggerli costa
    /// un accesso a dizionario.
    ///
    /// Quello che l'archivio continua a dare è ciò che solo lui può dare: il
    /// trend, che richiede un prima. Finché non è arrivato i sensori sono
    /// `.steady`, che è la stessa cosa che succedeva quando la lettura di
    /// confronto mancava.
    ///
    /// I sensori stantii non entrano proprio: `HomeState` li esclude a monte,
    /// quindi un sensore spento da giorni smette di pesare sul punteggio della
    /// stanza invece di restarci con un numero che sembra attuale.
    @discardableResult
    func applyLiveState(_ homeState: HomeState, now: Date = Date()) -> [RoomEnvironmentData] {
        var byRoom: [String: [SensorData]] = [:]

        for roomUUID in homeState.knownRoomUUIDs {
            guard let roomName = homeState.roomName(roomUUID) else { continue }

            for serviceType in homeState.typesEverSeen(inRoom: roomUUID) {
                let everything = homeState.everyReading(serviceType, inRoom: roomUUID)
                let live = everything.filter { !$0.isStale(after: HomeState.defaultStaleInterval, now: now) }

                // Se qualcuno parla ancora si usa solo lui. Se tacciono tutti si
                // tiene comunque l'ultima parola detta, marcata: buttarla via
                // perderebbe l'unica informazione che resta, e mostrarla senza
                // marcarla è la bugia che stiamo togliendo.
                let group = live.isEmpty ? everything : live
                guard let first = group.first else { continue }
                let staleFor: TimeInterval? = live.isEmpty
                    ? group.map { $0.age(now: now) }.min()
                    : nil

                let aggregatedValue: Double
                if serviceType.isBooleanAlert || serviceType == .airQuality {
                    aggregatedValue = group.map(\.value).max() ?? first.value
                } else {
                    aggregatedValue = group.reduce(0.0) { $0 + $1.value } / Double(group.count)
                }

                let threshold = cachedThresholds.first {
                    $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == roomName && $0.isEnabled
                } ?? cachedThresholds.first {
                    $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == nil && $0.isEnabled
                }

                let syntheticID = UUID(uuidString: stableUUID(room: roomName, type: serviceType.rawValue)) ?? UUID()

                byRoom[roomName, default: []].append(SensorData(
                    id: syntheticID,
                    accessoryUUIDs: group.map(\.accessoryUUID).map(\.uuidString),
                    serviceType: serviceType,
                    roomName: roomName,
                    currentValue: aggregatedValue,
                    lastUpdated: group.map(\.confirmedAt).max() ?? now,
                    warningThreshold: threshold?.warningValue ?? serviceType.defaultWarning,
                    dangerThreshold:  threshold?.dangerValue  ?? serviceType.defaultDanger,
                    sourceCount: group.count,
                    trend: cachedTrends["\(roomName)|\(serviceType.rawValue)"] ?? .steady,
                    staleFor: staleFor
                ))
            }
        }

        rooms = Self.arrange(byRoom, customOrder: customOrderNames)
        lastRefresh = now
        return rooms
    }

    /// Ordine dei sensori dentro una stanza: prima chi ha qualcosa da dire,
    /// poi per peso, poi per nome.
    ///
    /// I due criteri di spareggio non sono pedanteria. Ordinando solo per
    /// urgenza, quando i sensori stanno tutti bene — cioè quasi sempre — la
    /// relazione non decide niente e l'ordine finale resta quello, arbitrario,
    /// in cui il dizionario di partenza si è fatto scorrere. Finché la lista si
    /// ricostruiva ogni quindici minuti la cosa passava inosservata; da quando
    /// si ricostruisce a ogni notifica HomeKit le icone si rimescolano sotto
    /// gli occhi a ogni aggiornamento.
    private static func sensorOrder(_ a: SensorData, _ b: SensorData) -> Bool {
        if a.urgency != b.urgency { return a.urgency > b.urgency }
        let wa = a.serviceType.qualityWeight, wb = b.serviceType.qualityWeight
        if wa != wb { return wa > wb }
        return a.serviceType.rawValue < b.serviceType.rawValue
    }

    /// Ordine delle stanze: prima chi ha qualcosa da segnalare, poi per nome.
    private static func roomOrder(_ a: RoomEnvironmentData, _ b: RoomEnvironmentData) -> Bool {
        if a.worstUrgency != b.worstUrgency { return a.worstUrgency > b.worstUrgency }
        return a.roomName.localizedCaseInsensitiveCompare(b.roomName) == .orderedAscending
    }

    /// Ordinamento condiviso dai due percorsi: stanze critiche prima, salvo
    /// l'ordine scelto dall'utente. Duplicarlo significherebbe farli divergere.
    private static func arrange(_ byRoom: [String: [SensorData]],
                                customOrder: [String]) -> [RoomEnvironmentData] {
        // Esclude la stanza sintetica outdoor: i dati meteo hanno il loro banner.
        let outdoorUUID = "weather.outdoor"
        // In passaggi espliciti e non in catena: incatenati, filter/map/sorted
        // con questi predicati mandano il type-checker fuori tempo massimo.
        var built: [RoomEnvironmentData] = []
        built.reserveCapacity(byRoom.count)
        for (roomName, sensors) in byRoom {
            let isSyntheticOutdoor = sensors.allSatisfy { $0.accessoryUUIDs == [outdoorUUID] }
            guard !isSyntheticOutdoor else { continue }
            built.append(RoomEnvironmentData(id: UUID(),
                                             roomName: roomName,
                                             sensors: sensors.sorted(by: sensorOrder)))
        }

        // Il nome come spareggio: fra stanze ugualmente tranquille l'urgenza non
        // ordina niente, e senza un secondo criterio la griglia si
        // rimescolerebbe a ogni aggiornamento.
        let roomData = built.sorted(by: roomOrder)

        guard !customOrder.isEmpty else { return roomData }
        let orderMap = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($1, $0) })
        return roomData.sorted { a, b in
            (orderMap[a.roomName] ?? Int.max) < (orderMap[b.roomName] ?? Int.max)
        }
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
        currentLoadTask = Task {
            _ = await performReloadFromCoreData()
        }
    }

    /// Reloads environment data and returns only after `rooms` has been updated.
    /// Use this before running AI analysis that depends on freshly sampled readings.
    @discardableResult
    func reloadFromCoreData() async -> [RoomEnvironmentData] {
        currentLoadTask?.cancel()
        currentLoadTask = nil
        return await performReloadFromCoreData()
    }

    @discardableResult
    private func performReloadFromCoreData() async -> [RoomEnvironmentData] {
        guard let container = modelContainer else { return rooms }
        isLoading = true

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
            let t = fetchedThresholds.map { RawSensorThreshold(serviceTypeRaw: $0.serviceTypeRaw, roomName: $0.roomName, warningValue: $0.warningValue, dangerValue: $0.dangerValue, isEnabled: $0.isEnabled) }
            return (r, t)
        }.value

        guard !Task.isCancelled else {
            isLoading = false
            return rooms
        }

        // ── Fase 2: elaborazione su main actor (veloce, in-memory) ──────

            // 0. Indice per il trend: per ogni coppia accessoryUUID+serviceType,
            //    la lettura più recente ANTERIORE al cutoff. Precomputato una
            //    volta sola — prima ogni gruppo rifaceva una scansione lineare
            //    di rawReadings (fino a 500) sul main actor, cioè decine di
            //    migliaia di confronti per reload.
            let trendCutoff = Date().addingTimeInterval(-45 * 60)
            var olderByDevice: [String: RawSensorReading] = [:]
            for r in rawReadings where r.timestamp < trendCutoff {
                let key = "\(r.accessoryUUID)-\(r.serviceTypeRaw)"
                if olderByDevice[key] == nil { olderByDevice[key] = r }
            }

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

                let threshold = rawThresholds.first(where: { $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == roomName && $0.isEnabled })
                    ?? rawThresholds.first(where: { $0.serviceTypeRaw == serviceType.rawValue && $0.roomName == nil && $0.isEnabled })

                let aggregatedValue: Double
                if serviceType.isBooleanAlert || serviceType == .airQuality {
                    aggregatedValue = group.map(\.value).max() ?? first.value
                } else {
                    aggregatedValue = group.reduce(0.0) { $0 + $1.value } / Double(group.count)
                }

                // Trend: confronta l'aggregato con la lettura più recente ma più
                // vecchia di 45 min per gli stessi accessori (rawReadings è già
                // ordinato per timestamp decrescente — nessuna query aggiuntiva).
                var trend = SensorTrend.steady
                if !serviceType.isBooleanAlert && serviceType != .airQuality {
                    // Lookup O(gruppo) sull'indice precomputato invece della
                    // scansione lineare di tutte le letture per ogni gruppo.
                    let older = group
                        .compactMap { olderByDevice["\($0.accessoryUUID)-\(serviceType.rawValue)"] }
                        .max { $0.timestamp < $1.timestamp }
                    if let older {
                        let epsilon: Double
                        switch serviceType {
                        case .temperature: epsilon = 0.3
                        case .humidity:    epsilon = 2
                        default:           epsilon = max(abs(older.value) * 0.05, 0.5)
                        }
                        let delta = aggregatedValue - older.value
                        if delta > epsilon { trend = .rising }
                        else if delta < -epsilon { trend = .falling }
                    }
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
                    sourceCount: group.count,
                    trend: trend
                ))
            }

            // 4. Alimenta le cache del percorso vivo con ciò che solo
            //    l'archivio sa: le soglie utente e la direzione a 45 minuti.
            //    Da qui in poi la schermata può ridisegnarsi dallo stato in
            //    memoria senza tornare a leggere il disco.
            cachedThresholds = rawThresholds
            for (_, sensors) in byRoom {
                for sensor in sensors {
                    cachedTrends["\(sensor.roomName)|\(sensor.serviceType.rawValue)"] = sensor.trend
                }
            }

            // 5. Costruisce, ordina e applica l'ordinamento utente.
            //
            //    Se c'è uno stato vivo, i valori correnti li ha lui: qui si
            //    ridisegna da quello, ora che le cache sono piene. Assegnare
            //    `byRoom` sovrascriverebbe numeri freschi con numeri vecchi
            //    fino alla notifica successiva — cioè la schermata si
            //    aggiornerebbe *all'indietro* dopo il primo disegno.
            if let liveState {
                applyLiveState(liveState)
            } else {
                rooms = Self.arrange(byRoom, customOrder: customOrderNames)
            }
            guard !Task.isCancelled else {
                isLoading = false
                return rooms
            }
            lastRefresh = Date()
            isLoading   = false
            #if DEBUG
            dprint("⏱ [loadFromCoreData] \(ContinuousClock.now - _loadStart) | readings=\(rawReadings.count) rooms=\(rooms.count)")
            #endif
        return rooms
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
