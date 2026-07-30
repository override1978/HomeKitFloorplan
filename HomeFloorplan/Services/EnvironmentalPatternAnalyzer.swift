import Foundation
import SwiftData

// MARK: - EnvironmentalRecurrencePattern

/// A recurring environmental exceedance event detected across multiple weeks of history.
/// Codable for UserDefaults persistence — no SwiftData migration needed.
struct EnvironmentalRecurrencePattern: Codable, Identifiable {

    var id:                 UUID
    var roomName:           String
    var sensorTypeRaw:      String
    /// Feriale o festivo.
    ///
    /// Era il giorno esatto della settimana, e insieme all'ora esatta del picco
    /// rendeva le ricorrenze irraggiungibili: misurato sui dati veri, quel
    /// raggruppamento produceva 807 bucket da 981 aggregati — una media di 1,2
    /// campioni ciascuno, cioè non raggruppava affatto. Con feriale/festivo e
    /// fascia oraria i bucket scendono a 244 con media 4, e i gruppi che
    /// raggiungono la soglia si moltiplicano per circa quattro.
    ///
    /// È anche più onesto come significato: "aria viziata la sera nei giorni
    /// lavorativi" è un'abitudine che una persona riconosce, "picco di CO₂ il
    /// martedì alle 21" è un artefatto statistico.
    var dayType:            DayType
    /// Fascia oraria in cui cade il picco. Sostituisce l'ora esatta come
    /// dimensione di raggruppamento: l'ora del picco è la più volatile che
    /// esista — basta una finestra aperta o una cena diversa e slitta.
    var timeOfDay:          TimeOfDay
    /// Ora media (0–23) dei picchi in questo gruppo.
    ///
    /// Non è più una dimensione di raggruppamento ma un valore derivato, e
    /// serve a chi deve programmare un'ora concreta — `PredictiveAlertBuilder`
    /// calcola da qui quanti minuti mancano al picco atteso. La fascia dice
    /// *quando* in termini umani, questa dice *a che ora* in termini di orologio.
    var hourOfDay:          Int
    /// Total DailySensorSummary records contributing to this pattern.
    var sampleCount:        Int
    /// How many of those days the sensor exceeded the seasonal warning threshold.
    var aboveWarningCount:  Int
    /// Mean peak value across all matching days.
    var meanPeakValue:      Double
    var lastUpdatedAt:      Date
    /// Season this pattern belongs to (CalendarSeason rawValue).
    /// Empty string means legacy data collected before Sprint 31 (treat as all-season).
    var seasonRaw:          String

    var sensorType: SensorServiceType? { SensorServiceType(rawValue: sensorTypeRaw) }

    var exceedanceRate: Double {
        sampleCount > 0 ? Double(aboveWarningCount) / Double(sampleCount) : 0
    }

    /// Confidence: saturates at 1.0 after 8 matching observations.
    var confidence: Double { min(1.0, Double(sampleCount) / 8.0) }

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case id, roomName, sensorTypeRaw, dayType, timeOfDay, hourOfDay
        case sampleCount, aboveWarningCount, meanPeakValue, lastUpdatedAt
        case seasonRaw
    }

    // MARK: - Inits

    init(
        id:                UUID,
        roomName:          String,
        sensorTypeRaw:     String,
        dayType:           DayType,
        timeOfDay:         TimeOfDay,
        hourOfDay:         Int,
        sampleCount:       Int,
        aboveWarningCount: Int,
        meanPeakValue:     Double,
        lastUpdatedAt:     Date,
        seasonRaw:         String = ""
    ) {
        self.id                = id
        self.roomName          = roomName
        self.sensorTypeRaw     = sensorTypeRaw
        self.dayType           = dayType
        self.timeOfDay         = timeOfDay
        self.hourOfDay         = hourOfDay
        self.sampleCount       = sampleCount
        self.aboveWarningCount = aboveWarningCount
        self.meanPeakValue     = meanPeakValue
        self.lastUpdatedAt     = lastUpdatedAt
        self.seasonRaw         = seasonRaw
    }

    /// Backward-compatible decoder: `seasonRaw` defaults to "" when missing
    /// (records written before Sprint 31 don't contain this key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decode(UUID.self,   forKey: .id)
        roomName          = try c.decode(String.self, forKey: .roomName)
        sensorTypeRaw     = try c.decode(String.self, forKey: .sensorTypeRaw)
        dayType           = try c.decode(DayType.self,   forKey: .dayType)
        timeOfDay         = try c.decode(TimeOfDay.self, forKey: .timeOfDay)
        hourOfDay         = try c.decode(Int.self,       forKey: .hourOfDay)
        sampleCount       = try c.decode(Int.self,    forKey: .sampleCount)
        aboveWarningCount = try c.decode(Int.self,    forKey: .aboveWarningCount)
        meanPeakValue     = try c.decode(Double.self, forKey: .meanPeakValue)
        lastUpdatedAt     = try c.decode(Date.self,   forKey: .lastUpdatedAt)
        seasonRaw         = (try? c.decodeIfPresent(String.self, forKey: .seasonRaw)) ?? ""
    }
}

