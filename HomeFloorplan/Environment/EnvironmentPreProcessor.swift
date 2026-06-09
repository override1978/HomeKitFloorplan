import Foundation

// MARK: - RoomType

/// Classificazione semantica di una stanza per guidare le decisioni AI e il filtro degli intent.
enum RoomType: String, Codable, CaseIterable {
    case indoor  = "indoor"
    case outdoor = "outdoor"
    case utility = "utility"
    case transit = "transit"
}

// MARK: - RoomClassifier

/// Classifica una stanza per nome usando keyword italiane.
/// Stateless — tutti i metodi sono statici.
enum RoomClassifier {

    private static let outdoorKeywords: [String] = [
        "balcone", "terrazzo", "giardino", "garden", "patio",
        "cortile", "portico", "veranda"
    ]

    private static let utilityKeywords: [String] = [
        "lavanderia", "garage", "cantina", "ripostiglio", "soffitta"
    ]

    private static let transitKeywords: [String] = [
        "ingresso", "corridoio", "disimpegno", "scale", "pianerottolo"
    ]

    /// Classifica il nome della stanza in un RoomType.
    /// - Parameters:
    ///   - roomName: Nome della stanza da classificare.
    ///   - outdoorRoomName: Nome stanza outdoor impostato dall'utente (AppStorage "outdoorRoomName").
    ///                      Se corrisponde esattamente (case-insensitive) → `.outdoor` con precedenza massima.
    static func classify(roomName: String, outdoorRoomName: String = "") -> RoomType {
        let lower = roomName.lowercased()

        // Override esplicito dell'utente ha priorità assoluta
        if !outdoorRoomName.isEmpty,
           lower == outdoorRoomName.lowercased() {
            return .outdoor
        }

        if outdoorKeywords.contains(where: { lower.contains($0) }) { return .outdoor }
        if utilityKeywords.contains(where: { lower.contains($0) }) { return .utility }
        if transitKeywords.contains(where: { lower.contains($0) }) { return .transit }
        return .indoor
    }
}

// MARK: - SensorStatusEntry

/// Stato pre-valutato di un sensore, serializzabile direttamente nel payload LLM.
/// Sostituisce l'invio di valori grezzi + soglie al modello.
struct SensorStatusEntry: Codable {
    /// SensorServiceType.rawValue (es. "temperature", "humidity").
    let type: String
    /// Valore corrente del sensore.
    let value: Double
    /// Urgency deterministica: "normal" | "warning" | "danger".
    let urgency: String
    /// Deviazione dalla media storica in sigma. Nil se baseline insufficiente (< 5 letture).
    let deviationSigma: Double?
    /// True se |deviationSigma| > anomalyThreshold (1.5σ).
    let isAnomaly: Bool
    /// Direzione dell'anomalia statistica: "high" | "low" | "none".
    let anomalyDirection: String
    /// True se l'anomalia è actionable, cioè richiede attenzione reale.
    let actionableAnomaly: Bool

    // Sprint 16A — Device identity & health

    /// UUID string of the primary contributing accessory (first UUID when aggregated).
    let accessoryID: String?
    /// Display name of the primary contributing accessory.
    let accessoryName: String?
    /// True if no reading has arrived in the last 60 minutes (device health signal).
    let isStale: Bool
    /// Minutes since last reading. Non-nil only when isStale is true.
    let staleMinutes: Int?
}

// MARK: - PreProcessorResult

/// Risultato del pre-processing deterministico di una stanza.
struct PreProcessorResult {
    /// Stato pre-valutato di ogni sensore nella stanza.
    let sensorStatuses: [SensorStatusEntry]
    /// Tipo di stanza classificato deterministicamente.
    let roomType: RoomType
    /// Gate AI: false = salta la chiamata API (tutto nella norma).
    let shouldCallAI: Bool
    /// Severità massima che l'LLM può assegnare (clamping post-parsing).
    let severityCeiling: InsightSeverity
}

// MARK: - EnvironmentPreProcessor

/// Pre-processore deterministico dell'ambiente.
/// Calcola stato sensori, tipo stanza, gate AI e severità ceiling
/// PRIMA di costruire il payload LLM.
///
/// Stateless — tutti i metodi sono statici.
enum EnvironmentPreProcessor {

    /// Soglia di anomalia statistica in sigma. Valori |σ| > 1.5 sono considerati anomali.
    static let anomalyThreshold: Double = 1.5

    // MARK: - Pre-Processing

    /// Esegue il pre-processing completo per una stanza.
    /// - Parameters:
    ///   - room: Dati ambientali correnti della stanza.
    ///   - baselineByType: Baseline 7 giorni pre-calcolata: [serviceType.rawValue: (avg, stdDev)].
    ///   - outdoorRoomName: Nome stanza outdoor da UserDefaults (AppStorage "outdoorRoomName").
    /// Stale threshold: sensors with no update in the last 60 minutes are flagged.
    static let staleThresholdMinutes: Int = 60

