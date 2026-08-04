import Foundation
import SwiftData

// MARK: - AccessoryIdentityDecision

/// Cosa ha **risposto l'utente** su una corrispondenza fra due accessori.
///
/// È la parte preziosa della sezione. Il censimento si ricostruisce da HomeKit
/// in qualunque momento e perderlo non è un dramma; questo no: *«questi due sono
/// lo stesso dispositivo»* e *«questi due no»* sono informazioni che esistono
/// solo perché qualcuno le ha guardate.
///
/// Il «no» conta quanto il «sì»: senza registrarlo, la stessa coppia verrebbe
/// riproposta a ogni passata, e una schermata che ripete la stessa domanda dopo
/// tre volte non si apre più.
///
/// La terza risposta possibile — *«non c'è più e non è stato sostituito»* — qui
/// non compare, e non è una dimenticanza: rimuove la riga del censimento e il
/// marker, quindi non resta niente da riproporre e niente da ricordare.
@Model
final class AccessoryIdentityDecision {

    enum Kind: String, Codable, Sendable {
        /// È lo stesso dispositivo: il marker passa al nuovo.
        case same
        /// Non è lo stesso: non riproporre questa coppia.
        case distinct
    }

    @Attribute(.unique) var id: UUID
    var kindRaw: String

    /// La riga ritirata: quella che HomeKit non ha più.
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

    init(kind: Kind,
         retiredIdentityID: UUID,
         liveIdentityID: UUID,
         reason: String?,
         deviceName: String,
         now: Date = Date()) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.retiredIdentityID = retiredIdentityID
        self.liveIdentityID = liveIdentityID
        self.pairKey = Self.pairKey(retiredIdentityID, liveIdentityID)
        self.decidedAt = now
        self.decidedOnDeviceName = deviceName
        self.reason = reason
    }

    static func pairKey(_ first: UUID, _ second: UUID) -> String {
        [first.uuidString, second.uuidString].sorted().joined(separator: "|")
    }
}

extension AccessoryIdentityDecision {
    var kind: Kind { Kind(rawValue: kindRaw) ?? .distinct }
}