// MARK: - EnvironmentalPatternAnalyzer

/// Scans DailySensorSummary history to find recurring environmental exceedances
/// grouped by (room, sensor type, day type, time of day, season). Stores results in UserDefaults.
/// Intended to run once daily from the DataLifecycle background task.
enum EnvironmentalPatternAnalyzer {

    static let patternsKey = "env.recurrence.patterns.v1"

    /// Minimum fraction of matching days that exceeded the threshold to surface a pattern.
    private static let minExceedanceRate: Double = 0.60
    /// Minimum samples before a pattern is considered reliable.
    private static let minSamples: Int = 3
    /// Lookback window in days.
    private static let lookbackDays: Int = 56  // 8 weeks

    // MARK: - Analysis

    /// Fetches DailySensorSummary records, groups them by (room, sensor, day type, time of day, season),
    /// and persists detected patterns. Season-aware grouping (Sprint 31.5) prevents summer
    /// heat patterns from inflating winter baselines.
    static func analyze(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        let descriptor = FetchDescriptor<DailySensorSummary>(
            predicate: #Predicate { $0.date >= cutoff }
        )
        let summaries = (try? context.fetch(descriptor)) ?? []
        guard summaries.count >= 3 else { return }

        let cal    = Calendar.current
        let season = CalendarSeason.current

        // Group by (roomName, serviceTypeRaw, dayType, timeOfDay, season).
        //
        // Erano il giorno esatto e l'ora esatta del picco. Misurato sui dati
        // reali di una casa con 39 giorni di copertura, quel raggruppamento
        // produceva 807 gruppi da 981 aggregati: 1,2 campioni per gruppo, cioè
        // non raggruppava. Nessuna ricorrenza poteva maturare — non per
        // scarsità di dati ma per costruzione. Con feriale/festivo e fascia
        // oraria i gruppi scendono a 244 con media 4 campioni.
        var groups: [String: [DailySensorSummary]] = [:]
        for s in summaries {
            let dayType   = DayType(weekday: cal.component(.weekday, from: s.date))
            let timeOfDay = TimeOfDay(hour: cal.component(.hour, from: s.peakAt))
            let seasonStr = CalendarSeason.season(for: s.date).rawValue
            let key       = "\(s.roomName)|\(s.serviceTypeRaw)|\(dayType.rawValue)|\(timeOfDay.rawValue)|\(seasonStr)"
            groups[key, default: []].append(s)
        }

        var patterns: [EnvironmentalRecurrencePattern] = []
        for (keyStr, group) in groups {
            guard group.count >= minSamples else { continue }

            let parts = keyStr.split(separator: "|", maxSplits: 4)
            guard parts.count == 5,
                  let dayType   = DayType(rawValue: String(parts[2])),
                  let timeOfDay = TimeOfDay(rawValue: String(parts[3])),
                  let sType     = SensorServiceType(rawValue: String(parts[1]))
            else { continue }

            // L'ora concreta non è più una dimensione del gruppo, quindi va
            // derivata: la media dei picchi effettivi. Serve a chi deve
            // programmare un orario, non a descrivere l'abitudine.
            //
            // **Media circolare, non aritmetica.** L'ora è una grandezza ciclica
            // e la fascia `night` scavalca la mezzanotte (21–5): picchi alle 22,
            // 23, 1 e 2 danno media aritmetica 12, cioè mezzogiorno. Il primo
            // referto lo mostrava subito — "nel weekend di Notte verso le 11:00"
            // — ed è il tipo di errore che passa inosservato se nessuno stampa
            // il risultato in una frase leggibile.
            //
            // Mediando i versori invece dei numeri il problema non esiste, per
            // tutte le fasce e senza casi speciali.
            let hour: Int = {
                let angles = group.map { Double(cal.component(.hour, from: $0.peakAt)) / 24 * 2 * .pi }
                let sinSum = angles.reduce(0) { $0 + sin($1) }
                let cosSum = angles.reduce(0) { $0 + cos($1) }
                guard abs(sinSum) > 1e-9 || abs(cosSum) > 1e-9 else {
                    // Picchi diametralmente opposti: la media circolare non è
                    // definita. Si ripiega sull'ora del primo campione, che è
                    // arbitraria ma non assurda.
                    return cal.component(.hour, from: group[0].peakAt)
                }
                var mean = atan2(sinSum, cosSum) / (2 * .pi) * 24
                if mean < 0 { mean += 24 }
                return Int(mean.rounded()) % 24
            }()

            let threshold = SeasonalBaselineProvider.warningThreshold(for: sType, season: season)
            let aboveCount = group.filter { $0.peakValue >= threshold }.count
            let rate = Double(aboveCount) / Double(group.count)
            guard rate >= minExceedanceRate else { continue }

            let meanPeak  = group.map(\.peakValue).reduce(0, +) / Double(group.count)
            let seasonStr = String(parts[4])

            patterns.append(EnvironmentalRecurrencePattern(
                id:                UUID(),
                roomName:          String(parts[0]),
                sensorTypeRaw:     String(parts[1]),
                dayType:           dayType,
                timeOfDay:         timeOfDay,
                hourOfDay:         hour,
                sampleCount:       group.count,
                aboveWarningCount: aboveCount,
                meanPeakValue:     meanPeak,
                lastUpdatedAt:     Date(),
                seasonRaw:         seasonStr
            ))
        }

        VersionedStore<[EnvironmentalRecurrencePattern]>(key: Self.patternsKey, version: 2).save(patterns)
    }

