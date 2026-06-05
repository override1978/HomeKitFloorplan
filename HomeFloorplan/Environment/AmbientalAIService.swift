import Foundation
import HomeKit
import SwiftData
import Observation

// MARK: - AmbientalAIService

/// Analizza i dati ambientali delle stanze e genera insight AI contestuali.
/// Complementa i warning manuali (basati su soglie) con pattern temporali e
/// anomalie storiche che le soglie fisse non possono rilevare.
///
/// Frequenza: chiamato ogni 15 minuti per stanza (solo se app attiva).
/// Graceful degradation: se AI non configurata, `insights` rimane vuoto senza errori.
///
/// Sprint 4: pre-processing deterministico prima di ogni chiamata LLM:
///   - Gate AI: salta la chiamata se tutto è nella norma (urgency=normal, nessuna anomalia)
///   - Severity clamping: la severity LLM è limitata al ceiling deterministico
///   - Intent filtering: intent HVAC/ventilazione rimossi per stanze outdoor
///   - RoomType: classificazione keyword-based, override tramite UserDefaults "outdoorRoomName"
@Observable
@MainActor
final class AmbientalAIService {

    // MARK: - State

    /// Insight attivi (non dismessi, non scaduti) per tutte le stanze.
    var insights: [AmbientalAIInsight] = []
    var isAnalyzing: Bool = false
    var lastAnalyzed: Date?

    // MARK: - Private

    private let aiSettings: AISettings
    private let modelContainer: ModelContainer
    private let homeKit: HomeKitService
    private let resolver: ActionResolver
    let effectivenessTracker: ActionEffectivenessTracker
    /// Intervallo minimo tra analisi per la stessa stanza (15 min).
    private var lastAnalysisByRoom: [String: Date] = [:]
    private let minInterval: TimeInterval = 15 * 60

    /// Nome stanza outdoor impostato dall'utente (AppStorage "outdoorRoomName").
    private var outdoorRoomName: String {
        UserDefaults.standard.string(forKey: "outdoorRoomName") ?? ""
    }

    // MARK: - Init

    /// - Parameter tracker: Tracker condiviso. Se nil, ne viene creato uno autonomo
    ///   (backward-compatible per le istanze locali nelle view come EnvironmentContextDashboard).
    init(
        aiSettings: AISettings,
        modelContainer: ModelContainer,
        homeKit: HomeKitService,
        tracker: ActionEffectivenessTracker? = nil
    ) {
        self.aiSettings = aiSettings
        self.modelContainer = modelContainer
        self.homeKit = homeKit
        let resolvedTracker = tracker ?? ActionEffectivenessTracker(modelContainer: modelContainer)
        self.effectivenessTracker = resolvedTracker
        // Sprint 6: passa il tracker al resolver così i candidati vengono
        // ordinati per effectiveness storica per accessorio.
        self.resolver = ActionResolver(homeKit: homeKit, tracker: resolvedTracker)
    }

    // MARK: - Public API

    /// Analizza tutte le stanze fornite e aggiunge insight per quelle che ne hanno bisogno.
    /// Rispetta l'intervallo minimo di 15 minuti per stanza.
    func analyzeRooms(_ rooms: [RoomEnvironmentData]) async {
        guard aiSettings.isOperational, aiSettings.anomalyDetectionEnabled else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // Traccia gli insight scaduti prima di rimuoverli
        for insight in insights where insight.isExpired && !insight.isDismissed {
            effectivenessTracker.trackExpiration(
                intents: insight.resolvedIntents,
                roomName: insight.roomName,
                severityRaw: insight.severity.rawValue,
                suggestedAt: insight.generatedAt
            )
        }

        // Rimuovi insight scaduti prima di procedere
        insights = insights.filter { $0.isVisible }

        for room in rooms {
            let now = Date()
            if let last = lastAnalysisByRoom[room.roomName],
               now.timeIntervalSince(last) < minInterval { continue }

            let readings = loadHistory(for: room)
            guard !readings.isEmpty else { continue }

            await analyzeRoom(room, readings: readings)
            lastAnalysisByRoom[room.roomName] = now
        }

        lastAnalyzed = Date()
    }

