import SwiftUI

/// Renderizza un'icona dato un nome che può essere:
/// - SF Symbol di sistema (es. "lightbulb.fill")
/// - asset catalog custom (es. "acc.vacuum")
/// - nome inesistente (mostra un placeholder rosso)
///
/// Priorità: SF Symbol → Asset catalog → Placeholder.
/// Così nel resto dell'app usiamo la stessa API ovunque senza preoccuparci
/// di sapere a priori se il nome è di sistema o custom.
struct AccessoryIconView: View {
    let iconName: String
    
    var body: some View {
        resolvedImage
            .resizable()
            .scaledToFit()
    }
    
    private var resolvedImage: Image {
        if UIImage(systemName: iconName) != nil {
            return Image(systemName: iconName)
        }
        if UIImage(named: iconName) != nil {
            return Image(iconName)
        }
        return Image(systemName: "questionmark.circle")
    }
}