    // MARK: - Load

    /// Loads persisted patterns, preferring those for the current season.
    /// Falls back to legacy patterns (seasonRaw == "") when no seasonal data exists yet.
    static func loadPatterns() -> [EnvironmentalRecurrencePattern] {
        let decoded = VersionedStore<[EnvironmentalRecurrencePattern]>(key: patternsKey, version: 2).load() ?? []
        guard !decoded.isEmpty else { return [] }

        let currentSeason = CalendarSeason.current.rawValue
        let seasonal = decoded.filter { $0.seasonRaw == currentSeason }
        return seasonal.isEmpty ? decoded.filter { $0.seasonRaw.isEmpty } : seasonal
    }
}

// MARK: - CalendarSeason extension

extension CalendarSeason {
    /// Returns the season for a given date (used during pattern analysis to bucket historical records).
    ///
    /// Non più `private`: `EnvironmentalAutomationProbe` deve replicare la chiave
    /// di raggruppamento dell'analyzer **alla lettera** per poterla misurare. La
    /// prima versione della sonda l'approssimava e finiva per contare un
    /// raggruppamento diverso da quello reale, concludendo che il materiale
    /// abbondasse mentre l'analyzer salvava sei ricorrenze. Uno strumento di
    /// misura che approssima ciò che misura è peggio di nessuno strumento.
    static func season(for date: Date) -> CalendarSeason {
        let month = Calendar.current.component(.month, from: date)
        switch month {
        case 3...5:  return .spring
        case 6...8:  return .summer
        case 9...11: return .autumn
        default:     return .winter
        }
    }
}
