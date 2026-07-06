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
    private(set) var lastAnalysisError: String?
    private(set) var lastAnalysisFailedAt: Date?

    /// Current presence state injected from LocationPresenceService when geofencing is active.
    /// Falls back to ContextResolver heuristics inside buildPayload when nil.
    var presenceOverride: PresenceState? = nil

    /// Current outdoor weather snapshot, injected by HomeFloorplanApp from WeatherKitService.
    /// When non-nil, the indoor temperature baseline is adjusted and weather context is added
    /// to the LLM payload and system prompt.
    var currentWeather: WeatherSnapshot? = nil

    // MARK: - Private

    private let aiSettings: AISettings
    private let aiService: AIService
    private let modelContainer: ModelContainer
    private let context: ModelContext
    private let homeKit: HomeKitService
    private let resolver: ActionResolver
    private let baselineProvider = BaselineProvider()
    let effectivenessTracker: ActionEffectivenessTracker
    /// Intervallo minimo tra analisi per la stessa stanza (15 min).
    private var lastAnalysisByRoom: [String: Date] = [:]
    private let minInterval: TimeInterval = 15 * 60
    /// Rate-limiter for event-driven immediate analysis requests (5 min per room).
    private var lastImmediateByRoom: [String: Date] = [:]
    private let immediateAnalysisInterval: TimeInterval = 5 * 60
    /// True after the first restoreFromStorage() call — prevents re-loading on every analyzeRooms.
    private var isRestored = false

    /// Nome stanza outdoor impostato dall'utente (AppStorage "outdoorRoomName").
    private var outdoorRoomName: String {
        UserDefaults.standard.string(forKey: "outdoorRoomName") ?? ""
    }

    // MARK: - Init

    /// - Parameters:
    ///   - tracker: Tracker condiviso. Se nil, ne viene creato uno autonomo
    ///     (backward-compatible per le istanze locali nelle view come EnvironmentContextDashboard).
    ///   - aiService: AIService condiviso. Se nil, ne viene creato uno dall'aiSettings (backward-compatible).
    init(
        aiSettings: AISettings,
        modelContainer: ModelContainer,
        homeKit: HomeKitService,
        tracker: ActionEffectivenessTracker? = nil,
        aiService: AIService? = nil
    ) {
        self.aiSettings = aiSettings
        self.aiService  = aiService ?? AIService(settings: aiSettings)
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
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
        if !isRestored { restoreFromStorage() }
        guard aiSettings.isOperational, aiSettings.anomalyDetectionEnabled else { return }

        normalizeVisibleInsightSeverities(rooms: rooms)

        // Re-resolve stale insights on every cycle so accessory state changes
        // (e.g. blind opened between analysis cycles) are reflected immediately.
        reResolveStaleInsights()

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
            updatePersistedStatus(for: insight.id, to: .expired)
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

    /// Dismette un insight specifico e registra il dismissal con il motivo per il tracking.
    func dismiss(_ insight: AmbientalAIInsight, reason: DismissalReason = .unclear) {
        updatePersistedStatus(for: insight.id, to: .dismissed)
        if let idx = insights.firstIndex(where: { $0.id == insight.id }) {
            insights[idx].isDismissed = true
            effectivenessTracker.trackDismissal(
                intents: insight.resolvedIntents,
                roomName: insight.roomName,
                severityRaw: insight.severity.rawValue,
                suggestedAt: insight.generatedAt,
                reason: reason
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

    /// Clears all per-room analysis gates, forcing the next analyzeRooms call to re-analyse
    /// every room regardless of when it was last analysed. Use before a manual refresh.
    func clearAnalysisGates() {
        lastAnalysisByRoom.removeAll()
    }

    /// Called by SensorEventRouter on high-priority sensor events.
    /// Resets the 15-min gate for `roomName` so the next analyzeRooms call includes it immediately.
    /// Rate-limited to once every 5 minutes per room to prevent alert storms.
    func requestImmediateAnalysis(for roomName: String) {
        let now = Date()
        if let last = lastImmediateByRoom[roomName],
           now.timeIntervalSince(last) < immediateAnalysisInterval { return }
        lastImmediateByRoom[roomName] = now
        lastAnalysisByRoom.removeValue(forKey: roomName)
    }

    // MARK: - Room Analysis

    private func analyzeRoom(_ room: RoomEnvironmentData, readings: [SensorReading]) async {
        // Step 1: baseline from DailySensorSummary (14-day window, seasonal fallback for new users)
        let serviceTypes = room.sensors.map { $0.serviceType.rawValue }
        let baselineResult = baselineProvider.baseline(for: room.roomName, serviceTypes: serviceTypes, context: context)
        let baseline = baselineResult.byType

        // Step 1.5 (Sprint 31): shift indoor temperature baseline when outdoor temp deviates
        // from its seasonal norm, reducing false anomalies on unusually hot or cold days.
        let effectiveBaseline: [String: (avg: Double, stdDev: Double)]
        if let weather = currentWeather {
            effectiveBaseline = WeatherContextProvider.applyWeatherCorrection(
                to: baseline,
                outdoorTemp: weather.outdoorTemperature,
                season: CalendarSeason.current
            )
        } else {
            effectiveBaseline = baseline
        }

        // Phase 1 trace: raw sensor snapshot
        #if DEBUG
        AITraceLogger.shared.logRawSnapshot(
            roomName: room.roomName,
            sensors: room.sensors.map { (type: $0.serviceType.rawValue, value: $0.currentValue) }
        )
        #endif

        // Step 2: pre-processing deterministico
        let nameMap = buildAccessoryNameMap()
        let preResult = EnvironmentPreProcessor.preProcess(
            room: room,
            baselineByType: effectiveBaseline,
            outdoorRoomName: outdoorRoomName,
            accessoryNameMap: nameMap
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
            autoDismissNormalizedInsights(for: room.roomName)
            return
        }

        // Step 3.5: Semantic fingerprint deduplication
        let fingerprint = computeSemanticFingerprint(preResult: preResult)
        let existingState = fetchRoomState(roomName: room.roomName, context: context)

        if let state = existingState, state.semanticFingerprint == fingerprint {
            // Exception: previous LLM result was empty (hasInsight:false / intents:[]) for a
            // danger-level state. The prompt may have changed or the model may now respond —
            // force a retry instead of permanently suppressing the insight.
            let prevWasEmpty = state.lastIntentSet.isEmpty && state.lastSeverityRaw == "none"
            let hasDanger = preResult.sensorStatuses.contains { $0.urgency == "danger" }
            if prevWasEmpty && hasDanger {
                dprint("🔄 [Fingerprint] \(room.roomName): danger-state retry (prev=empty, curr=danger)")
            } else {
                dprint("⏭️ [Fingerprint] \(room.roomName): SKIP — semantic state unchanged")
                dprint("   fingerprint=\(fingerprint)")
                return
            }
        }
        #if DEBUG
        if let state = existingState {
            dprint("🆕 [Fingerprint] \(room.roomName): state changed")
            dprint("   prev=\(state.semanticFingerprint)")
            dprint("   curr=\(fingerprint)")
        } else {
            dprint("🆕 [Fingerprint] \(room.roomName): first analysis (fp=\(fingerprint))")
        }
        #endif

        // Step 4: costruisce payload con stato pre-valutato (no raw values/thresholds)
        let payload = buildPayload(room: room, readings: readings, baseline: effectiveBaseline, preResult: preResult)
        let weatherNote = currentWeather.map { WeatherContextProvider.systemPromptNote(snapshot: $0) }
        let systemPrompt = buildSystemPrompt(roomType: preResult.roomType, baselineLevel: baselineResult.level, weatherNote: weatherNote)

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
            let response = try await aiService.sendPrompt(
                systemPrompt: systemPrompt,
                userPrompt: payload
            )
            lastAnalysisError = nil
            lastAnalysisFailedAt = nil
            if let insight = parseInsight(response: response, roomName: room.roomName, preResult: preResult) {
                let sortedIntents = insight.resolvedIntents.sorted()

                // Task 4: intent deduplication — same intents + same severity means the situation
                // hasn't changed from the user's perspective; suppress UI churn.
                let intentsDuplicated = existingState.map {
                    $0.lastIntentSet.sorted() == sortedIntents &&
                    $0.lastSeverityRaw == insight.severity.rawValue
                } ?? false

                if intentsDuplicated {
                    // Fingerprint changed (e.g. numeric oscillation around a threshold),
                    // but the AI conclusion is identical → update state fingerprint only.
                    if let state = existingState {
                        state.semanticFingerprint = fingerprint
                        state.lastAnalysisDate    = Date()
                        try? context.save()
                    }
                    dprint("⏭️ [IntentDedup] \(room.roomName): same intents \(sortedIntents) — suppressing insight update")
                } else {
                    // New intents or severity change → full update
                    insights.removeAll { $0.roomName == room.roomName }
                    insights.append(insight)
                    persistInsight(insight)
                    upsertRoomState(
                        roomName:      insight.roomName,
                        fingerprint:   fingerprint,
                        sortedIntents: sortedIntents,
                        severityRaw:   insight.severity.rawValue,
                        insightID:     insight.id,
                        context:       context,
                        existing:      existingState
                    )

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
            } else {
                // LLM returned no insight — record the fingerprint so this exact state
                // is not re-analysed until the environment changes again.
                upsertRoomState(
                    roomName:      room.roomName,
                    fingerprint:   fingerprint,
                    sortedIntents: [],
                    severityRaw:   "none",
                    insightID:     nil,
                    context:       context,
                    existing:      existingState
                )
                dprint("⏭️ [Fingerprint] \(room.roomName): LLM returned no insight — fingerprint recorded")
            }
        } catch {
            // Graceful degradation: non mostrare errori all'utente
            lastAnalysisError = error.localizedDescription
            lastAnalysisFailedAt = Date()
            #if DEBUG
            dprint("⚠️ [EnvironmentAI] \(room.roomName): \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - System Prompt Builder

    private func buildSystemPrompt(roomType: RoomType, baselineLevel: BaselineLevel = .personal, weatherNote: String? = nil) -> String {
        let cal = Calendar.current
        let now = Date()
        let hour  = cal.component(.hour,  from: now)
        let month = cal.component(.month, from: now)
        let lang  = AILocale.outputLanguage

        // Neutral English time slot label (prompt language is English)
        let timeSlot: String
        switch hour {
        case 6..<12:  timeSlot = "morning (\(hour):00)"
        case 12..<14: timeSlot = "midday (\(hour):00)"
        case 14..<19: timeSlot = "afternoon (\(hour):00)"
        case 19..<23: timeSlot = "evening (\(hour):00)"
        default:      timeSlot = "night (\(hour):00)"
        }

        // Neutral English season
        let season: String
        switch month {
        case 12, 1, 2: season = "winter"
        case 3, 4, 5:  season = "spring"
        case 6, 7, 8:  season = "summer"
        default:        season = "autumn"
        }

        // Room type context
        let roomContext: String
        switch roomType {
        case .outdoor:
            roomContext = "outdoor (balcony/terrace/garden) — do NOT suggest HVAC, ventilation, or dehumidification. " +
                          "If temperature urgency is 'danger' or σ ≥ 2.0 high, use coolRoom (e.g. suggest closing awnings or seeking shade). " +
                          "Do not use heatRoom or ventilateRoom."
        case .utility:
            roomContext = "utility (garage/laundry/basement)"
        case .transit:
            roomContext = "transit (entrance/corridor)"
        case .indoor:
            roomContext = "indoor"
        }

        let baselineNote: String
        switch baselineLevel {
        case .personal:  baselineNote = "deviation (σ) from 14-day personal baseline"
        case .seasonal:  baselineNote = "deviation (σ) from seasonal typical values (personal data < 5 days)"
        case .none:      baselineNote = "no baseline — treat deviationSigma as absent"
        }

        let weatherLine = weatherNote.map { "\n        \($0)" } ?? ""

        return """
        You are a smart home AI assistant. RESPOND IN \(lang.uppercased()).
        Context: \(timeSlot), season: \(season), room type: \(roomContext).\(weatherLine)

        INPUT DATA:
        - `sensorStatus`: pre-evaluated array — urgency (normal/warning/danger) + \(baselineNote).
        - `presence`: "people_home" | "sleeping" | "home_empty" — current occupancy context.
        - Do NOT evaluate thresholds — pre-computed in `urgency`.
        - Focus on sensors with `isAnomaly: true`, `actionableAnomaly: true`, or `urgency` ≠ `normal`.
        - If all urgency:normal and no anomalies → respond with hasInsight:false.
        - Use `presence` for semantic reasoning: home_empty findings differ from people_home ones.

        DATA QUALITY:
        - If a sensor entry has `isStale: true`, its value may be unreliable — do not draw environmental conclusions from it alone.
        - You may generate a generic data quality observation (e.g. "sensor data in this room may be outdated") but never reference physical devices, accessory names, manufacturers, or hardware identifiers.
        - The payload contains no device identity — do not speculate about hardware.

        SEMANTIC REASONING — go beyond describing sensor values:
        - OBSERVE patterns: correlate sensor state with time, season, or usage context.
        - EXPLAIN context: infer probable cause (shower, cooking, occupancy, solar exposure, closed windows).
        - PREDICT: when trend is clear, state what is expected to happen.
        - Use probabilistic language ("tends to", "usually", "likely") — never deterministic statements.

        MESSAGE QUALITY:
        - One concise sentence in \(lang), max 14 words.
        - Colloquial tone — no technical jargon ("baseline", "deviation", "anomaly detected", "normalize").
        - Always include the room name (from the `room` field in the input JSON).
        - GOOD: "Kitchen humidity has been lingering after cooking."
        - GOOD: "Studio tends to overheat during afternoon sun."
        - GOOD: "Living room CO₂ usually rises during evening occupancy."
        - BAD: "Humidity at 72%, above historical average of 65%."
        - BAD: "An environmental anomaly has been detected."

        INTELLIGENCE LEVEL — classify your observation as one of:
        - "observation": current environment state worth noticing
        - "pattern": repeated behavior inferred from context and time
        - "prediction": expected future state based on observable trend
        - "recommendation": a direct action suggestion

        PATTERN KEY — stable English snake_case identifier for deduplication (null if one-off):
        - Examples: "bathroom_post_shower_humidity", "studio_solar_overheating", "living_co2_evening_occupancy"

        WHY EXPLANATION — one brief sentence in \(lang) explaining your reasoning (max 12 words):
        - Mention the data signal: time of day, deviation direction, trend.
        - Example: "Humidity above normal at this hour with a rising trend."

        INTENTS — environmental problem only, max 2 values from:
        coolRoom | heatRoom | reduceHumidity | increaseHumidity | improveAirQuality | ventilateRoom | reduceCO2 | respondToSmoke | respondToCO
        Use empty array if no intent is applicable.

        Respond ONLY with valid JSON (no text, no markdown):
        {"hasInsight":true,"message":"...","severity":"info"|"warning"|"anomaly","intents":["coolRoom"],"intelligenceLevel":"observation"|"pattern"|"prediction"|"recommendation","patternKey":"snake_case_key_or_null","whyExplanation":"..."}
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

        // Sensor status array — semantic fields only. No hardware identity reaches the LLM (Sprint 16B).
        // accessoryID, accessoryName, staleMinutes are retained in SensorStatusEntry for the
        // deterministic attribution pipeline (parseInsight → sourceAccessoryID/Name) but are
        // intentionally excluded from the AI payload to preserve hardware-agnosticism.
        let sensorStatusArray: [[String: Any]] = preResult.sensorStatuses.map { entry in
            var dict: [String: Any] = [
                "type":             entry.type,
                "value":            entry.value,
                "urgency":          entry.urgency,
                "isAnomaly":        entry.isAnomaly,
                "actionableAnomaly": entry.actionableAnomaly,
                "anomalyDirection": entry.anomalyDirection,
                "isStale":          entry.isStale,
            ]
            if let sigma = entry.deviationSigma { dict["deviationSigma"] = sigma }
            return dict
        }

        // Ora locale
        let cal = Calendar.current
        let nowHour = cal.component(.hour, from: now)
        let nowMin  = cal.component(.minute, from: now)
        let localTime = String(format: "%02d:%02d", nowHour, nowMin)

        // Presence context: geofence override → ContextResolver heuristics fallback
        let resolvedPresence = presenceOverride ?? ContextResolver.resolve().presenceState
        let presenceLabel: String
        switch resolvedPresence {
        case .home:              presenceLabel = "people_home"
        case .sleeping:          presenceLabel = "sleeping"
        case .away, .vacation:   presenceLabel = "home_empty"
        }

        var payloadDict: [String: Any] = [
            "room":         room.roomName,
            "roomType":     preResult.roomType.rawValue,
            "localTime":    localTime,
            "presence":     presenceLabel,
            "sensorStatus": sensorStatusArray,
            "periods":      periods,
            "baseline7d":   baselineJSON,
        ]
        // Sprint 31: inject outdoor weather when available
        if let weather = currentWeather {
            payloadDict["outdoor"] = WeatherContextProvider.payloadDict(snapshot: weather)
        }

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

        // Clamp severity within deterministic bounds: the model cannot overstate or understate
        // the severity implied by current sensor urgency.
        let clampedSeverity = EnvironmentPreProcessor.clampSeverity(
            llmSeverity,
            ceiling: preResult.severityCeiling,
            floor: EnvironmentPreProcessor.severityFloor(for: preResult.sensorStatuses)
        )

        // Parse intent strings dal LLM e integra intent deterministici quando il dato
        // rende l'azione evidente anche se il modello risponde in modo generico.
        let rawIntents = augmentedIntents(
            intentStrings.compactMap { ActionIntent(rawValue: $0) },
            preResult: preResult
        )

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

        let intelligenceLevelRaw = json["intelligenceLevel"] as? String
        let level = intelligenceLevelRaw.flatMap { IntelligenceLevel(rawValue: $0) } ?? .observation
        let patternKey = json["patternKey"] as? String
        let whyExplanation = json["whyExplanation"] as? String
        // 24.B: confidence computed deterministically — not requested from LLM
        let confidence = computeConfidence(preResult: preResult)

        // 24.E: language quality flag — Italian insights should contain at least one non-ASCII char
        let suspect = languageSuspect(message: message)
        #if DEBUG
        if suspect {
            dprint("⚠️ [AI] Language suspect in \(roomName): message appears to be in English instead of Italian")
        }
        #endif

        // Source accessory attribution: pick the most anomalous sensor that has device identity (Sprint 16A)
        let urgencyOrder = ["normal": 0, "warning": 1, "danger": 2]
        let sourceEntry = preResult.sensorStatuses
            .filter { $0.accessoryID != nil }
            .max {
                let ls = (urgencyOrder[$0.urgency] ?? 0) * 4 + ($0.actionableAnomaly ? 2 : 0) + ($0.isAnomaly ? 1 : 0)
                let rs = (urgencyOrder[$1.urgency] ?? 0) * 4 + ($1.actionableAnomaly ? 2 : 0) + ($1.isAnomaly ? 1 : 0)
                return ls < rs
            }

        return AmbientalAIInsight(
            roomName: roomName,
            message: message,
            severity: clampedSeverity,
            intelligenceLevel: level,
            patternKey: patternKey,
            whyExplanation: whyExplanation,
            confidence: confidence,
            nextActions: nextActions,
            resolvedIntents: filteredIntents.map(\.rawValue),
            sourceAccessoryID: sourceEntry?.accessoryID,
            sourceAccessoryName: sourceEntry?.accessoryName,
            sourceServiceType: sourceEntry?.type,
            promptVersion: AIPromptVersion.currentEnvironmental,
            isLanguageSuspect: suspect
        )
    }

    private func augmentedIntents(
        _ intents: [ActionIntent],
        preResult: PreProcessorResult
    ) -> [ActionIntent] {
        var result = intents

        let hasOutdoorHeatIssue = preResult.roomType == .outdoor &&
            preResult.sensorStatuses.contains { status in
                status.type == SensorServiceType.temperature.rawValue &&
                !status.isStale &&
                (
                    status.urgency == "danger" ||
                    (status.actionableAnomaly && status.anomalyDirection == "high") ||
                    ((status.deviationSigma ?? 0) >= 2.0 && status.anomalyDirection == "high")
                )
            }

        if hasOutdoorHeatIssue && !result.contains(.coolRoom) {
            result.insert(.coolRoom, at: 0)
        }

        return result
    }

    // MARK: - Confidence Computation (24.B)

    /// Computes insight confidence deterministically from pre-processor signals.
    /// Replaces the LLM-generated confidence field (Sprint 24.B).
    private func computeConfidence(preResult: PreProcessorResult) -> Double {
        let statuses = preResult.sensorStatuses
        guard !statuses.isEmpty else { return 0.5 }

        // Signal intensity: max |deviationSigma| normalised to 3σ (0.40 weight)
        let maxSigma = statuses.compactMap(\.deviationSigma).map(abs).max() ?? 0
        let signalScore = min(maxSigma / 3.0, 1.0) * 0.40

        // Data reliability: fraction of sensors with valid personal baseline (0.30 weight)
        let withBaseline = Double(statuses.filter { $0.deviationSigma != nil }.count)
        let sampleScore  = (withBaseline / Double(statuses.count)) * 0.30

        // Urgency level (0.30 weight)
        let urgencyMap: [String: Double] = ["normal": 0.0, "warning": 0.5, "danger": 1.0]
        let maxUrgency = statuses.compactMap { urgencyMap[$0.urgency] }.max() ?? 0
        let urgencyScore = maxUrgency * 0.30

        return min(1.0, signalScore + sampleScore + urgencyScore)
    }

    // MARK: - Language Validation (24.E)

    /// Returns true when the Italian device locale is expected but the message contains
    /// only ASCII characters — a heuristic signal that the LLM responded in English.
    private func languageSuspect(message: String) -> Bool {
        guard AILocale.outputLanguage == "Italian", !message.isEmpty else { return false }
        return message.unicodeScalars.allSatisfy { $0.value < 128 }
    }

    private func extractJSON(from string: String) -> String {
        guard let start = string.firstIndex(of: "{"),
              let end = string.lastIndex(of: "}"),
              start <= end
        else { return string }
        return String(string[start...end])
    }

    // MARK: - Persistence

    /// Loads active non-expired insights from SwiftData into the in-memory array.
    /// Called once per service session before the first analysis run.
    /// Also triggers a 30-day cleanup of old records.
    private func restoreFromStorage() {
        isRestored = true
        pruneOldInsights()
        let now = Date()
        let statusActive = HomeInsightStatus.active.rawValue
        let environmentCategory = HomeInsightCategory.environment.rawValue
        let legacySourceType = String(describing: PersistedInsight.self)
        let ambientalSourceType = String(describing: AmbientalAIInsight.self)
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.statusRaw == statusActive && $0.categoryRaw == environmentCategory
            }
        )
        let records = ((try? context.fetch(descriptor)) ?? [])
            .filter {
                ($0.sourceRecordType == ambientalSourceType || $0.sourceRecordType == legacySourceType) &&
                $0.createdAt.addingTimeInterval(2 * 3600) > now
            }
        insights = records.compactMap { record -> AmbientalAIInsight? in
            guard let insight = ambientInsight(from: record) else { return nil }
            // Fast path: re-resolve in-memory (works when HomeKit is already loaded)
            let updated = reResolveIfAllTips(insight, record: record)
            // Slow path fallback: if HomeKit wasn't loaded yet, bust the fingerprint so the
            // current analyzeRooms() cycle forces a fresh AI + resolver pass for this room.
            let stillOnlyTips = !updated.nextActions.isEmpty && updated.nextActions.allSatisfy { $0.isTip }
            if stillOnlyTips { invalidateFingerprint(for: insight.roomName) }
            return updated
        }
        if insights.isEmpty {
            restoreLegacyInsightsFromStorage(now: now)
            return
        }
        dprint("🔄 [Persistence] Restored \(insights.count) active insight(s) from unified storage")
    }

    private func restoreLegacyInsightsFromStorage(now: Date) {
        let statusActive = InsightPersistedStatus.active.rawValue
        let descriptor = FetchDescriptor<PersistedInsight>(
            predicate: #Predicate { $0.statusRaw == statusActive && $0.expiresAt > now }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        insights = records.compactMap { record -> AmbientalAIInsight? in
            guard let insight = record.toAmbientalAIInsight() else { return nil }
            let updated = reResolveIfAllTips(insight, record: record)
            let stillOnlyTips = !updated.nextActions.isEmpty && updated.nextActions.allSatisfy { $0.isTip }
            if stillOnlyTips { invalidateFingerprint(for: insight.roomName) }
            return updated
        }
        dprint("🔄 [Persistence] Restored \(insights.count) active legacy insight(s) from storage")
    }

    private func ambientInsight(from record: PersistedHomeInsight) -> AmbientalAIInsight? {
        guard let roomName = record.roomName else { return nil }
        let actions = record.suggestedActionJSON?
            .data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([AINextAction].self, from: $0) } ?? []

        return AmbientalAIInsight(
            id: record.id,
            roomName: roomName,
            message: record.message,
            severity: ambientSeverity(from: record.severityRaw),
            intelligenceLevel: ambientIntelligenceLevel(from: record.kindRaw),
            patternKey: record.dedupeKey,
            whyExplanation: record.whyExplanation,
            confidence: record.confidence,
            generatedAt: record.createdAt,
            isDismissed: record.statusRaw == HomeInsightStatus.dismissed.rawValue,
            nextActions: actions,
            resolvedIntents: [],
            sourceAccessoryID: record.sourceEntityID,
            sourceAccessoryName: record.sourceEntityName,
            sourceServiceType: nil,
            promptVersion: AIPromptVersion.currentEnvironmental
        )
    }

    private func ambientSeverity(from rawValue: String) -> InsightSeverity {
        switch HomeInsightSeverity(rawValue: rawValue) {
        case .critical, .high:
            return .anomaly
        case .medium:
            return .warning
        case .low, .info, nil:
            return .info
        }
    }

    private func ambientIntelligenceLevel(from rawValue: String) -> IntelligenceLevel {
        switch HomeInsightKind(rawValue: rawValue) {
        case .prediction:
            return .prediction
        case .recommendation, .opportunity:
            return .recommendation
        case .environment:
            return .observation
        case .anomaly:
            return .pattern
        case .incoherence, .security, .habit, .maintenance, .deviceHealth, nil:
            return .observation
        }
    }

    /// Re-runs the resolver for an insight whose every action is a tip.
    /// Uses ActionIntentInferrer as fallback when resolvedIntents is empty (old records).
    /// Returns the original insight unchanged when no real accessory is found.
    private func reResolveIfAllTips(_ insight: AmbientalAIInsight, record: PersistedHomeInsight) -> AmbientalAIInsight {
        guard !insight.nextActions.isEmpty, insight.nextActions.allSatisfy({ $0.isTip }) else { return insight }

        var intents = insight.resolvedIntents.compactMap { ActionIntent(rawValue: $0) }
        if intents.isEmpty { intents = ActionIntentInferrer.infer(from: insight) }
        guard !intents.isEmpty else { return insight }

        let roomType = RoomClassifier.classify(roomName: insight.roomName, outdoorRoomName: outdoorRoomName)
        let freshActions = resolver.resolve(intents: intents, roomName: insight.roomName, roomType: roomType)
        guard freshActions.contains(where: { !$0.isTip }) else { return insight }

        let updated = AmbientalAIInsight(
            id: insight.id,
            roomName: insight.roomName,
            message: insight.message,
            severity: insight.severity,
            intelligenceLevel: insight.intelligenceLevel,
            patternKey: insight.patternKey,
            whyExplanation: insight.whyExplanation,
            confidence: insight.confidence,
            generatedAt: insight.generatedAt,
            isDismissed: insight.isDismissed,
            nextActions: freshActions,
            resolvedIntents: insight.resolvedIntents,
            sourceAccessoryID: insight.sourceAccessoryID,
            sourceAccessoryName: insight.sourceAccessoryName,
            sourceServiceType: insight.sourceServiceType
        )
        if let data = try? JSONEncoder().encode(freshActions),
           let json = String(data: data, encoding: .utf8) {
            record.suggestedActionJSON = json
            record.updatedAt = Date()
            try? context.save()
        }
        dprint("🔁 [Restore] \(insight.roomName): upgraded unified tip-only → \(freshActions.count) action(s)")
        return updated
    }

    private func reResolveIfAllTips(_ insight: AmbientalAIInsight, record: PersistedInsight) -> AmbientalAIInsight {
        guard !insight.nextActions.isEmpty, insight.nextActions.allSatisfy({ $0.isTip }) else { return insight }

        var intents = insight.resolvedIntents.compactMap { ActionIntent(rawValue: $0) }
        if intents.isEmpty { intents = ActionIntentInferrer.infer(from: insight) }
        guard !intents.isEmpty else { return insight }

        let roomType = RoomClassifier.classify(roomName: insight.roomName, outdoorRoomName: outdoorRoomName)
        let freshActions = resolver.resolve(intents: intents, roomName: insight.roomName, roomType: roomType)
        guard freshActions.contains(where: { !$0.isTip }) else { return insight }

        let updated = AmbientalAIInsight(
            id: insight.id,
            roomName: insight.roomName,
            message: insight.message,
            severity: insight.severity,
            intelligenceLevel: insight.intelligenceLevel,
            patternKey: insight.patternKey,
            whyExplanation: insight.whyExplanation,
            confidence: insight.confidence,
            generatedAt: insight.generatedAt,
            isDismissed: insight.isDismissed,
            nextActions: freshActions,
            resolvedIntents: insight.resolvedIntents,
            sourceAccessoryID: insight.sourceAccessoryID,
            sourceAccessoryName: insight.sourceAccessoryName,
            sourceServiceType: insight.sourceServiceType
        )
        if let data = try? JSONEncoder().encode(freshActions),
           let json = String(data: data, encoding: .utf8) {
            record.nextActionsJSON = json
            upsertPersistedHomeInsight(from: record)
            try? context.save()
        }
        dprint("🔁 [Restore] \(insight.roomName): upgraded tip-only → \(freshActions.count) action(s)")
        return updated
    }

    /// Re-resolves every visible insight that has no actionable suggests (empty or tip-only).
    /// Called on every analyzeRooms() cycle so accessory state changes between cycles
    /// (e.g. blind opened) are reflected without waiting for a full AI re-run.
    ///
    /// - If re-resolve finds real accessories: updates insight in-memory + SwiftData, no AI call.
    /// - If re-resolve still finds nothing: invalidates the semantic fingerprint so the
    ///   per-room analysis in the current cycle will call the AI fresh.
    private func reResolveStaleInsights() {
        let staleIndices = insights.indices.filter { i in
            let a = insights[i].nextActions
            return a.isEmpty || a.allSatisfy { $0.isTip }
        }
        guard !staleIndices.isEmpty else { return }

        for i in staleIndices {
            let insight = insights[i]
            var intents = insight.resolvedIntents.compactMap { ActionIntent(rawValue: $0) }
            if intents.isEmpty { intents = ActionIntentInferrer.infer(from: insight) }
            guard !intents.isEmpty else { continue }

            let roomType = RoomClassifier.classify(roomName: insight.roomName, outdoorRoomName: outdoorRoomName)
            let freshActions = resolver.resolve(intents: intents, roomName: insight.roomName, roomType: roomType)

            if freshActions.contains(where: { !$0.isTip }) {
                // Found real accessories — upgrade in-memory insight
                insights[i] = AmbientalAIInsight(
                    id: insight.id,
                    roomName: insight.roomName,
                    message: insight.message,
                    severity: insight.severity,
                    intelligenceLevel: insight.intelligenceLevel,
                    patternKey: insight.patternKey,
                    whyExplanation: insight.whyExplanation,
                    confidence: insight.confidence,
                    generatedAt: insight.generatedAt,
                    isDismissed: insight.isDismissed,
                    nextActions: freshActions,
                    resolvedIntents: insight.resolvedIntents,
                    sourceAccessoryID: insight.sourceAccessoryID,
                    sourceAccessoryName: insight.sourceAccessoryName,
                    sourceServiceType: insight.sourceServiceType
                )
                // Persist updated actions
                let insightID = insight.id
                let descriptor = FetchDescriptor<PersistedInsight>(
                    predicate: #Predicate { $0.id == insightID }
                )
                if let record = (try? context.fetch(descriptor))?.first,
                   let data = try? JSONEncoder().encode(freshActions),
                   let json = String(data: data, encoding: .utf8) {
                    record.nextActionsJSON = json
                    upsertPersistedHomeInsight(from: record)
                    try? context.save()
                }
                dprint("🔁 [ReResolve] \(insight.roomName): stale insight upgraded to \(freshActions.count) action(s)")
            } else {
                // Still nothing — bust the fingerprint so AI re-runs for this room
                invalidateFingerprint(for: insight.roomName)
            }
        }
    }

    private func normalizeVisibleInsightSeverities(rooms: [RoomEnvironmentData]) {
        let severityByRoom = Dictionary(uniqueKeysWithValues: rooms.map { room in
            (room.roomName, severityFloor(for: room.worstUrgency))
        })

        for index in insights.indices {
            let insight = insights[index]
            guard insight.isVisible,
                  let roomSeverity = severityByRoom[insight.roomName],
                  roomSeverity > insight.severity
            else { continue }

            insights[index] = AmbientalAIInsight(
                id: insight.id,
                roomName: insight.roomName,
                message: insight.message,
                severity: roomSeverity,
                intelligenceLevel: insight.intelligenceLevel,
                patternKey: insight.patternKey,
                whyExplanation: insight.whyExplanation,
                confidence: insight.confidence,
                generatedAt: insight.generatedAt,
                isDismissed: insight.isDismissed,
                nextActions: insight.nextActions,
                resolvedIntents: insight.resolvedIntents,
                sourceAccessoryID: insight.sourceAccessoryID,
                sourceAccessoryName: insight.sourceAccessoryName,
                sourceServiceType: insight.sourceServiceType,
                promptVersion: insight.promptVersion,
                isLanguageSuspect: insight.isLanguageSuspect
            )
            updatePersistedSeverity(for: insight.id, to: roomSeverity)
        }
    }

    private func severityFloor(for urgency: SensorUrgency) -> InsightSeverity {
        switch urgency {
        case .danger:  return .anomaly
        case .warning: return .warning
        case .normal:  return .info
        }
    }

    /// Auto-dismisses non-safety insights for a room when the PreProcessor determines
    /// all sensors have returned to normal (shouldCallAI = false).
    /// Safety-critical insights (respondToSmoke, respondToCO) are never auto-dismissed.
    /// Also invalidates the stored fingerprint so that when conditions become dangerous
    /// again, a fresh LLM analysis is triggered rather than hitting the cached result.
    private func autoDismissNormalizedInsights(for roomName: String) {
        let safetyIntents: Set<String> = [
            ActionIntent.respondToSmoke.rawValue,
            ActionIntent.respondToCO.rawValue
        ]
        let toAutoDismiss = insights.filter {
            $0.roomName == roomName &&
            $0.isVisible &&
            !$0.resolvedIntents.contains(where: { safetyIntents.contains($0) })
        }
        guard !toAutoDismiss.isEmpty else { return }

        for insight in toAutoDismiss {
            dismiss(insight, reason: .conditionsNormalized)
        }
        // Bust the stored fingerprint so the next dangerous state runs a fresh LLM call
        // instead of matching the now-stale cached result.
        invalidateFingerprint(for: roomName)
        dprint("✅ [AutoDismiss] \(roomName): \(toAutoDismiss.count) insight(s) dismissed — conditions normalized")
    }

    /// Deletes the RoomAnalysisState for a room, forcing the fingerprint check to fail on
    /// the current analyzeRooms() cycle and triggering a fresh AI + resolver pass.
    private func invalidateFingerprint(for roomName: String) {
        guard let state = fetchRoomState(roomName: roomName, context: context) else { return }
        context.delete(state)
        try? context.save()
        dprint("🗑️ [Fingerprint] Invalidated '\(roomName)' — tip-only insight, will re-analyse")
    }

    /// Writes a new insight to SwiftData, invalidating any previous active record for the same room.
    private func persistInsight(_ insight: AmbientalAIInsight) {
        let roomName = insight.roomName
        let statusActive = HomeInsightStatus.active.rawValue
        let environmentCategory = HomeInsightCategory.environment.rawValue
        let existing = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate {
                $0.roomName == roomName &&
                $0.statusRaw == statusActive &&
                $0.categoryRaw == environmentCategory
            }
        )
        if let records = try? context.fetch(existing) {
            records.forEach { $0.markResolved() }
        }
        upsertPersistedHomeInsight(from: insight)
        try? context.save()
    }

    /// Mirrors legacy environmental AI insight records into the unified home insight store.
    private func upsertPersistedHomeInsight(from record: PersistedInsight) {
        let insight = HomeInsightMapper.map(record)
        upsertPersistedHomeInsight(insight)
    }

    /// Writes current environmental AI insights directly into the unified home insight store.
    private func upsertPersistedHomeInsight(from insight: AmbientalAIInsight) {
        upsertPersistedHomeInsight(homeInsight(from: insight))
    }

    private func upsertPersistedHomeInsight(_ insight: HomeInsight) {
        let dedupeKey = insight.dedupeKey
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate { $0.dedupeKey == dedupeKey }
        )

        if let existing = (try? context.fetch(descriptor))?.first {
            existing.update(from: insight)
        } else {
            context.insert(PersistedHomeInsight(insight: insight))
        }
    }

    private func homeInsight(from insight: AmbientalAIInsight) -> HomeInsight {
        HomeInsight(
            id: insight.id,
            kind: homeInsightKind(from: insight.intelligenceLevel, severity: insight.severity),
            category: .environment,
            severity: homeInsightSeverity(from: insight.severity),
            status: insight.isDismissed ? .dismissed : .active,
            title: displayTitle(for: insight),
            message: insight.message,
            whyExplanation: insight.whyExplanation,
            sourceEntityID: insight.sourceAccessoryID,
            sourceEntityName: insight.sourceAccessoryName,
            roomName: insight.roomName,
            createdAt: insight.generatedAt,
            updatedAt: Date(),
            startedAt: insight.generatedAt,
            resolvedAt: insight.isDismissed ? Date() : nil,
            confidence: insight.confidence,
            dedupeKey: insight.patternKey ?? "ambientalAI|\(insight.roomName)|\(insight.id.uuidString)",
            suggestedActionJSON: encodeNextActions(insight.nextActions),
            sourceRecordType: String(describing: AmbientalAIInsight.self),
            sourceRecordID: insight.id.uuidString,
            syncPolicy: .syncFull
        )
    }

    private func displayTitle(for insight: AmbientalAIInsight) -> String {
        let isItalian = Locale.current.language.languageCode?.identifier == "it"
        let roomName = insight.roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = roomName.isEmpty ? (isItalian ? "Casa" : "Home") : roomName
        // Gli underscore del patternKey AI ("kitchen_morning_air_quality_degradation")
        // impedivano il match dei token ("air_quality" ≠ "air quality") e il titolo
        // cadeva sul fallback inglese capitalizzato.
        let key = (insight.patternKey ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let message = insight.message
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let text = "\(key) \(message)"

        if text.contains("co2") || text.contains("co₂") || text.contains("anidride carbonica") || text.contains("carbon dioxide") {
            return isItalian ? "CO2 elevata in \(room)" : "Elevated CO2 in \(room)"
        }

        if text.contains("airquality") || text.contains("air quality") || text.contains("qualita aria") || text.contains("qualità aria") {
            return isItalian ? "Qualità aria da controllare in \(room)" : "Air quality to check in \(room)"
        }

        if text.contains("solar") || text.contains("heat") || text.contains("caldo") || text.contains("temperatura") || text.contains("temperature") {
            return isItalian ? "Temperatura da monitorare in \(room)" : "Temperature to monitor in \(room)"
        }

        if text.contains("humid") || text.contains("umidit") || text.contains("umido") || text.contains("secco") || text.contains("dry") || text.contains("moist") {
            return isItalian ? "Umidità da controllare in \(room)" : "Humidity to check in \(room)"
        }

        if text.contains("lux") || text.contains("luminosit") || text.contains("brightness") || text.contains("light level") || text.contains("buio") || text.contains("dark") {
            return isItalian ? "Luminosità da controllare in \(room)" : "Light level to check in \(room)"
        }

        // Nessun token riconosciuto: fallback SEMPRE localizzato. Il patternKey AI è
        // in inglese per costruzione — capitalizzarlo produceva titoli non localizzati
        // ("Studio Afternoon Low Humidity") con il messaggio in italiano sotto.
        return isItalian ? "Insight ambiente in \(room)" : "Environment insight in \(room)"
    }

    private func encodeNextActions(_ actions: [AINextAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func homeInsightKind(from level: IntelligenceLevel, severity: InsightSeverity) -> HomeInsightKind {
        switch level {
        case .prediction:
            return .prediction
        case .recommendation:
            return .recommendation
        case .pattern:
            return .environment
        case .observation:
            return severity == .anomaly ? .anomaly : .environment
        }
    }

    private func homeInsightSeverity(from severity: InsightSeverity) -> HomeInsightSeverity {
        switch severity {
        case .anomaly:
            return .high
        case .warning:
            return .medium
        case .info:
            return .info
        }
    }

    /// Updates the persisted status of a single insight record.
    private func updatePersistedStatus(for id: UUID, to status: InsightPersistedStatus) {
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate { $0.id == id }
        )
        guard let record = (try? context.fetch(descriptor))?.first else { return }
        record.statusRaw = homeInsightStatus(from: status).rawValue
        if status != .active {
            record.resolvedAt = Date()
        }
        record.updatedAt = Date()
        try? context.save()
    }

    private func updatePersistedSeverity(for id: UUID, to severity: InsightSeverity) {
        let descriptor = FetchDescriptor<PersistedHomeInsight>(
            predicate: #Predicate { $0.id == id }
        )
        guard let record = (try? context.fetch(descriptor))?.first else { return }
        record.severityRaw = homeInsightSeverity(from: severity).rawValue
        record.updatedAt = Date()
        try? context.save()
    }

    private func homeInsightStatus(from status: InsightPersistedStatus) -> HomeInsightStatus {
        switch status {
        case .active:
            return .active
        case .dismissed:
            return .dismissed
        case .expired:
            return .expired
        case .executed:
            return .executed
        }
    }

    // MARK: - Semantic Fingerprint

    /// Builds a deterministic semantic fingerprint from the preprocessor result.
    /// Encodes only urgency/anomaly/direction per sensor type and the room classification.
    /// Raw numeric values are intentionally excluded to ignore insignificant fluctuations.
    private func computeSemanticFingerprint(preResult: PreProcessorResult) -> String {
        let sensorParts = preResult.sensorStatuses
            .sorted { $0.type < $1.type }
            .map { "\($0.type):\($0.urgency):\($0.isAnomaly ? "1" : "0"):\($0.anomalyDirection)" }
        return (sensorParts + ["rt:\(preResult.roomType.rawValue)"]).joined(separator: "|")
    }

    private func fetchRoomState(roomName: String, context: ModelContext) -> RoomAnalysisState? {
        let descriptor = FetchDescriptor<RoomAnalysisState>(
            predicate: #Predicate { $0.roomName == roomName }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func upsertRoomState(
        roomName:      String,
        fingerprint:   String,
        sortedIntents: [String],
        severityRaw:   String,
        insightID:     UUID?,
        context:       ModelContext,
        existing:      RoomAnalysisState?
    ) {
        let now = Date()
        if let state = existing {
            state.semanticFingerprint = fingerprint
            state.lastAnalysisDate    = now
            state.lastIntentSet       = sortedIntents
            state.lastSeverityRaw     = severityRaw
            if let id = insightID { state.lastInsightID = id }
        } else {
            let state = RoomAnalysisState(
                roomName:            roomName,
                lastAnalysisDate:    now,
                semanticFingerprint: fingerprint,
                lastIntentSet:       sortedIntents,
                lastSeverityRaw:     severityRaw,
                lastInsightID:       insightID
            )
            context.insert(state)
        }
        try? context.save()
    }

    /// Deletes PersistedInsight records older than 30 days regardless of status.
    func pruneOldInsights() {
        guard !LocalDataProtection.shouldPreserveSwiftData else { return }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<PersistedInsight>(
            predicate: #Predicate { $0.generatedAt < cutoff }
        )
        let old = (try? context.fetch(descriptor)) ?? []
        guard !old.isEmpty else { return }
        old.forEach { context.delete($0) }
        try? context.save()
        dprint("🗑️ [Persistence] Pruned \(old.count) expired insight record(s)")
    }

    // MARK: - Accessory Map

    /// Builds a UUID→name map from all HomeKit accessories (Sprint 16A).
    private func buildAccessoryNameMap() -> [String: String] {
        Dictionary(
            homeKit.allAccessories.map { ($0.uniqueIdentifier.uuidString, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Data Loading

    private func loadHistory(for room: RoomEnvironmentData) -> [SensorReading] {
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