    /// Dismette un insight specifico e registra il dismissal per il tracking.
    func dismiss(_ insight: AmbientalAIInsight) {
        if let idx = insights.firstIndex(where: { $0.id == insight.id }) {
            insights[idx].isDismissed = true
            effectivenessTracker.trackDismissal(
                intents: insight.resolvedIntents,
                roomName: insight.roomName,
                severityRaw: insight.severity.rawValue,
                suggestedAt: insight.generatedAt
            )
            // Phase 7 trace: dismissal event
            #if DEBUG
            AITraceLogger.shared.logInsightDismissed(
                roomName: insight.roomName,
                intents: insight.resolvedIntents
            )
            #endif
        }
    }

    /// Restituisce gli insight visibili per una stanza specifica.
    func visibleInsights(for roomName: String) -> [AmbientalAIInsight] {
        insights.filter { $0.roomName == roomName && $0.isVisible }
    }

    /// True se la stanza ha almeno un insight AI visibile.
    func hasActiveInsight(for roomName: String) -> Bool {
        insights.contains { $0.roomName == roomName && $0.isVisible }
    }

    // MARK: - Room Analysis

    private func analyzeRoom(_ room: RoomEnvironmentData, readings: [SensorReading]) async {
        // Step 1: calcola baseline 7 giorni
        let baseline = computeBaseline(sensors: room.sensors, readings: readings)

        // Phase 1 trace: raw sensor snapshot
        #if DEBUG
        AITraceLogger.shared.logRawSnapshot(
            roomName: room.roomName,
            sensors: room.sensors.map { (type: $0.serviceType.rawValue, value: $0.currentValue) }
        )
        #endif

        // Step 2: pre-processing deterministico
        let preResult = EnvironmentPreProcessor.preProcess(
            room: room,
            baselineByType: baseline,
            outdoorRoomName: outdoorRoomName
        )

        // Phase 2 trace: preprocessor evaluation with full baseline stats
        #if DEBUG
        let baselineStats: [String: BaselineStat] = baseline.reduce(into: [:]) { dict, pair in
            // Count samples used for this sensor type
            let n = readings.filter { $0.serviceTypeRaw == pair.key }.count
            dict[pair.key] = BaselineStat(avg: pair.value.avg, stdDev: pair.value.stdDev, sampleCount: n)
        }
        AITraceLogger.shared.logPreprocessor(roomName: room.roomName, result: preResult, baselineStats: baselineStats)
        #endif

        // Step 3: AI Call Gate — salta se tutto è nella norma
        guard preResult.shouldCallAI else {
            dprint("🛑 [Gate] \(room.roomName): skip AI — tutto normale")
            return
        }

        // Step 4: costruisce payload con stato pre-valutato (no raw values/thresholds)
        let payload = buildPayload(room: room, readings: readings, baseline: baseline, preResult: preResult)
        let systemPrompt = buildSystemPrompt(roomType: preResult.roomType)

        // Phase 3 trace: payload summary with actionable breakdown
        #if DEBUG
        let anomalousSensors = preResult.sensorStatuses
            .filter { $0.isAnomaly || $0.urgency != "normal" }
            .map { $0.type }
        let actionableSensors = preResult.sensorStatuses
            .filter { $0.actionableAnomaly || $0.urgency != "normal" }
            .map { s -> String in
                let dir = s.anomalyDirection != "none" ? "(\(s.anomalyDirection))" : ""
                return "\(s.type)\(dir)"
            }
        AITraceLogger.shared.logPayload(
            roomName: room.roomName,
            roomType: preResult.roomType.rawValue,
            anomalousSensors: anomalousSensors,
            actionableSensors: actionableSensors
        )
        #endif

        do {
            let service = AIService(settings: aiSettings)
            let response = try await service.sendPrompt(
                systemPrompt: systemPrompt,
                userPrompt: payload
            )
            if let insight = parseInsight(response: response, roomName: room.roomName, preResult: preResult) {
                // Rimuovi eventuale insight precedente per la stessa stanza
                insights.removeAll { $0.roomName == room.roomName }
                insights.append(insight)

                // Phase 7 trace: final insight delivered to UI
                #if DEBUG
                AITraceLogger.shared.logFinalInsight(
                    roomName: insight.roomName,
                    severity: insight.severity.rawValue,
                    message: insight.message,
                    actionsCount: insight.nextActions.count
                )
                #endif
            }
        } catch {
            // Graceful degradation: non mostrare errori all'utente
        }
    }

