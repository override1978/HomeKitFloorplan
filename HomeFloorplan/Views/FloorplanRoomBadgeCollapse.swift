import SwiftUI

// MARK: - FloorplanRoomBadgeCollapse

/// Collasso a 3 livelli delle etichette stanza (design v3, regola mobile 4):
/// L1 nome+valore quando la stanza è larga, L2 solo valore, L3 pallino 14pt.
/// La regola: l'etichetta non deve superare il 60% della larghezza della
/// stanza A SCHERMO — che cresce con lo zoom, quindi zoomando le etichette
/// si riespandono da sole.
///
/// La larghezza dell'etichetta è STIMATA (≈0.62×corpo per carattere), non
/// misurata: misurare testo in un ForEach di badge riaprirebbe l'anello
/// misura→stato→layout che questo file di viste ha già pagato una volta.
enum FloorplanRoomBadgeCollapse {

    enum Level {
        case full       // nome + valore
        case valueOnly  // solo valore
        case dot        // pallino 14pt
    }

    static func estimatedWidth(text: String, fontSize: CGFloat) -> CGFloat {
        CGFloat(text.count) * fontSize * 0.62 + 20  // padding orizzontale
    }

    /// `roomScreenWidth` = larghezza stanza × effectiveScale (i badge sono
    /// contro-scalati, quindi la loro larghezza resa è quella intrinseca).
    static func level(roomScreenWidth: CGFloat,
                      fullText: String,
                      valueText: String?,
                      fontSize: CGFloat = 11) -> Level {
        let cap = roomScreenWidth * 0.6
        if estimatedWidth(text: fullText, fontSize: fontSize) <= cap { return .full }
        if let valueText,
           estimatedWidth(text: valueText, fontSize: fontSize) <= cap { return .valueOnly }
        return .dot
    }
}

// MARK: - RoomBadgeDot

/// Livello 3: il pallino da 14pt. Bordo bianco e ombra per staccare dal
/// disegno; area di tocco più ampia del visibile.
struct RoomBadgeDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }
}
