import AppIntents
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Errori

/// Errori mostrati da Siri / Comandi quando un intent non può completare.
nonisolated enum HomeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case homeUnavailable
    case noRememberedVimarExport

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .homeUnavailable:
            return LocalizedStringResource(
                "intent.error.homeUnavailable",
                defaultValue: "Your home isn't available right now. Open Home Floorplan once and try again."
            )
        case .noRememberedVimarExport:
            return LocalizedStringResource(
                "intent.error.noVimarExport",
                defaultValue: "No Vimar export to update yet. Import it once from the Energy section, or pass the file to this action."
            )
        }
    }
}

// MARK: - Analizza casa

/// Analisi ambientale completa senza passare dal pannello: campiona tutti i
/// sensori, ricostruisce le stanze dall'archivio appena scritto e forza l'AI
/// su ognuna, come il pulsante "aggiorna" della dashboard Ambiente.
///
/// Con molte stanze supera i ~30 secondi concessi a un intent in background:
/// da iOS 27 gira come `LongRunningIntent`, con l'avanzamento per stanza nella
/// Live Activity di sistema. Su iOS 26 gira direttamente.
struct AnalyzeHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze Home"
    static let description = IntentDescription(
        "Samples every sensor and runs the AI environmental analysis on all rooms."
    )
    static var supportedModes: IntentModes { .background }

    @Dependency private var services: AppServices

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = services
        let summary: HomeAnalysisSummary
        if #available(iOS 27.0, *) {
            let progress = progress
            progress.localizedDescription = String(
                localized: "intent.analyzeHome.progress",
                defaultValue: "Analyzing your home…"
            )
            summary = try await performBackgroundTask {
                try await services.runOnDemandHomeAnalysis(progress: progress)
            }
        } else {
            summary = try await services.runOnDemandHomeAnalysis(progress: nil)
        }
        // Senza schermo Siri legge tutto; con lo schermo la scheda porta i
        // dettagli, e sopra basta una riga che non li ripeta.
        return .result(
            dialog: IntentDialog(full: "\(summary.spokenText)", supporting: "\(summary.supportingText)"),
            view: HomeAnalysisSnippetView(summary: summary)
        )
    }
}

@available(iOS 27.0, *)
extension AnalyzeHomeIntent: LongRunningIntent {}

/// Esito dell'analisi on-demand: alimenta sia la risposta vocale sia la scheda.
nonisolated struct HomeAnalysisSummary: Sendable {
    struct RoomRow: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let temperature: String?
        let humidity: String?
        /// Cosa non va, es. "Umidità: 78%". `nil` se la stanza è a posto.
        let issue: String?
        /// Il tipo del valore fuori norma, per colorarlo dove la riga lo mostra già.
        let issueType: SensorServiceType?
        let urgency: SensorUrgency
        /// Spiegazione dell'AI per questa stanza, con l'azione consigliata.
        var aiNote: String? = nil
    }

    var verdict: String
    var climate: String? = nil
    var rooms: [RoomRow] = []
    var aiNotes: [String] = []
    var aiPending = false

    var hasIssues: Bool { rooms.contains { $0.urgency != .normal } }

    /// Sopra la scheda: il verdetto solo se è tutto a posto, altrimenti una
    /// riga neutra — stanza e valore li mostra già la scheda.
    var supportingText: String {
        hasIssues
            ? String(localized: "intent.analyzeHome.supporting", defaultValue: "Here's how your home is doing.")
            : verdict
    }

    var spokenText: String {
        var lines = [verdict]
        // La stanza più grave è già nel verdetto: le altre in elenco.
        lines += rooms
            .filter { !verdict.contains($0.name) }
            .compactMap { row in row.issue.map { "• \(row.name) — \($0)" } }
        if let climate { lines.append(climate) }
        lines += aiNotes
        if aiPending { lines.append(Self.aiPendingText) }
        return lines.joined(separator: "\n")
    }

    static var aiPendingText: String {
        String(localized: "intent.analyzeHome.aiPending",
               defaultValue: "The AI analysis is still running: results will appear in the app.")
    }
}

extension AppServices {