    // MARK: - Baseline Computation

    /// Calcola la baseline 7 giorni per ogni tipo di sensore della stanza.
    /// Estratto da buildPayload per riutilizzo nel pre-processor.
    /// Richiede almeno 5 letture per tipo per includere il tipo nel risultato.
    private func computeBaseline(
        sensors: [SensorData],
        readings: [SensorReading]
    ) -> [String: (avg: Double, stdDev: Double)] {
        var result: [String: (avg: Double, stdDev: Double)] = [:]
        for sensor in sensors {
            let forType = readings.filter { $0.serviceTypeRaw == sensor.serviceType.rawValue }
            guard forType.count > 5 else { continue }
            let values = forType.map(\.value)
            let avg = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + pow($1 - avg, 2) } / Double(values.count)
            result[sensor.serviceType.rawValue] = (avg: avg, stdDev: sqrt(variance))
        }
        return result
    }

    // MARK: - System Prompt Builder

    private func buildSystemPrompt(roomType: RoomType) -> String {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let month = cal.component(.month, from: now)

        // Fascia oraria
        let timeOfDay: String
        switch hour {
        case 6..<12:  timeOfDay = "mattina (\(hour):00)"
        case 12..<14: timeOfDay = "mezzogiorno (\(hour):00)"
        case 14..<19: timeOfDay = "pomeriggio (\(hour):00)"
        case 19..<23: timeOfDay = "sera (\(hour):00)"
        default:      timeOfDay = "notte (\(hour):00)"
        }

        // Stagione (emisfero nord)
        let season: String
        switch month {
        case 12, 1, 2: season = "inverno"
        case 3, 4, 5:  season = "primavera"
        case 6, 7, 8:  season = "estate"
        default:        season = "autunno"
        }

        // Contesto tipo stanza per il LLM
        let roomTypeContext: String
        switch roomType {
        case .outdoor:
            roomTypeContext = "TIPO STANZA: outdoor (balcone/terrazzo/giardino). " +
                "NON suggerire HVAC, ventilazione o deumidificazione — " +
                "stai già all'aperto. Usa intent coolRoom/heatRoom solo per comfort estremo."
        case .utility:
            roomTypeContext = "TIPO STANZA: utility (garage/lavanderia/cantina)."
        case .transit:
            roomTypeContext = "TIPO STANZA: transit (ingresso/corridoio)."
        case .indoor:
            roomTypeContext = "TIPO STANZA: indoor."
        }

        return """
        Sei un assistente domotico integrato in un'app per la casa. \
        Ora: \(timeOfDay), stagione: \(season). \
        \(roomTypeContext) \
        \
        DATI CHE RICEVI: \
        - `sensorStatus`: stato pre-valutato (urgency + deviazione dalla media in σ). \
        - NON devi valutare soglie — sono già calcolate nel campo `urgency`. \
        - Concentrati su sensori con `isAnomaly: true` che non sono già in urgency warning/danger. \
        - Se tutto è `urgency: normal` e nessun `isAnomaly: true` → hasInsight=false. \
        \
        TONO DEL MESSAGGIO (fondamentale): \
        - Scrivi UNA sola frase breve in italiano colloquiale, massimo 12 parole. \
        - NON usare termini tecnici: niente "baseline", "normalizzare", "trend storico", "rilevato". \
        - NON includere numeri né confronti espliciti (non scrivere "72% invece della media di 65%"). \
        - NON aggiungere spiegazioni dopo la virgola ("...è rimasta su per tutta la sera" → troppo). \
        - NON spiegare l'azione — ci sono già i pulsanti per quello. \
        - Usa SEMPRE il nome della stanza nel messaggio (campo `room` del JSON). \
        - Esempi di tono CORRETTO: \
          "L'umidità in cucina è un po' alta." \
          "Fa ancora un po' caldo in mansarda." \
          "L'aria nel soggiorno è un po' pesante." \
          "La CO₂ in camera è un po' alta." \
          "Sul balcone fa davvero caldo." \
          "L'aria in lavanderia è viziata." \
        - Esempi di tono SBAGLIATO (da evitare): \
          "L'umidità è al 72%, superiore alla media storica del 65%." \
          "Fa un po' caldo in mansarda, la temperatura è rimasta alta tutta la sera." \
          "Suggerirei di attivare la ventilazione per normalizzare." \
          "L'ambiente ha raggiunto valori anomali." \
        \
        ARTICOLI E PREPOSIZIONI con i nomi delle stanze — regola italiana: \
        - Stanze con articolo determinativo femminile: "in cucina", "in camera", "in mansarda", \
          "in lavanderia", "sul balcone", "sul terrazzo", "in bagno". \
        - Stanze con articolo maschile: "nel soggiorno", "nello studio", "nel garage", \
          "nell'ingresso", "nel corridoio". \
        - Se non sei sicuro → usa "nella stanza [nome]" come fallback sicuro. \
        \
        INTENT — indica SOLO il problema ambientale rilevato, senza scegliere dispositivi: \
        Valori possibili (array di stringhe, max 2): \
          "coolRoom"         — temperatura troppo alta \
          "heatRoom"         — temperatura troppo bassa \
          "reduceHumidity"   — umidità troppo alta \
          "increaseHumidity" — umidità troppo bassa / aria troppo secca \
          "improveAirQuality"— qualità aria scarsa, VOC alto \
          "ventilateRoom"    — aria viziata, ricambio necessario \
          "reduceCO2"        — CO₂ (anidride carbonica) alta (>1000 ppm) \
          "respondToSmoke"   — rilevato fumo \
          "respondToCO"      — rilevato monossido di carbonio \
        Usa un array vuoto se nessun intent è applicabile. \
        NON inventare valori diversi da quelli elencati. \
        \
        Rispondi SOLO con JSON valido (nessun testo, nessun markdown):
        {"hasInsight":true,"message":"una frase breve colloquiale","severity":"info"|"warning"|"anomaly",\
        "intents":["coolRoom"]}
        """
    }

    // MARK: - Payload Builder

    /// Costruisce il payload JSON per il LLM con stato pre-valutato (Sprint 4).
    /// Invia `sensorStatus` (urgency+sigma già calcolati) invece di raw values+thresholds.
    private func buildPayload(
        room: RoomEnvironmentData,
        readings: [SensorReading],
        baseline: [String: (avg: Double, stdDev: Double)],
        preResult: PreProcessorResult
    ) -> String {
        let now = Date()

        // Suddividi le letture nelle ultime 12 ore in fasce da 4h
        let periodRanges: [(String, TimeInterval, TimeInterval)] = [
            ("00:00-04:00", -12 * 3600, -8 * 3600),
            ("04:00-08:00", -8  * 3600, -4 * 3600),
            ("08:00-12:00", -4  * 3600,  0),
        ]

        var periods: [[String: Any]] = []
        for (label, startOffset, endOffset) in periodRanges {
            let start = now.addingTimeInterval(startOffset)
            let end   = now.addingTimeInterval(endOffset)
            let slice = readings.filter { $0.timestamp >= start && $0.timestamp <= end }
            guard !slice.isEmpty else { continue }

            var periodData: [String: Any] = ["range": label]
            for sensor in room.sensors {
                let typeReadings = slice.filter { $0.serviceTypeRaw == sensor.serviceType.rawValue }
                guard !typeReadings.isEmpty else { continue }
                let values = typeReadings.map(\.value)
                let avg = values.reduce(0, +) / Double(values.count)
                let max = values.max() ?? avg
                let key = sensor.serviceType.rawValue
                periodData["avg\(key.capitalized)"] = Double(round(avg * 10) / 10)
                periodData["max\(key.capitalized)"] = Double(round(max * 10) / 10)
            }
            periods.append(periodData)
        }

        // Baseline 7 giorni (formattata per JSON)
        var baselineJSON: [String: Any] = [:]
        for (typeRaw, stats) in baseline {
            baselineJSON["avg\(typeRaw.capitalized)"]    = Double(round(stats.avg    * 10) / 10)
            baselineJSON["stdDev\(typeRaw.capitalized)"] = Double(round(stats.stdDev * 10) / 10)
        }

        // Sensor status come array Codable
        let sensorStatusArray: [[String: Any]] = preResult.sensorStatuses.map { entry in
            var dict: [String: Any] = [
                "type":    entry.type,
                "value":   entry.value,
                "urgency": entry.urgency,
                "isAnomaly": entry.isAnomaly,
            ]
            if let sigma = entry.deviationSigma {
                dict["deviationSigma"] = sigma
            }
            return dict
        }

        // Ora locale
        let cal = Calendar.current
        let nowHour = cal.component(.hour, from: now)
        let nowMin  = cal.component(.minute, from: now)
        let localTime = String(format: "%02d:%02d", nowHour, nowMin)

        let payloadDict: [String: Any] = [
            "room":         room.roomName,
            "roomType":     preResult.roomType.rawValue,
            "localTime":    localTime,
            "sensorStatus": sensorStatusArray,
            "periods":      periods,
            "baseline7d":   baselineJSON,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"room\": \"\(room.roomName)\"}" }

        return str
    }

    // MARK: - Response Parser

    /// Parses the LLM JSON response.
    /// Applica severity clamping e intent filtering deterministici (Sprint 4).
    private func parseInsight(
        response: String,
        roomName: String,
        preResult: PreProcessorResult
    ) -> AmbientalAIInsight? {
        let cleaned = extractJSON(from: response)

        // Parse JSON once so we can trace both success and failure paths
        let parsedJSON = cleaned.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        guard let json = parsedJSON,
              let hasInsight = json["hasInsight"] as? Bool,
              hasInsight,
              let message = json["message"] as? String,
              !message.isEmpty,
              let severityRaw = json["severity"] as? String,
              let llmSeverity = InsightSeverity(rawValue: severityRaw)
        else {
            // Phase 4 trace: AI returned no insight (parse failure or hasInsight=false)
            #if DEBUG
            AITraceLogger.shared.logAIResponse(
                roomName: roomName,
                hasInsight: (parsedJSON?["hasInsight"] as? Bool) ?? false,
                message: parsedJSON?["message"] as? String,
                severity: parsedJSON?["severity"] as? String,
                intents: parsedJSON?["intents"] as? [String] ?? []
            )
            #endif
            return nil
        }

        let intentStrings = json["intents"] as? [String] ?? []

        // Phase 4 trace: AI response parsed successfully
        #if DEBUG
        AITraceLogger.shared.logAIResponse(
            roomName: roomName,
            hasInsight: true,
            message: message,
            severity: severityRaw,
            intents: intentStrings
        )
        #endif

        // Clamp severity al ceiling deterministico
        let clampedSeverity = EnvironmentPreProcessor.clampSeverity(
            llmSeverity, ceiling: preResult.severityCeiling
        )

        // Parse intent strings dal LLM
        let rawIntents = intentStrings.compactMap { ActionIntent(rawValue: $0) }

        // Filtra intent per tipo di stanza
        let filteredIntents = EnvironmentPreProcessor.filterIntents(rawIntents, for: preResult.roomType)

        // Phase 5 trace: validator (severity clamping + intent filtering)
        #if DEBUG
        AITraceLogger.shared.logValidator(
            roomName: roomName,
            llmSeverity: severityRaw,
            clampedSeverity: clampedSeverity.rawValue,
            rawIntents: intentStrings,
            filteredIntents: filteredIntents.map(\.rawValue)
        )
        #endif

        // Delegare la selezione dispositivi al resolver deterministico
        let nextActions = filteredIntents.isEmpty
            ? []
            : resolver.resolve(intents: filteredIntents, roomName: roomName, roomType: preResult.roomType)

        return AmbientalAIInsight(
            roomName: roomName,
            message: message,
            severity: clampedSeverity,
            nextActions: nextActions,
            resolvedIntents: filteredIntents.map(\.rawValue)
        )
    }

    private func extractJSON(from string: String) -> String {
        guard let start = string.firstIndex(of: "{"),
              let end = string.lastIndex(of: "}")
        else { return string }
        return String(string[start...end])
    }

    // MARK: - Data Loading

    private func loadHistory(for room: RoomEnvironmentData) -> [SensorReading] {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let roomName = room.roomName

        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.roomName == roomName && $0.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
