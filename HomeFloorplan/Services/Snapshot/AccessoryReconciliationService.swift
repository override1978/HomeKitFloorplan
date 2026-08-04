import Foundation
import SwiftData
import Observation

// MARK: - AccessoryReconciliationService

/// Le domande aperte sull'identità degli accessori, e cosa succede quando si
/// risponde.
///
/// Una domanda nasce a una sola condizione: **è sparito qualcosa che questa app
/// referenzia**. Un accessorio che se ne va senza lasciare marker né storico non
/// ha niente da riparare, e chiederlo produrrebbe una lista che non si svuota
/// mai — che è il modo più sicuro di far smettere di aprirla.
@MainActor
@Observable
final class AccessoryReconciliationService {

    // MARK: - Tipi

    struct Candidate: Identifiable, Sendable {
        let id: UUID
        let name: String
        let roomName: String?
        /// Perché è stato proposto. Si mostra sempre: «stesso numero di serie»
        /// e «stesso modello nella stessa stanza» portano a decisioni diverse.
        let reason: String
        let strength: Strength

        enum Strength: Int, Comparable, Sendable {
            case hardware = 0, strong = 1, plausible = 2
            static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        }
    }

    struct Review: Identifiable, Sendable {
        let id: UUID
        let name: String
        let roomName: String?
        let manufacturer: String?
        let model: String?
        let categoryType: String
        let retiredAt: Date?
        let references: AccessoryReferences
        let candidates: [Candidate]
    }

    private(set) var reviews: [Review] = []

    private let census: AccessoryCensusService
    private let homeKit: HomeKitService
    private let iconOverrides: IconOverrideStore
    private let context: ModelContext

    init(census: AccessoryCensusService,
         homeKit: HomeKitService,
         iconOverrides: IconOverrideStore,
         modelContainer: ModelContainer) {
        self.census = census
        self.homeKit = homeKit
        self.iconOverrides = iconOverrides
        self.context = ModelContext(modelContainer)
    }

    // MARK: - Domande aperte

    func refresh() {
        let rows = census.currentRows
        let decided = decidedPairs()
        let live = rows.filter { !$0.isRetired }

        reviews = rows
            .filter { $0.isRetired && !decided.resolved.contains($0.id) }
            .compactMap { retired -> Review? in
                let references = references(of: retired)
                guard !references.isEmpty else { return nil }
                return Review(
                    id: retired.id,
                    name: retired.name,
                    roomName: retired.roomName,
                    manufacturer: retired.manufacturer,
                    model: retired.model,
                    categoryType: retired.category,
                    retiredAt: retired.retiredAt,
                    references: references,
                    candidates: candidates(for: retired, among: live, rejected: decided.rejected)
                )
            }
            .sorted { ($0.retiredAt ?? .distantPast) > ($1.retiredAt ?? .distantPast) }
    }

    /// Le proposte, dalla più forte alla più debole, al massimo tre.
    ///
    /// Poche e motivate: offrire un candidato per ogni accessorio della casa
    /// sposta la fatica sull'utente e non aggiunge informazione. Chi non trova
    /// il suo qui usa la scelta manuale.
    private func candidates(for retired: KnownAccessory,
                            among live: [KnownAccessory],
                            rejected: Set<String>) -> [Candidate] {
        let retiredSince = retired.retiredAt ?? .distantPast

        return live.compactMap { row -> Candidate? in
            guard !rejected.contains(AccessoryIdentityDecision.pairKey(retired.id, row.id)) else { return nil }

            // Comparso dopo la sparizione: è la coincidenza temporale, il
            // segnale che nessun'altra app può avere perché HomeKit non tiene
            // una data di aggiunta.
            let appearedAfter = !row.isSeeded && row.firstSeenAt >= retiredSince.addingTimeInterval(-3600)

            if let serial = retired.serialNumber, !serial.isEmpty, row.serialNumber == serial {
                return Candidate(id: row.id, name: row.name, roomName: row.roomName,
                                 reason: String(localized: "reconcile.reason.serial",
                                                defaultValue: "same serial number"),
                                 strength: .hardware)
            }
            if row.normalizedName == retired.normalizedName {
                return Candidate(id: row.id, name: row.name, roomName: row.roomName,
                                 reason: appearedAfter
                                    ? String(localized: "reconcile.reason.nameAfter",
                                             defaultValue: "same name, appeared right after")
                                    : String(localized: "reconcile.reason.name", defaultValue: "same name"),
                                 strength: .strong)
            }
            if !retired.stableKey.isEmpty, row.stableKey == retired.stableKey {
                return Candidate(id: row.id, name: row.name, roomName: row.roomName,
                                 reason: appearedAfter
                                    ? String(localized: "reconcile.reason.modelAfter",
                                             defaultValue: "same model in the same room, appeared right after")
                                    : String(localized: "reconcile.reason.model",
                                             defaultValue: "same model in the same room"),
                                 strength: .strong)
            }
            // Senza nessun tratto in comune, la sola coincidenza temporale non
            // basta a proporre: sarebbe un'ipotesi vestita da suggerimento.
            guard appearedAfter, row.roomName == retired.roomName, row.category == retired.category else {
                return nil
            }
            return Candidate(id: row.id, name: row.name, roomName: row.roomName,
                             reason: String(localized: "reconcile.reason.sameRoomAfter",
                                            defaultValue: "appeared in the same room right after"),
                             strength: .plausible)
        }
        .sorted { $0.strength < $1.strength }
        .prefix(3)
        .map { $0 }
    }

