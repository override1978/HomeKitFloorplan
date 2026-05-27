import SwiftUI

/// Design system per il rendering coerente di accessori HomeKit nell'app.
/// Mappa lo stato visuale (MarkerUrgency) di un adapter in colori semantici
/// usati in modo uniforme su marker, lista e DetailView.
@MainActor
struct AccessoryAppearance {
    let urgency: MarkerUrgency
    
    /// Colore principale dello stato, usato come tint per icone "standalone"
    /// (es. icona nella lista accessori, icona header in DetailView).
    var statusColor: Color {
        switch urgency {
        case .normal:  return .secondary
        case .ok:      return .green
        case .active:  return .yellow
        case .warning: return .orange
        case .alarm:   return .red
        }
    }
    
    /// Stile di riempimento del marker circolare sul floorplan.
    /// `.normal` usa thinMaterial (look "spento/neutro"),
    /// gli altri usano il colore di stato con opacità.
    var markerFill: AnyShapeStyle {
        switch urgency {
        case .normal:  return AnyShapeStyle(.thinMaterial)
        case .ok:      return AnyShapeStyle(Color.green.opacity(0.85))
        case .active:  return AnyShapeStyle(Color.yellow.opacity(0.85))
        case .warning: return AnyShapeStyle(Color.orange.opacity(0.85))
        case .alarm:   return AnyShapeStyle(Color.red.opacity(0.85))
        }
    }
    
    /// Colore icona DENTRO il marker. Bianca su sfondi colorati, primary su neutro.
    var markerIconColor: Color {
        urgency == .normal ? .primary : .white
    }
    
    /// Colore del bordo intorno al marker (solitamente trasparente,
    /// tinto solo per stati ad alta urgency dove serve un boost di visibilità).
    var markerStrokeColor: Color? {
        switch urgency {
        case .alarm:   return .red
        default:       return nil
        }
    }
    
    // MARK: - Factory
    
    /// Crea AccessoryAppearance leggendo l'urgency dall'adapter.
    static func from(_ adapter: (any AccessoryAdapter)?) -> AccessoryAppearance {
        AccessoryAppearance(urgency: adapter?.visualUrgency ?? .normal)
    }
}
