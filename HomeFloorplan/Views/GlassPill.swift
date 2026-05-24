import SwiftUI

struct GlassPill<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

struct GlassCircle<Content: View>: View {
    let content: Content
    let size: CGFloat
    
    init(size: CGFloat = 40, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }
    
    var body: some View {
        content
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

/// Variante più opaca del GlassPill, usata quando serve massima leggibilità
/// del testo sopra contenuti molto variabili (es. titolo sopra una galleria
/// di immagini). Usa .regularMaterial invece di .ultraThinMaterial.
struct GlassTitlePill<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}
