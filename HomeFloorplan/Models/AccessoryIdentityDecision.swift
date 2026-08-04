import Foundation
import SwiftData

// MARK: - AccessoryIdentityDecision

/// Cosa ha **risposto l'utente** su una corrispondenza fra due accessori.
///
/// È la parte preziosa di tutta la sezione. Il censimento si ricostruisce da
/// HomeKit in qualunque momento e perderlo non è un dramma; questo no: *«questi
/// due sono lo stesso dispositivo»* e *«questi due no»* sono informazioni che
/// esistono solo perché qualcuno le ha guardate. Vanno sincronizzate prima
/// ancora degli snapshot.
///
/// Il «no» conta quanto il «sì»: senza registrarlo, la stessa coppia verrebbe
/// riproposta a ogni passata, e una schermata che ripete la stessa domanda dopo
/// tre volte non si apre più.
///
/// La terza risposta possibile — *«non c'è più e non è stato sostituito»* — qui
/// non compare, e non è una dimenticanza: rimuove la riga del censimento e i
/// riferimenti locali, quindi non resta niente da riproporre e non c'è niente da
/// ricordare.
@Model
final class AccessoryIdentityDecision {

    enum Kind: String, Codable, Sendable {
        /// È lo stesso dispositivo: i riferimenti locali passano al nuovo.
        case same
        /// Non è lo stesso: non riproporre questa coppia.
        case distinct
    }

    @Attribute(.unique) var id: UUID
    var kindRaw: String

    /// La riga ritirata — quella che l'app ancora referenzia e che HomeKit non
    /// ha più.
    var retiredIdentityID: UUID
    /// La riga viva: il sostituto accettato, o quello rifiutato.
    var liveIdentityID: UUID

    /// Chiave della coppia, indipendente dall'ordine: serve a ritrovare un «no»
    /// già dato senza scorrere tutta la tabella.
    var pairKey: String

    var decidedAt: Date
    var decidedOnDeviceName: String

    /// Perché era stata proposta — «stesso numero di serie», «stesso modello
    /// nella stessa stanza». Si conserva perché una decisione senza il motivo,
    /// riletta fra sei mesi, non è verificabile.
    var reason: String?

    /// Cosa è stato riscritto, per poterlo disfare. Un abbinamento sbagliato su
    /// un candidato debole è l'errore probabile di questa funzione, e deve
    /// restare reversibile.
    var receiptJSON: Data?

    init(kind: Kind,
         retiredIdentityID: UUID,
         liveIdentityID: UUID,
         reason: String?,
         deviceName: String,
         receipt: IdentityMergeReceipt? = nil,
         now: Date = Date()) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.retiredIdentityID = retiredIdentityID
        self.liveIdentityID = liveIdentityID
        self.pairKey = Self.pairKey(retiredIdentityID, liveIdentityID)
        self.decidedAt = now
        self.decidedOnDeviceName = deviceName
        self.reason = reason
        self.receiptJSON = receipt.flatMap { try? JSONEncoder().encode($0) }
    }

    static func pairKey(_ first: UUID, _ second: UUID) -> String {
        [first.uuidString, second.uuidString].sorted().joined(separator: "|")
    }
}

extension AccessoryIdentityDecision {

    var kind: Kind { Kind(rawValue: kindRaw) ?? .distinct }

    var receipt: IdentityMergeReceipt? {
        guard let receiptJSON else { return nil }
        return try? JSONDecoder().decode(IdentityMergeReceipt.self, from: receiptJSON)
    }
}

// MARK: - Ricevuta di una fusione

/// Cosa ha toccato un «È lo stesso», voce per voce.
///
/// I riferimenti locali puntano all'`uniqueIdentifier` di HomeKit, non alla
/// nostra identità, quindi una fusione li **riscrive** — e una riscrittura senza
/// ricevuta non si annulla. Serve anche a mostrare in anticipo il peso di ciò
/// che si sta per fare, che è l'unica difesa contro un abbinamento sbagliato:
/// un rimappaggio è invisibile, e se è sbagliato lo si scopre fra mesi.
struct IdentityMergeReceipt: Codable, Sendable, Equatable {
    var fromUUID: UUID
    var toUUID: UUID
    /// `PlacedAccessory.id` dei marker spostati.
    var markerIDs: [UUID]
    var accessoryEventCount: Int
    var usageSummaryCount: Int
    var effectivenessEventCount: Int
    var wasSecurityMonitored: Bool
    var movedIconOverride: Bool

    static let empty = IdentityMergeReceipt(
        fromUUID: UUID(), toUUID: UUID(), markerIDs: [],
        accessoryEventCount: 0, usageSummaryCount: 0, effectivenessEventCount: 0,
        wasSecurityMonitored: false, movedIconOverride: false
    )

    /// Vero se la fusione non tocca niente: si può fare senza avvisi.
    var isEmpty: Bool {
        markerIDs.isEmpty && accessoryEventCount == 0 && usageSummaryCount == 0
            && effectivenessEventCount == 0 && !wasSecurityMonitored && !movedIconOverride
    }
}
