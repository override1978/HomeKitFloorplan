import SwiftUI
import HomeKit

// MARK: - FloorplanStatusStripState

/// Fotografia dei segnali vivi della planimetria. Nata per la barra di stato
/// separata della v1 del design; dalla v3 (modello "2d", decisione finale)
/// NON esiste più una barra: questi stessi segnali diventano i sottotitoli
/// delle quattro tab e la pill temperatura nell'header. La struct resta la
/// fonte unica; è la resa che è cambiata.
struct FloorplanStatusStripState: Equatable {
    /// Dispositivi accesi sul piano (sottotitolo tab Controlli).
    var controlsActiveCount: Int?

    /// Media pesata per stanza (0–100); nil se non ci sono accessori.
    var healthScore: Int?
    var healthLabel: String?

    /// Aperture (sensori contatto monitorati risultati aperti) sul piano.
    var openingsCount: Int?
    /// Stato antifurto breve ("Disins.", "Totale"…); nil senza impianto.
    var alarmShortText: String?

    /// Situazioni attive rilevanti per questo piano.
    var situationsCount: Int?
    /// Quante con severità alta/critica, e la stanza della più grave.
    var criticalCount: Int = 0
    var criticalRoomName: String?

    /// Temperature già formattate con l'unità dell'utente ("25.5°C").
    var indoorText: String?
    var outdoorText: String?

    // MARK: Rese per le tab 2d (design v3)

    /// Sottotitolo di stato per la tab. `compact` usa le forme brevi da
    /// iPhone ("91%", "2 aperte", "6 · 1 crit").
    func subtitle(for mode: FloorplanOverlayMode, compact: Bool) -> String? {
        switch mode {
        case .controls:
            guard let active = controlsActiveCount else { return nil }
            return String(localized: "floorplan.tab.sub.controls",
                          defaultValue: "\(active) on")
        case .environment:
            guard let score = healthScore else { return nil }
            if compact { return "\(score)%" }
            if let label = healthLabel { return "\(score)% \(label)" }
            return "\(score)%"
        case .security:
            guard let openings = openingsCount else { return nil }
            let base = String(localized: "floorplan.tab.sub.security",
                              defaultValue: "\(openings) open")
            if compact { return base }
            // Lo stato antifurto vive QUI, mai in una riga dedicata (v3:
            // ogni informazione appare una sola volta per schermata).
            if let alarm = alarmShortText { return "\(base) · \(alarm)" }
            return base
        case .intelligence:
            guard let situations = situationsCount else { return nil }
            guard criticalCount > 0 else { return "\(situations)" }
            return compact
                ? "\(situations) · \(criticalCount) crit"
                : String(localized: "floorplan.tab.sub.intelligence",
                         defaultValue: "\(situations) · \(criticalCount) critical")
        }
    }

    /// Colore d'allarme della tab NON selezionata (bordo 1.5pt + sottotitolo):
    /// arancio per Sicurezza con aperture, rosso per Intelligenza con
    /// critiche (arancio se solo anomalie). `nil` = tab quieta.
    func alarmColor(for mode: FloorplanOverlayMode) -> Color? {
        switch mode {
        case .security:
            guard let openings = openingsCount, openings > 0 else { return nil }
            return FloorplanTokens.Semantic.warning
        case .intelligence:
            guard let situations = situationsCount, situations > 0 else { return nil }
            return criticalCount > 0
                ? FloorplanTokens.Semantic.critical
                : FloorplanTokens.Semantic.warning
        case .controls, .environment:
            return nil
        }
    }

    /// Pulse sul pallino della tab Intelligenza quando ci sono situazioni.
    func pulses(for mode: FloorplanOverlayMode) -> Bool {
        mode == .intelligence && criticalCount > 0
    }

    /// Pill temperatura nell'header ("25.5°/25.4°"); nil senza sensori.
    var temperaturePillText: String? {
        guard let indoor = indoorText else { return nil }
        guard let outdoor = outdoorText else { return indoor }
        return "\(indoor)/\(outdoor)"
    }
}

// MARK: - FloorplanStatusStripBuilder

/// Calcoli dei segnali. Stateless come gli altri controller del floorplan.
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

    /// Dispositivi accesi sul piano (un accessorio con più marker conta una
    /// volta) — sottotitolo della tab Controlli.
    static func activeDeviceCount(floorplan: Floorplan,
                                  adapterMap: [UUID: any AccessoryAdapter]) -> Int {
        var seen = Set<UUID>()
        var count = 0
        for placed in floorplan.accessories {
            guard !seen.contains(placed.homeKitAccessoryUUID) else { continue }
            seen.insert(placed.homeKitAccessoryUUID)
            if adapterMap[placed.homeKitAccessoryUUID]?.isOn == true { count += 1 }
        }
        return count
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
