import Foundation
import SwiftData
import Observation

// MARK: - AccessoryReconciliationService

/// Risolve gli accessori quando la casa cambia.
///
/// Il censimento dice chi c'era. Quando qualcosa sparisce, questo servizio lo
/// mette davanti all'utente con i possibili sostituti, e la risposta diventa una
/// riga di mappatura: da lì in poi l'identità è risolta.
///
/// L'unica scrittura che comporta è il **marker sulla planimetria**, che è il
/// solo posto dove l'UUID di HomeKit è inciso a mano da qualcuno. Tutto il resto
/// dell'app non ha bisogno di essere toccato.
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
        /// Quanti marker puntano ancora a questo accessorio. Zero è normale e
        /// non toglie la domanda: dice solo che risolverla non sposta niente.
        let markerCount: Int
        let candidates: [Candidate]
    }

    private(set) var reviews: [Review] = []

    private let census: AccessoryCensusService
    private let context: ModelContext

    init(census: AccessoryCensusService, modelContainer: ModelContainer) {
        self.census = census
        self.context = ModelContext(modelContainer)
    }

    // MARK: - Cosa c'è da risolvere

    func refresh() {
        let rows = census.currentRows
        let decided = decidedPairs()
        let live = rows.filter { !$0.isRetired }

        reviews = rows
            .filter { $0.isRetired && !decided.resolved.contains($0.id) }
            .map { retired in
                Review(
                    id: retired.id,
                    name: retired.name,
                    roomName: retired.roomName,
                    manufacturer: retired.manufacturer,
                    model: retired.model,
                    categoryType: retired.category,
                    retiredAt: retired.retiredAt,
                    markerCount: markers(of: retired).count,
                    candidates: candidates(for: retired, among: live, rejected: decided.rejected)
                )
            }
            .sorted { ($0.retiredAt ?? .distantPast) > ($1.retiredAt ?? .distantPast) }
    }

    /// Le proposte, dalla più forte alla più debole, al massimo tre.
    ///
    /// Poche e motivate: offrire un candidato per ogni accessorio della casa
    /// sposta la fatica sull'utente senza aggiungere informazione. Chi non trova
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
    /// filtro due righe finirebbero per rivendicare lo stesso dispositivo.
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

    /// «È lo stesso»: i marker passano al vivo e la coppia è risolta.
    func replace(_ review: Review, with candidateID: UUID, reason: String?) {
        let rows = census.currentRows
        guard let retired = rows.first(where: { $0.id == review.id }),
              let live = rows.first(where: { $0.id == candidateID }),
              let to = live.localUUID
        else { return }

        for marker in markers(of: retired) { marker.homeKitAccessoryUUID = to }

        context.insert(AccessoryIdentityDecision(
            kind: .same,
            retiredIdentityID: retired.id,
            liveIdentityID: live.id,
            reason: reason,
            deviceName: AppDeviceIdentity.displayName
        ))
        try? context.save()
        refresh()
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

    /// «Non c'è più e non è stato sostituito»: via i marker e via la riga.
    func discard(_ review: Review) {
        let rows = census.currentRows
        guard let retired = rows.first(where: { $0.id == review.id }) else { return }
        for marker in markers(of: retired) { context.delete(marker) }
        context.delete(retired)
        try? context.save()
        refresh()
    }

    // MARK: - Interni

    /// I marker sono l'unico posto dell'app dove l'UUID di HomeKit è scritto a
    /// mano da qualcuno, quindi l'unico che una risoluzione deve aggiornare.
    private func markers(of row: KnownAccessory) -> [PlacedAccessory] {
        guard let uuid = row.localUUID else { return [] }
        return fetch(FetchDescriptor<PlacedAccessory>(
            predicate: #Predicate { $0.homeKitAccessoryUUID == uuid }))
    }

    private func fetch<T>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    private func decidedPairs() -> (resolved: Set<UUID>, rejected: Set<String>) {
        var resolved: Set<UUID> = []
        var rejected: Set<String> = []
        for decision in fetch(FetchDescriptor<AccessoryIdentityDecision>()) {
            switch decision.kind {
            case .same:     resolved.insert(decision.retiredIdentityID)
            case .distinct: rejected.insert(decision.pairKey)
            }
        }
        return (resolved, rejected)
    }
}
