import Foundation
import SwiftData

// MARK: - EnvironmentalAutomationProbe

/// Prova a vuoto: cosa proporrebbe un suggeritore di automazioni costruito sulle
/// ricorrenze ambientali, se lo costruissimo?
///
/// Nasce da una lezione pagata tre volte. I motori abitudini (statistico,
/// deviazioni, occupancy) sono stati costruiti per intero — motore, persistenza,
/// UI — e solo alla fine provati su dati veri, scoprendo che non producevano
/// nulla: cercavano gesti manuali ricorrenti in una casa dove le automazioni
/// fanno tutto il rumore. Qui l'ordine è invertito: prima si guarda cosa
/// uscirebbe, poi si decide se valga la pena costruirlo.
///
/// **Questo file è usa e getta.** Non ha stato, non persiste niente, non entra
/// nello schema. Se il referto è deludente si cancella e il cantiere si chiude
/// avendo speso mezza giornata invece di uno sprint.
///
/// La sorgente è diversa da quella dei motori morti, ed è il punto: le
/// `EnvironmentalRecurrencePattern` misurano lo stato fisico della casa — che
/// accade comunque — invece di dedurre intenzioni dal comportamento umano.
enum EnvironmentalAutomationProbe {

    // MARK: - Soglie della prova

    /// Quante osservazioni servono prima di considerare una ricorrenza matura.
    /// Più alta della soglia dell'analyzer (3): generare un pattern e proporre
    /// un'automazione sono decisioni di peso diverso.
    static let minSamples = 4

    /// Quota di giorni sopra soglia perché valga la pena proporre.
    static let minExceedanceRate = 0.70

    /// Con quanto anticipo agire rispetto all'ora del picco.
    static let leadMinutes = 30

    // MARK: - Esito

    struct Candidate {
        let pattern: EnvironmentalRecurrencePattern
        let intents: [ActionIntent]
        /// Nome dell'accessorio che l'ActionResolver comanderebbe, nil se
        /// risolverebbe solo in un consiglio testuale.
        let resolvedAccessory: String?
        /// Ora a cui scatterebbe l'automazione ("HH:mm").
        let triggerTime: String
    }

    struct Report {
        var totalPatterns = 0
        var afterSeasonFilter = 0
        var afterMaturityFilter = 0
        var withKnownIntent = 0
        var candidates: [Candidate] = []
        /// Ricorrenze scartate, con il motivo — serve a distinguere "non ci sono
        /// dati" da "i dati ci sono ma il filtro è troppo severo".
        var rejections: [String] = []
    }

    // MARK: - Mappa sensore → intento

    /// Cosa si fa quando *questo* sensore sfora. Deliberatamente parziale:
    /// per fumo e monossido non si propone un'automazione, sono emergenze che
    /// vogliono una persona, non una regola.
    static func intents(for sensor: SensorServiceType) -> [ActionIntent] {
        switch sensor {
        case .carbonDioxide, .vocDensity:   return [.ventilateRoom, .improveAirQuality]
        case .airQuality, .pm25, .pm10:     return [.improveAirQuality, .ventilateRoom]
        case .humidity:                     return [.reduceHumidity]
        case .temperature:                  return [.coolRoom]
        default:                            return []
        }
    }

    // MARK: - Prova a vuoto

    /// Costruisce il referto senza toccare niente: nessuna scrittura, nessuna
    /// proposta creata, nessun effetto collaterale.
    ///
    /// - Parameter resolveAccessory: iniettata dal chiamante così la funzione
    ///   resta pura e testabile senza HomeKit. In produzione la fornisce
    ///   `ActionResolver`; nei test una closure finta.
    static func dryRun(
        patterns: [EnvironmentalRecurrencePattern],
        now: Date = Date(),
        resolveAccessory: (_ intents: [ActionIntent], _ roomName: String) -> String?
    ) -> Report {
        var report = Report()
        report.totalPatterns = patterns.count

        let season = CalendarSeason.current.rawValue

        for pattern in patterns {
            // Stagione: un pattern estivo non va proposto a novembre. Lo storico
            // pre-Sprint 31 ha seasonRaw vuoto e vale per tutte le stagioni.
            guard pattern.seasonRaw.isEmpty || pattern.seasonRaw == season else {
                report.rejections.append("\(pattern.roomName)/\(pattern.sensorTypeRaw): fuori stagione (\(pattern.seasonRaw) ≠ \(season))")
                continue
            }
            report.afterSeasonFilter += 1

            guard pattern.sampleCount >= minSamples else {
                report.rejections.append("\(pattern.roomName)/\(pattern.sensorTypeRaw): solo \(pattern.sampleCount) osservazioni (ne servono \(minSamples))")
                continue
            }
            guard pattern.exceedanceRate >= minExceedanceRate else {
                report.rejections.append(String(format: "%@/%@: sfora solo il %.0f%% delle volte (ne serve il %.0f%%)",
                                                pattern.roomName, pattern.sensorTypeRaw,
                                                pattern.exceedanceRate * 100, minExceedanceRate * 100))
                continue
            }
            report.afterMaturityFilter += 1

            guard let sensor = pattern.sensorType else {
                report.rejections.append("\(pattern.roomName)/\(pattern.sensorTypeRaw): tipo sensore non riconosciuto")
                continue
            }
            let intents = Self.intents(for: sensor)
            guard !intents.isEmpty else {
                report.rejections.append("\(pattern.roomName)/\(pattern.sensorTypeRaw): nessuna azione sensata per questo sensore")
                continue
            }
            report.withKnownIntent += 1

            let accessory = resolveAccessory(intents, pattern.roomName)
            report.candidates.append(Candidate(
                pattern: pattern,
                intents: intents,
                resolvedAccessory: accessory,
                triggerTime: triggerTime(forPeakHour: pattern.hourOfDay)
            ))
        }
        return report
    }