    /// Tutti gli accessori vivi scegliibili a mano, **tolti quelli già presi**.
    ///
    /// Un accessorio vivo appartiene al massimo a un'identità: senza questo
    /// filtro due righe finirebbero per rivendicare lo stesso dispositivo e lo
    /// storico si cucirebbe insieme a sproposito — un errore che poi non si
    /// vede.
    func manualTargets() -> [Candidate] {
        let claimed = Set(fetch(FetchDescriptor<AccessoryIdentityDecision>())
            .filter { $0.kind == .same }
            .map(\.liveIdentityID))
        return census.currentRows
            .filter { !$0.isRetired && !claimed.contains($0.id) }
            .sorted { ($0.roomName ?? "", $0.name) < ($1.roomName ?? "", $1.name) }
            .map { Candidate(id: $0.id, name: $0.name, roomName: $0.roomName,
                             reason: "", strength: .plausible) }
    }

    // MARK: - Risposte

    /// «È lo stesso»: i riferimenti locali passano al vivo.
    @discardableResult
    func replace(_ review: Review, with candidateID: UUID, reason: String?) -> IdentityMergeReceipt? {
        let rows = census.currentRows
        guard let retired = rows.first(where: { $0.id == review.id }),
              let live = rows.first(where: { $0.id == candidateID }),
              let from = retired.localUUID,
              let to = live.localUUID
        else { return nil }

        let moved = rewriteReferences(from: from, to: to, newName: live.name)
        let receipt = IdentityMergeReceipt(fromUUID: from, toUUID: to, references: moved)

        context.insert(AccessoryIdentityDecision(
            kind: .same,
            retiredIdentityID: retired.id,
            liveIdentityID: live.id,
            reason: reason,
            deviceName: AppDeviceIdentity.displayName,
            receipt: receipt
        ))
        // La riga ritirata resta come lapide: filtrata dalle domande grazie
        // alla decisione, e disponibile se un giorno la si vuole disfare.
        try? context.save()
        refresh()
        return receipt
    }

    /// «Non è lo stesso»: la coppia non si ripropone più.
    func markDistinct(_ review: Review, from candidateID: UUID, reason: String?) {
        context.insert(AccessoryIdentityDecision(
            kind: .distinct,
            retiredIdentityID: review.id,
            liveIdentityID: candidateID,
            reason: reason,
            deviceName: AppDeviceIdentity.displayName
        ))
        try? context.save()
        refresh()
    }

    /// «Non c'è più e non è stato sostituito»: via i riferimenti e via la riga.
    /// Non resta niente da riproporre, quindi non c'è niente da ricordare.
    func discard(_ review: Review) {
        let rows = census.currentRows
        guard let retired = rows.first(where: { $0.id == review.id }) else { return }
        if let uuid = retired.localUUID { deleteReferences(to: uuid) }
        context.delete(retired)
        try? context.save()
        refresh()
    }

    // MARK: - Riferimenti locali