    /// Stesso percorso di `EnvironmentDashboardView.refreshManual()`, ma senza
    /// view: usabile da un intent lanciato ad app chiusa.
    ///
    /// La risposta è prima di tutto lo stato della casa, deterministico e con
    /// i numeri — la stessa diagnosi delle card della planimetria. L'AI si
    /// aggiunge solo quando ha prodotto qualcosa: per una casa tranquilla il
    /// pre-processore salta la chiamata, e un "analizzate N stanze" da solo
    /// non dice niente. Senza AI configurata si risponde comunque.
    func runOnDemandHomeAnalysis(progress: Progress?) async throws -> HomeAnalysisSummary {
        let runAI = ambientalAIService.canRunEnvironmentalAI

        // Al lancio a freddo Siri aspetta poco: ogni fase ha un tetto, e se lo
        // sfora la risposta parte con quello che c'è mentre il lavoro continua.
        // Il campionamento legge i sensori uno alla volta e, con HomeKit appena
        // svegliato, un accessorio irraggiungibile può fermarlo per secondi.

        // HMHomeManager consegna le case dopo qualche istante.
        for _ in 0..<20 where !homeKit.isReady {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let home = homeKit.currentHome else { throw HomeIntentError.homeUnavailable }

        // Un passo per il campionamento, uno per stanza.
        progress?.totalUnitCount = 1
        progress?.completedUnitCount = 0

        // Una lettura degli ultimi 10 minuti basta: la producono il BGTask e
        // l'apertura dell'app, e rileggere tutto non cambierebbe il verdetto.
        if Self.latestReadingAge(in: sharedModelContainer) > 10 * 60 {
            let container = sharedModelContainer
            _ = await Self.run(within: .seconds(6)) {
                await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
            }
        }

        // Senza HomeState il ViewModel ricostruisce le stanze dall'archivio.
        let environment = EnvironmentViewModel()
        environment.configure(modelContainer: sharedModelContainer)
        let rooms = await environment.reloadFromCoreData()

        progress?.totalUnitCount = Int64(rooms.count + 1)
        progress?.completedUnitCount = 1
        try Task.checkCancellation()

        var aiStillRunning = false
        if runAI {
            ambientalAIService.clearAnalysisGates()
            let ai = ambientalAIService
            let finished = await Self.run(within: .seconds(12)) {
                await ai.analyzeRooms(rooms) { done, total in
                    progress?.completedUnitCount = Int64(done + 1)
                    progress?.localizedAdditionalDescription = String(
                        format: String(localized: "intent.analyzeHome.progressRooms",
                                       defaultValue: "Room %1$d of %2$d"),
                        done, total
                    )
                }
            }
            aiStillRunning = !finished
        }
        progress?.completedUnitCount = progress?.totalUnitCount ?? 0

        guard !rooms.isEmpty else {
            return HomeAnalysisSummary(verdict: String(
                localized: "home.digest.environment.empty",
                defaultValue: "There is not enough environmental data yet."
            ))
        }

        // 1. Verdetto: la stessa diagnosi delle card della planimetria.
        let digest = HomeAssistantDigestService.environmentDigest(rooms: rooms, highlightedRoomName: nil)
        var summary = HomeAnalysisSummary(verdict: digest.message)

        // 2. Il clima interno in numeri, e una riga per stanza (prima quelle da guardare).
        summary.climate = Self.indoorClimateLine(rooms: rooms)
        summary.rooms = rooms
            .map { room in
                let issue = room.sensors
                    .filter { $0.urgency != .normal }
                    .max { $0.urgency < $1.urgency }
                return HomeAnalysisSummary.RoomRow(
                    name: room.roomName,
                    temperature: room.sensors.first { $0.serviceType == .temperature }?.formattedValue,
                    humidity: room.sensors.first { $0.serviceType == .humidity }?.formattedValue,
                    issue: issue.map { "\($0.serviceType.displayName): \($0.formattedValue)" },
                    issueType: issue?.serviceType,
                    urgency: room.worstUrgency
                )
            }
            .sorted {
                if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }

        // 3. L'AI, solo se ha qualcosa da dire.
        var lines: [String] = []
        if runAI {
            let insights = ambientalAIService.insights
                .filter(\.isVisible)
                .sorted { $0.severity > $1.severity }
            for insight in insights.prefix(2) {
                if let action = insight.dedupedNextActions.first(where: { !$0.isTip }) {
                    lines.append(String(
                        format: String(localized: "intent.analyzeHome.aiWithAction",
                                       defaultValue: "AI · %1$@: %2$@ Suggested: %3$@."),
                        insight.roomName, insight.message, action.label
                    ))
                } else {
                    lines.append(String(
                        format: String(localized: "intent.analyzeHome.ai",
                                       defaultValue: "AI · %1$@: %2$@"),
                        insight.roomName, insight.message
                    ))
                }
            }
            // Nella scheda la nota AI sta nella riga della sua stanza: spiega
            // il valore invece di ripeterlo in una sezione a parte.
            for insight in insights {
                guard let index = summary.rooms.firstIndex(where: { $0.name == insight.roomName }),
                      summary.rooms[index].aiNote == nil else { continue }
                let action = insight.dedupedNextActions.first(where: { !$0.isTip })
                summary.rooms[index].aiNote = insight.message + (action.map { " → \($0.label)" } ?? "")
            }
        }

        summary.aiNotes = lines
        summary.aiPending = aiStillRunning
        return summary
    }

    /// Età dell'ultima lettura sensore in archivio; infinito se non ce ne sono.
    private static func latestReadingAge(in container: ModelContainer) -> TimeInterval {
        var descriptor = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\SensorReading.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let latest = try? ModelContext(container).fetch(descriptor).first?.timestamp else {
            return .infinity
        }
        return Date().timeIntervalSince(latest)
    }

    /// Avvia `work` e aspetta al massimo `budget`. Restituisce `true` se ha
    /// finito in tempo; altrimenti il lavoro prosegue da solo e i suoi
    /// risultati arrivano nell'archivio e nell'app quando sono pronti.
    ///
    /// Non è un task group: il gruppo aspetterebbe comunque i figli, e né le
    /// letture HomeKit né le chiamate AI reagiscono alla cancellazione.
    private static func run(within budget: Duration, _ work: @escaping () async -> Void) async -> Bool {
        let completion = CompletionFlag()
        Task {
            await work()
            completion.isDone = true
        }
        let deadline = ContinuousClock.now + budget
        while !completion.isDone, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return completion.isDone
    }
}

/// Segnale di fine lavoro per `AppServices.run(within:_:)` (main actor).
private final class CompletionFlag {
    var isDone = false
}

extension AppServices {