    /// Orario di scatto: `leadMinutes` prima del picco, con wrap a mezzanotte.
    static func triggerTime(forPeakHour hour: Int) -> String {
        let minutes = ((hour * 60) - leadMinutes + 1440) % 1440
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Referto leggibile

    /// Il referto in testo. Ricalca gli stadi numerati della pipeline ambientale
    /// (P1→P7), che è l'unica di questo progetto che si riesca a diagnosticare
    /// leggendo il log invece che indovinando.
    static func format(_ report: Report) -> String {
        var out: [String] = []
        out.append("=== PROVA A VUOTO — automazioni da ricorrenze ambientali ===")
        out.append("")
        out.append("S1 · ricorrenze salvate ............ \(report.totalPatterns)")
        out.append("S2 · in stagione .................. \(report.afterSeasonFilter)")
        out.append("S3 · abbastanza mature ............ \(report.afterMaturityFilter)   (≥\(minSamples) osservazioni, ≥\(Int(minExceedanceRate * 100))% sfori)")
        out.append("S4 · con un'azione sensata ........ \(report.withKnownIntent)")
        out.append("S5 · PROPOSTE ..................... \(report.candidates.count)")
        let actionable = report.candidates.filter { $0.resolvedAccessory != nil }.count
        out.append("     di cui con accessorio ........ \(actionable)")
        out.append("")

        if report.candidates.isEmpty {
            out.append("Nessuna proposta.")
        } else {
            out.append("--- Cosa proporrebbe ---")
            for c in report.candidates {
                let day = c.pattern.dayType.localizedLabel
                let target = c.resolvedAccessory ?? "⚠️ nessun accessorio — sarebbe solo un consiglio"
                out.append(String(format: "• %@, %@ di %@ (verso le %02d:00) — %@ arriva a %.0f (%d/%d giorni)",
                                  c.pattern.roomName, day, c.pattern.timeOfDay.localizedLabel, c.pattern.hourOfDay,
                                  c.pattern.sensorTypeRaw, c.pattern.meanPeakValue,
                                  c.pattern.aboveWarningCount, c.pattern.sampleCount))
                out.append("  → alle \(c.triggerTime): \(target)")
            }
        }

        if !report.rejections.isEmpty {
            out.append("")
            out.append("--- Perché le altre sono state scartate ---")
            for r in report.rejections { out.append("· \(r)") }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Sorgente a monte

    /// Perché S1 è zero? Le ricorrenze sono un prodotto derivato: nascono dai
    /// `DailySensorSummary`, che a loro volta nascono solo dentro il ciclo
    /// giornaliero `runFullCycle`, invocato da un `BGProcessingTask`. Su un
    /// pannello sempre acceso e in primo piano quel task potrebbe non essere mai
    /// concesso da iOS — quindi "nessuna ricorrenza" può voler dire "la catena
    /// non è mai partita" invece di "non c'è segnale". Sono due diagnosi opposte
    /// e questo referto le distingue.
    static func upstreamReport(modelContainer: ModelContainer) -> String {
        let ctx = ModelContext(modelContainer)
        var out: [String] = []
        out.append("=== SORGENTE A MONTE ===")
        out.append("")

        let lastCycle = UserDefaults.standard.object(forKey: "dataLifecycle.lastCycleDate") as? Date
        out.append("Ultimo ciclo DataLifecycle ....... " + (lastCycle.map {
            "\($0.formatted(date: .abbreviated, time: .shortened))  (\($0.formatted(.relative(presentation: .named))))"
        } ?? "MAI ESEGUITO"))

        let readings = (try? ctx.fetchCount(FetchDescriptor<SensorReading>())) ?? 0
        out.append("SensorReading grezze ............. \(readings)")

        let summaries = (try? ctx.fetch(FetchDescriptor<DailySensorSummary>())) ?? []
        out.append("DailySensorSummary aggregati ..... \(summaries.count)")

        if summaries.isEmpty {
            out.append("")
            out.append("→ Nessun aggregato: la catena ambientale non ha mai prodotto nulla.")
            out.append("  Le ricorrenze non possono esistere. Il problema NON è mancanza di")
            out.append("  segnale — è che il ciclo giornaliero non gira.")
            return out.joined(separator: "\n")
        }

        let dates = summaries.map(\.date).sorted()
        if let first = dates.first, let last = dates.last {
            out.append("Copertura ........................ \(first.formatted(date: .abbreviated, time: .omitted)) → \(last.formatted(date: .abbreviated, time: .omitted))")
            out.append("Giorni distinti .................. \(Set(dates.map { Calendar.current.startOfDay(for: $0) }).count)")
        }

        // Due raggruppamenti a confronto, ed è il cuore del referto.
        //
        // La prima versione di questo blocco usava `component(.hour, from: s.date)`
        // — ma `s.date` è uno startOfDay, quindi l'ora era sempre zero e il
        // raggruppamento risultava 24 volte più grossolano di quello vero.
        // Contava 224 gruppi maturi e concludeva "il materiale c'è" mentre
        // l'analyzer ne salvava sei: lo strumento diagnostico mentiva, ed è il
        // difetto peggiore che possa avere.
        let cal = Calendar.current

        // A) La chiave REALE dell'analyzer, replicata alla lettera da
        //    EnvironmentalPatternAnalyzer: l'ora viene da `peakAt`, non da `date`.
        var strict: [String: Int] = [:]
        for s in summaries {
            let key = "\(s.roomName)|\(s.serviceTypeRaw)|\(cal.component(.weekday, from: s.date))"
                    + "|\(cal.component(.hour, from: s.peakAt))|\(CalendarSeason.season(for: s.date).rawValue)"
            strict[key, default: 0] += 1
        }
        let strictMature = strict.values.filter { $0 >= 3 }.count

        // B) L'alternativa in valutazione: fascia oraria invece di ora esatta,
        //    feriale/festivo invece di giorno esatto. L'ora del picco è la
        //    dimensione più volatile che esista — basta una finestra aperta o una
        //    cena diversa e slitta — quindi frammenta i bucket senza aggiungere
        //    significato. Serve a rispondere con numeri, non a intuito, alla
        //    domanda: allargare il raggruppamento renderebbe le ricorrenze
        //    raggiungibili?
        var loose: [String: Int] = [:]
        for s in summaries {
            let weekday = cal.component(.weekday, from: s.date)
            let dayType = (weekday == 1 || weekday == 7) ? "festivo" : "feriale"
            let key = "\(s.roomName)|\(s.serviceTypeRaw)|\(dayType)|\(Self.timeBand(cal.component(.hour, from: s.peakAt)))"
            loose[key, default: 0] += 1
        }
        let looseMature = loose.values.filter { $0 >= 3 }.count
        let looseRich   = loose.values.filter { $0 >= 8 }.count

        out.append("")
        out.append("— Raggruppamento attuale (giorno esatto · ora del picco · stagione) —")
        out.append("Gruppi ........................... \(strict.count)")
        out.append("  di cui con ≥3 campioni ......... \(strictMature)   ← soglia dell'analyzer")
        out.append("")
        out.append("— Alternativa (feriale/festivo · fascia oraria) —")
        out.append("Gruppi ........................... \(loose.count)")
        out.append("  di cui con ≥3 campioni ......... \(looseMature)")
        out.append("  di cui con ≥8 campioni ......... \(looseRich)   ← davvero mature")
        out.append("")
        if strict.isEmpty {
            out.append("→ Nessun aggregato utilizzabile.")
        } else {
            let gain = strictMature > 0 ? Double(looseMature) / Double(strictMature) : Double(looseMature)
            out.append(String(format: "→ Allargare il raggruppamento moltiplica i gruppi maturi per %.1f×.", gain))
            out.append("  Media campioni per gruppo: \(strict.count > 0 ? summaries.count / strict.count : 0) stretto, \(loose.count > 0 ? summaries.count / loose.count : 0) allargato.")
        }
        return out.joined(separator: "\n")
    }

    /// Fascia oraria al posto dell'ora esatta. I confini sono quelli che una
    /// persona userebbe descrivendo la propria giornata, non quartili: "lo
    /// Studio ha aria viziata la sera" è un'abitudine riconoscibile, "picco di
    /// CO₂ il martedì alle 21" è un artefatto statistico.
    static func timeBand(_ hour: Int) -> String {
        switch hour {
        case 6..<12:  return "mattina"
        case 12..<18: return "pomeriggio"
        case 18..<23: return "sera"
        default:      return "notte"
        }
    }

}