    static func preProcess(
        room: RoomEnvironmentData,
        baselineByType: [String: (avg: Double, stdDev: Double)],
        outdoorRoomName: String = "",
        accessoryNameMap: [String: String] = [:]
    ) -> PreProcessorResult {

        let roomType = RoomClassifier.classify(roomName: room.roomName, outdoorRoomName: outdoorRoomName)
        let now = Date()

        var sensorStatuses: [SensorStatusEntry] = []
        var worstUrgency: SensorUrgency = .normal

        for sensor in room.sensors {
            let urgency = sensor.urgency
            if urgency > worstUrgency { worstUrgency = urgency }

            // Stale detection: flag sensors with no update in the last 60 minutes
            let minutesSinceUpdate = Int(-sensor.lastUpdated.timeIntervalSince(now) / 60)
            let isStale = minutesSinceUpdate >= staleThresholdMinutes
            let staleMinutes: Int? = isStale ? minutesSinceUpdate : nil

            // Device identity — use first UUID as primary source
            let primaryUUID = sensor.accessoryUUIDs.first
            let accessoryName = primaryUUID.flatMap { accessoryNameMap[$0] }

            // Calcola deviazione dalla baseline se disponibile
            var sigma: Double? = nil
            var isAnomaly = false
            var anomalyDirection = "none"
            var actionableAnomaly = false

            // Skip statistical anomaly check for stale sensors — value is unreliable
            if !isStale,
               let baseline = baselineByType[sensor.serviceType.rawValue],
               baseline.stdDev > 0 {
                let deviation = (sensor.currentValue - baseline.avg) / baseline.stdDev
                sigma = Double(round(deviation * 100) / 100)
                isAnomaly = abs(deviation) > anomalyThreshold

                if deviation > anomalyThreshold {
                    anomalyDirection = "high"
                    actionableAnomaly = true
                } else if deviation < -anomalyThreshold {
                    anomalyDirection = "low"
                    if let lowWarn = sensor.serviceType.defaultLowWarning {
                        actionableAnomaly = sensor.currentValue < lowWarn
                    } else {
                        actionableAnomaly = false
                    }
                }
            }

            let entry = SensorStatusEntry(
                type: sensor.serviceType.rawValue,
                value: sensor.currentValue,
                urgency: urgencyString(urgency),
                deviationSigma: sigma,
                isAnomaly: isAnomaly,
                anomalyDirection: anomalyDirection,
                actionableAnomaly: actionableAnomaly,
                accessoryID: primaryUUID,
                accessoryName: accessoryName,
                isStale: isStale,
                staleMinutes: staleMinutes
            )
            sensorStatuses.append(entry)
        }

        // AI Call Gate: call AI when urgency is elevated, there is an actionable anomaly,
        // or a sensor is stale (device health signal worth reporting).
        let hasAbnormal = sensorStatuses.contains { $0.urgency != "normal" || $0.actionableAnomaly || $0.isStale }
        let shouldCallAI = hasAbnormal

        let ceiling = severityCeiling(for: worstUrgency)

        return PreProcessorResult(
            sensorStatuses: sensorStatuses,
            roomType: roomType,
            shouldCallAI: shouldCallAI,
            severityCeiling: ceiling
        )
    }

    // MARK: - Severity Clamping

    /// Clamp la severity LLM al ceiling deterministico.
    /// Garantisce che il modello non possa assegnare severità più alta di quella giustificata dai dati.
    static func clampSeverity(
        _ llmSeverity: InsightSeverity,
        ceiling: InsightSeverity
    ) -> InsightSeverity {
        min(llmSeverity, ceiling)
    }

    // MARK: - Intent Filtering

    /// Filtra gli intent per tipo di stanza.
    /// - Intent HVAC/ventilazione rimossi per stanze outdoor (nonsensical).
    /// - Intent di sicurezza (smoke, CO) passano sempre.
    static func filterIntents(
        _ intents: [ActionIntent],
        for roomType: RoomType
    ) -> [ActionIntent] {
        guard roomType == .outdoor else { return intents }

        // coolRoom is NOT blocked outdoors — its fallbackTip produces "Attiva la tenda da sole"
        // heatRoom and ventilateRoom are suppressed (no HVAC/ventilation outdoors makes sense)
        let outdoorBlocked: Set<ActionIntent> = [.heatRoom, .ventilateRoom]
        return intents.filter { !outdoorBlocked.contains($0) }
    }

    // MARK: - Private Helpers

    private static func urgencyString(_ urgency: SensorUrgency) -> String {
        switch urgency {
        case .normal:  return "normal"
        case .warning: return "warning"
        case .danger:  return "danger"
        }
    }

    private static func severityCeiling(for worstUrgency: SensorUrgency) -> InsightSeverity {
        switch worstUrgency {
        case .normal:  return .info
        case .warning: return .warning
        case .danger:  return .anomaly
        }
    }
}