    /// ⚠️ Nessuna di queste scritture tocca HomeKit. Sono tutte tabelle
    /// dell'app: è ciò che rende questa funzione poco rischiosa.
    func references(of row: KnownAccessory) -> AccessoryReferences {
        guard let uuid = row.localUUID else { return AccessoryReferences() }
        let key = uuid.uuidString
        var found = AccessoryReferences()

        found.markerIDs = fetch(FetchDescriptor<PlacedAccessory>(
            predicate: #Predicate { $0.homeKitAccessoryUUID == uuid })).map(\.id)
        found.accessoryEventCount = fetch(FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.accessoryID == uuid })).count
        found.usageSummaryCount = fetch(FetchDescriptor<AccessoryUsageSummary>(
            predicate: #Predicate { $0.accessoryID == uuid })).count
        found.effectivenessEventCount = fetch(FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.accessoryID == key })).count
        found.isSecurityMonitored = Self.securityMonitoredUUIDs().contains(key)
        found.hasIconOverride = iconOverrides.icon(for: uuid) != nil
        return found
    }

    private func rewriteReferences(from: UUID, to: UUID, newName: String) -> AccessoryReferences {
        let fromKey = from.uuidString
        var moved = AccessoryReferences()

        let markers = fetch(FetchDescriptor<PlacedAccessory>(
            predicate: #Predicate { $0.homeKitAccessoryUUID == from }))
        for marker in markers { marker.homeKitAccessoryUUID = to }
        moved.markerIDs = markers.map(\.id)

        let events = fetch(FetchDescriptor<AccessoryEvent>(predicate: #Predicate { $0.accessoryID == from }))
        for event in events {
            event.accessoryID = to
            event.accessoryName = newName
        }
        moved.accessoryEventCount = events.count

        let summaries = fetch(FetchDescriptor<AccessoryUsageSummary>(
            predicate: #Predicate { $0.accessoryID == from }))
        for summary in summaries {
            summary.accessoryID = to
            summary.accessoryName = newName
        }
        moved.usageSummaryCount = summaries.count

        let effectiveness = fetch(FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.accessoryID == fromKey }))
        for event in effectiveness { event.accessoryID = to.uuidString }
        moved.effectivenessEventCount = effectiveness.count

        var monitored = Self.securityMonitoredUUIDs()
        if monitored.contains(fromKey) {
            monitored.remove(fromKey)
            monitored.insert(to.uuidString)
            Self.setSecurityMonitoredUUIDs(monitored)
            moved.isSecurityMonitored = true
        }

        if let icon = iconOverrides.icon(for: from) {
            iconOverrides.setIcon(icon, for: to)
            iconOverrides.removeIcon(for: from)
            moved.hasIconOverride = true
        }

        try? context.save()
        return moved
    }

    private func deleteReferences(to uuid: UUID) {
        let key = uuid.uuidString
        for marker in fetch(FetchDescriptor<PlacedAccessory>(
            predicate: #Predicate { $0.homeKitAccessoryUUID == uuid })) { context.delete(marker) }
        for event in fetch(FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.accessoryID == uuid })) { context.delete(event) }
        for summary in fetch(FetchDescriptor<AccessoryUsageSummary>(
            predicate: #Predicate { $0.accessoryID == uuid })) { context.delete(summary) }
        for event in fetch(FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.accessoryID == key })) { context.delete(event) }

        var monitored = Self.securityMonitoredUUIDs()
        if monitored.remove(key) != nil { Self.setSecurityMonitoredUUIDs(monitored) }
        iconOverrides.removeIcon(for: uuid)
    }

    // MARK: - Interni

    private func fetch<T>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    private func decidedPairs() -> (resolved: Set<UUID>, rejected: Set<String>) {
        let decisions = fetch(FetchDescriptor<AccessoryIdentityDecision>())
        var resolved: Set<UUID> = []
        var rejected: Set<String> = []
        for decision in decisions {
            switch decision.kind {
            case .same:     resolved.insert(decision.retiredIdentityID)
            case .distinct: rejected.insert(decision.pairKey)
            }
        }
        return (resolved, rejected)
    }

    private static let securityKey = "securityMonitoredUUIDs"

    private static func securityMonitoredUUIDs() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: securityKey) ?? ""
        return Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private static func setSecurityMonitoredUUIDs(_ value: Set<String>) {
        UserDefaults.standard.set(value.sorted().joined(separator: ","), forKey: securityKey)
    }
}
