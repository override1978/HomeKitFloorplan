import SwiftUI

/// Palette colori del brand, accessibile in modo semantico.
/// Usa questi invece dei nomi diretti dei color set, così se rinominiamo
/// in futuro è un singolo posto da aggiornare.
enum BrandColor {
    static let primary       = Color("BrandPrimary")
    static let secondary     = Color("BrandSecondary")
    static let highlight     = Color("BrandHighlight")
    static let surfaceLight  = Color("BrandSurfaceLight")
    static let launchBg      = Color("LaunchBackground")
    
    /// Gradiente caldo stile Apple Home, da usare in splash, onboarding, hero sections.
    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [highlight, secondary, primary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    /// Gradiente sottile per backgrounds, card, hover (warm ma poco invadente).
    static var subtleGradient: LinearGradient {
        LinearGradient(
            colors: [highlight.opacity(0.08), primary.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
