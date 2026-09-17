import SwiftUI

// MARK: - RoomLightGlow

/// Il bagliore che nasce dalle stanze accese.
///
/// È ciò che resta della luce circadiana, ed è la parte che valeva: una casa
/// illuminata di sera non ha un centro di luce — ne ha tanti quante sono le
/// stanze in cui c'è qualcuno. Il resto — il fondo che seguiva il sole, le
/// superfici che ne ereditavano la temperatura, il sole che entrava dal
/// balcone, le due varianti del disegno — è stato tolto: raccontava bene
/// un'idea che alla prova non reggeva, e continuare a calcolarla perché il
/// codice c'era è il modo in cui una schermata diventa pesante senza che
/// nessuno decida di appesantirla.
///
/// Quello che resta non ha più niente di circadiano: non insegue un ciclo, non
/// sa che ora è. Sa solo dove sono accese le luci, e lo mostra.
struct RoomLightGlow: Equatable, Sendable {
    /// Dove nasce, in coordinate normalizzate della planimetria.
    let centre: UnitPoint
    /// Quanto è forte, da 0 a 1.
    let intensity: Double
    /// Quanto è ampio, in frazione della diagonale della planimetria.
    ///
    /// Stretto di proposito: una luce larga metà schermo non somiglia a una
    /// lampada, somiglia a una vignettatura — ed è quella che va a sbattere
    /// contro i bordi. Stretta e più intensa legge come luce e si spegne da
    /// sola prima di qualunque lato.
    let radius: Double
    let color: Color

    /// Un bagliore per ogni stanza con le luci accese.
    ///
    /// Uno per stanza e non uno solo al baricentro di tutte: con le luci accese
    /// in soggiorno e in cucina il baricentro cade nel corridoio in mezzo, dove
    /// non è acceso niente, e il risultato sarebbe un alone largo dove non c'è
    /// nessuna lampada invece di due pozze dove ce ne sono.
    ///
    /// - Parameter onDarkGround: su fondo chiaro non si disegna niente. Prima
    ///   la condizione era la quantità di luce del giorno, calcolata da una
    ///   curva solare; ma la ragione vera non era l'ora — era che un alone
    ///   caldo su una superficie chiara non si vede, e disegnarlo significa
    ///   pagare un gradiente per niente. Il fondo lo sa già di sé.
    nonisolated static func lamps(byRoom rooms: [[UnitPoint]],
                                  onDarkGround: Bool) -> [RoomLightGlow] {
        guard onDarkGround else { return [] }

        return rooms.compactMap { points in
            guard !points.isEmpty else { return nil }
            let centre = UnitPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                   y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            // Cresce col numero di lampade ma satura presto: fra tre e sei luci
            // accese una stanza non è il doppio più luminosa.
            let amount = min(Double(points.count) / 3, 1)
            return RoomLightGlow(centre: centre,
                                 intensity: (0.35 + 0.65 * amount) * 0.30,
                                 radius: 0.16,
                                 color: Color(hue: 0.095, saturation: 0.55, brightness: 1))
        }
    }
}
