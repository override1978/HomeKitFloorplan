import SwiftUI

/// Splash mostrato all'avvio mentre HomeKit si inizializza.
/// Sfondo a gradiente ispirato all'icona di Apple Home, icona casa centrale bianca.
struct SplashView: View {
    @State private var iconScale: CGFloat = 0.7
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0
    
    var body: some View {
        ZStack {
            BrandColor.heroGradient
                .ignoresSafeArea()
            
            VStack(spacing: 28) {
                // Icona casa grande con sottile glow bianco
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 160, height: 160)
                        .blur(radius: 20)
                    
                    Image(systemName: "house.fill")
                        .font(.system(size: 84, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)
                
                VStack(spacing: 8) {
                    Text("Home Floorplan")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("Controllo HomeKit visuale")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(textOpacity)
            }
        }
        .task {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.5)) {
                textOpacity = 1.0
            }
        }
    }
}

#Preview {
    SplashView()
}