    /// "Inside: 21.4°C on average (Bedroom 19.8°C – Living room 23.1°C) · humidity 52%".
    /// Solo stanze interne: fuori la temperatura è il meteo, non la casa.
    fileprivate static func indoorClimateLine(rooms: [RoomEnvironmentData]) -> String? {
        let indoor = rooms.flatMap(\.sensors).filter { $0.roomType != .outdoor }
        let temperatures = indoor.filter { $0.serviceType == .temperature }
        let humidities = indoor.filter { $0.serviceType == .humidity }
        guard !temperatures.isEmpty else { return nil }

        let unit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        ) ?? .celsius
        let average = temperatures.map(\.currentValue).reduce(0, +) / Double(temperatures.count)

        var line: String
        if temperatures.count > 1,
           let coldest = temperatures.min(by: { $0.currentValue < $1.currentValue }),
           let warmest = temperatures.max(by: { $0.currentValue < $1.currentValue }),
           warmest.currentValue - coldest.currentValue >= 0.5 {
            line = String(
                format: String(localized: "intent.analyzeHome.climateRange",
                               defaultValue: "Inside: %1$@ on average (%2$@ %3$@ – %4$@ %5$@)"),
                unit.format(average),
                coldest.roomName, coldest.formattedValue,
                warmest.roomName, warmest.formattedValue
            )
        } else {
            line = String(
                format: String(localized: "intent.analyzeHome.climate",
                               defaultValue: "Inside: %@ on average"),
                unit.format(average)
            )
        }
        if !humidities.isEmpty {
            let humidity = humidities.map(\.currentValue).reduce(0, +) / Double(humidities.count)
            line += String(
                format: String(localized: "intent.analyzeHome.humidity",
                               defaultValue: " · humidity %.0f%%"),
                humidity
            )
        }
        return line
    }
}

// MARK: - Importa consumi Vimar

/// Porta i dati del contatore Vimar nello storico Energia.
///
/// Con un file (es. da un'automazione Comandi "quando un file viene salvato
/// nella cartella") importa quello; senza, rilegge l'export già ricordato su
/// iCloud Drive. La dedup per timestamp di `HouseMeterImport` rende ripetere
/// l'azione innocuo: nel caso peggiore aggiunge zero giorni.
struct ImportVimarEnergyIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Vimar Energy Data"
    static let description = IntentDescription(
        "Adds the days from a Vimar meter export to the Energy history. Without a file, refreshes the export you imported last time."
    )
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "Vimar Export",
        description: "The .xlsx file exported from Vimar. Leave empty to refresh the remembered export.",
        // .xlsx è conforme a public.spreadsheet; il metadata extractor vuole una costante.
        supportedContentTypes: [.spreadsheet]
    )
    var file: IntentFile?

    @Dependency private var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = services.sharedModelContainer

        if let file {
            let outcome = try HouseMeterImport.importArchive(file.data, modelContainer: container)
            return .result(dialog: "\(Self.message(for: outcome))")
        }

        guard VimarAutoImport.hasRememberedFile else { throw HomeIntentError.noRememberedVimarExport }
        guard let outcome = await VimarAutoImport.importIfChanged(modelContainer: container) else {
            let unchanged = String(localized: "intent.vimar.unchanged",
                                   defaultValue: "The Vimar export hasn't changed since the last import.")
            return .result(dialog: "\(unchanged)")
        }
        return .result(dialog: "\(Self.message(for: outcome))")
    }

    private static func message(for outcome: HouseMeterImport.Outcome) -> String {
        String(
            format: String(localized: "energy.import.result",
                           defaultValue: "%1$d new days imported, %2$d already present."),
            outcome.inserted, outcome.skipped
        )
    }
}

// MARK: - App Shortcuts

nonisolated struct HomeFloorplanAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnalyzeHomeIntent(),
            phrases: [
                "Analizza casa con \(.applicationName)",
                "Analizza la casa con \(.applicationName)",
                "Come sta la casa secondo \(.applicationName)",
                "Analyze my home with \(.applicationName)",
                "Analyze home with \(.applicationName)"
            ],
            shortTitle: "Analyze Home",
            systemImageName: "house.and.flag"
        )

        AppShortcut(
            intent: ImportVimarEnergyIntent(),
            phrases: [
                "Importa consumi Vimar con \(.applicationName)",
                "Aggiorna consumi con \(.applicationName)",
                "Import Vimar energy with \(.applicationName)",
                "Update energy data with \(.applicationName)"
            ],
            shortTitle: "Import Vimar Energy",
            systemImageName: "bolt.horizontal.circle"
        )
    }
}
