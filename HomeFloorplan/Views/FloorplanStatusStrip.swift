import SwiftUI
import HomeKit

// MARK: - FloorplanStatusStripState

/// Fotografia dei quattro segnali della barra di stato unificata (redesign,
/// novità B): salute casa, aperture+antifurto, situazioni, temperature.
/// Struct pura: la costruisce l'editor dai propri dati cache-ati/osservabili,
/// la vista la disegna e basta.
struct FloorplanStatusStripState: Equatable {
    /// Media pesata per stanza (0–100); nil se non ci sono accessori.
    var healthScore: Int?
    var healthLabel: String?

    /// Aperture (sensori contatto monitorati risultati aperti) sul piano.
    var openingsCount: Int?
    /// Stato antifurto leggibile ("Antifurto disinserito"); nil senza impianto.
    var alarmModeText: String?

    /// Situazioni attive rilevanti per questo piano.
    var situationsCount: Int?
    /// Quante con severità alta/critica, e la stanza della più grave.
    var criticalCount: Int = 0
    var criticalRoomName: String?

    /// Temperature già formattate con l'unità dell'utente ("25.5°C").
    var indoorText: String?
    var outdoorText: String?

    var hasAnyContent: Bool {
        healthScore != nil || openingsCount != nil
            || situationsCount != nil || indoorText != nil
    }

    /// Badge per la mode pill: Sicurezza = aperture, Intelligenza = situazioni.
    var modeBadgeCounts: [String: Int] {
        var counts: [String: Int] = [:]
        if let openings = openingsCount, openings > 0 {
            counts[FloorplanOverlayMode.security.id] = openings
        }
        if let situations = situationsCount, situations > 0 {
            counts[FloorplanOverlayMode.intelligence.id] = situations
        }
        return counts
    }
}

// MARK: - FloorplanStatusStripBuilder

/// Calcoli dei quattro segnali. Stateless come gli altri controller del
/// floorplan: l'editor lo invoca con i propri riferimenti, niente stato globale.
@MainActor
enum FloorplanStatusStripBuilder {

    /// Media pesata dei punteggi per stanza — la stessa aritmetica di
    /// `AccessoriesViewModel.globalHealthScore` (media dei punteggi di stanza
    /// pesata sul numero di accessori), riprodotta qui sopra l'engine statico
    /// perché il VM la tiene privata dietro `refresh()`.
    /// NON è `AccessoryHealthEngine.score` sull'intera casa: quello somma le
    /// penalità in un solo 0–100 e crolla a zero con una manciata di problemi.
    static func weightedHealthScore(homeKit: HomeKitService) -> Int? {
        let accessories = homeKit.allAccessories
        guard !accessories.isEmpty else { return nil }

        let byRoom = Dictionary(grouping: accessories) { accessory in
            accessory.room?.uniqueIdentifier.uuidString ?? "no-room"
        }
        var weighted = 0.0
        var total = 0
        for (_, roomAccessories) in byRoom {
            let score = AccessoryHealthEngine.score(for: roomAccessories, homeKit: homeKit)
            weighted += Double(score) * Double(roomAccessories.count)
            total += roomAccessories.count
        }
        guard total > 0 else { return nil }
        return Int((weighted / Double(total)).rounded())
    }

    /// Aperture sul piano: sensori contatto MONITORATI (stessa semantica di
    /// `SecurityOverlayView`) fra i marker posati, risultati aperti. Restare
    /// sui marker posati non è solo parità visiva: sono gli unici accessori a
    /// cui l'editor è iscritto per gli aggiornamenti caratteristiche — un
    /// sensore non posato darebbe un conteggio congelato.
    static func openOpeningsCount(floorplan: Floorplan,
                                  adapterMap: [UUID: any AccessoryAdapter],
                                  monitoredIDs: Set<String>) -> Int {
        guard !monitoredIDs.isEmpty else { return 0 }
        var seen = Set<UUID>()
        var count = 0
        for placed in floorplan.accessories {
            let accessoryID = placed.homeKitAccessoryUUID
            guard !seen.contains(accessoryID) else { continue }
            seen.insert(accessoryID)
            guard monitoredIDs.contains(accessoryID.uuidString),
                  let sensor = adapterMap[accessoryID] as? SensorAdapter,
                  sensor.primarySensorKind == .contact,
                  sensor.contactDetected == true else { continue }
            count += 1
        }
        return count
    }

    /// Situazioni attive rilevanti per il piano: stessa pipeline dell'overlay
    /// Intelligenza (rilevanza → risoluzione → aggancio alle stanze del piano).
    static func situationCounts(
        insights: [PersistedHomeInsight],
        rooms: [LinkedRoom]
    ) -> (total: Int, critical: Int, criticalRoomName: String?) {
        guard !rooms.isEmpty else { return (0, 0, nil) }
        let relevant = insights
            .map { $0.toHomeInsight() }
            .filter(IntelligenceOverlayView.isFloorplanRelevant)
        let situations = HomeSituationResolver.resolve(relevant, granularity: .device)

        var total = 0
        var critical = 0
        var criticalRoomName: String?
        var worstSeverity: HomeInsightSeverity = .info
        for situation in situations {
            guard let room = rooms.first(where: {
                IntelligenceOverlayView.matchesRoom(situation.primary, room: $0)
            }) else { continue }
            total += 1
            let severity = situation.primary.severity
            if severity >= .high {
                critical += 1
                if severity >= worstSeverity {
                    worstSeverity = severity
                    criticalRoomName = room.name
                }
            }
        }
        return (total, critical, criticalRoomName)
    }

    /// Media delle temperature interne dai sensori del VM ambiente, formattata
    /// con l'unità scelta dall'utente.
    static func indoorTemperatureText(envVM: EnvironmentViewModel,
                                      unit: TemperatureUnit) -> String? {
        let values = envVM.rooms
            .flatMap(\.sensors)
            .filter { $0.serviceType == .temperature }
            .map(\.currentValue)
        guard !values.isEmpty else { return nil }
        return unit.format(values.reduce(0, +) / Double(values.count))
    }
}

// MARK: - FloorplanStatusStrip

/// La riga di pill sotto la barra superiore, visibile in tutti i tab.
/// Su larghezza regular: pill centrate con titolo+sottotitolo; su compact:
/// chip scorrevoli col solo titolo. Il tap apre il tab corrispondente col
/// pannello già aperto (gestito dal chiamante via `onSelect`).
struct FloorplanStatusStrip: View {
    let state: FloorplanStatusStripState
    let context: FloorplanOverlayContext
    let isCompact: Bool
    let onSelect: (FloorplanOverlayMode) -> Void

    var body: some View {
        if isCompact {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { pills(compact: true) }
                    .padding(.horizontal, 16)
            }
        } else {
            HStack(spacing: 10) { pills(compact: false) }
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func pills(compact: Bool) -> some View {
        if let score = state.healthScore {
            StatusStripPill(
                dotColor: FloorplanTokens.Semantic.ok,
                title: String(localized: "floorplan.strip.health",
                              defaultValue: "Health \(score)%"),
                subtitle: state.healthLabel,
                pulses: false,
                compact: compact,
                isEnabled: FloorplanOverlayMode.environment.isAvailable(in: context)
            ) { onSelect(.environment) }
        }

        if let openings = state.openingsCount {
            StatusStripPill(
                dotColor: openings > 0
                    ? FloorplanTokens.Semantic.warning
                    : FloorplanTokens.Semantic.ok,
                title: String(localized: "floorplan.strip.openings",
                              defaultValue: "\(openings) open"),
                subtitle: state.alarmModeText,
                pulses: false,
                compact: compact,
                isEnabled: FloorplanOverlayMode.security.isAvailable(in: context)
            ) { onSelect(.security) }
        }

        if let situations = state.situationsCount {
            StatusStripPill(
                dotColor: situations > 0
                    ? (state.criticalCount > 0
                        ? FloorplanTokens.Semantic.critical
                        : FloorplanTokens.Semantic.warning)
                    : FloorplanTokens.Semantic.ok,
                title: String(localized: "floorplan.strip.situations",
                              defaultValue: "\(situations) situations"),
                subtitle: situationsSubtitle,
                pulses: state.criticalCount > 0,
                compact: compact,
                isEnabled: true
            ) { onSelect(.intelligence) }
        }

        if let indoor = state.indoorText {
            StatusStripPill(
                dotColor: FloorplanTokens.Text.tertiary,
                title: state.outdoorText.map { "\(indoor) / \($0)" } ?? indoor,
                subtitle: String(localized: "floorplan.strip.tempSubtitle",
                                 defaultValue: "Indoor / Outdoor"),
                pulses: false,
                compact: compact,
                isEnabled: FloorplanOverlayMode.environment.isAvailable(in: context)
            ) { onSelect(.environment) }
        }
    }

    private var situationsSubtitle: String? {
        guard state.criticalCount > 0 else { return nil }
        if let room = state.criticalRoomName {
            return String(localized: "floorplan.strip.critical.room",
                          defaultValue: "\(state.criticalCount) critical · \(room)")
        }
        return String(localized: "floorplan.strip.critical",
                      defaultValue: "\(state.criticalCount) critical")
    }
}

// MARK: - StatusStripPill

private struct StatusStripPill: View {
    let dotColor: Color
    let title: String
    let subtitle: String?
    let pulses: Bool
    let compact: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    // Il pulse scala SOLO il pallino pieno, mai la superficie:
                    // scalare il vetro ne forza il ricampionamento per frame.
                    .scaleEffect(isPulsing ? 1.15 : 1.0)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    if !compact, let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 7 : 6)
            // Il vetro non offre area di hit-test affidabile: la forma
            // esplicita garantisce il tap su tutta la pill.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassChromeSurface(in: Capsule())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: pulses) { _, _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        guard pulses else {
            isPulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}
