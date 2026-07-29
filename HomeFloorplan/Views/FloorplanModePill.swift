import SwiftUI

// MARK: - FloorplanModePill

/// Bottom-centre floating pill that lets the user switch overlay modes.
/// Only visible when 2+ modes are available; hidden (not removed) otherwise
/// so the layout doesn't shift.
struct FloorplanModePill: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let context: FloorplanOverlayContext

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    /// Namespace condiviso dall'indicatore di selezione: dando lo STESSO id al
    /// solo elemento attivo, il container fa morphare la capsula di vetro da un
    /// tab all'altro invece di farla sparire e riapparire.
    @Namespace private var selectionNamespace

    /// Frame di ogni voce nello spazio della barra: servono SOLO al drag, per
    /// sapere sopra quale modalità si trova il dito.
    ///
    /// Tenuti in una classe e non in `@State` di proposito. Con `@State`, ogni
    /// scrittura invalidava la view: durante l'animazione della capsula i frame
    /// cambiano a ogni fotogramma, quindi si rimisurava e riscriveva in ciclo —
    /// da cui il warning `glassEffect() tried to update multiple times per
    /// frame`. Sono dati per il gesto, non per il rendering, e non devono
    /// partecipare al ciclo di layout.
    @State private var modeFrames = ModeFrameStore()

    private var usesGlass: Bool { isLiquidGlassEnabled && !isLiquidGlassSuppressed }

    private var modes: [FloorplanOverlayMode] {
        overlayVM.availableModes(context: context)
    }

    private static let barSpace = "floorplan.mode.bar"

    /// Unica curva della selezione: tap e drag devono condividerla, altrimenti
    /// il vetro riceve più animazioni concorrenti sullo stesso cambio di stato
    /// e il movimento diventa meccanico. Smorzamento basso = più liquido.
    private static let selectionAnimation: Animation = .spring(response: 0.38,
                                                              dampingFraction: 0.7)
    private static let selectionID = "floorplan.mode.selection"

    var body: some View {
        // Collapse when only one mode is available.
        if modes.count > 1 {
            // NIENTE container qui: la pill vive già dentro il
            // LiquidGlassContainer della top chrome. Annidarne un secondo,
            // per giunta con uno spacing di fusione in conflitto (120 contro
            // 12), faceva rimbalzare gli aggiornamenti tra i due nello stesso
            // frame — da cui `glassEffect() tried to update multiple times per
            // frame`. Il morph della selezione resta: lo gestisce il container
            // esterno, che vede comunque i glassEffectID nel namespace.
            HStack(spacing: 4) {
                ForEach(modes) { mode in
                    modeButton(mode)
                }
            }
            .padding(4)
            .modifier(ModeBarSurface(usesGlass: usesGlass))
            .coordinateSpace(name: Self.barSpace)
            // Scorrere il dito lungo la barra trascina la selezione. La
            // soglia lascia passare i tap ai bottoni: sotto gli 8 punti è
            // un tocco, sopra è un trascinamento.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.barSpace))
                    .onChanged { value in select(at: value.location) }
            )
            .sensoryFeedback(.selection, trigger: overlayVM.activeMode)
            // Solo opacità, niente scala: scalare una superficie di vetro ne
            // cambia la geometria a ogni fotogramma della transizione, e il
            // glassEffect deve rivalutarsi altrettante volte — mentre la
            // capsula di selezione sta già facendo il proprio morph. Verifica
            // dell'ipotesi sul warning `tried to update multiple times per
            // frame`.
            .transition(.opacity)
        }
    }

    /// Attiva la modalità sotto il dito, se diversa da quella corrente.
    private func select(at point: CGPoint) {
        guard let hit = modes.first(where: { mode in
            guard let frame = modeFrames.frames[mode.id] else { return false }
            return point.x >= frame.minX && point.x <= frame.maxX
        }), hit != overlayVM.activeMode else { return }

        withAnimation(Self.selectionAnimation) {
            overlayVM.activeMode = hit
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: FloorplanOverlayMode) -> some View {
        let isActive = overlayVM.activeMode == mode
        Button {
            withAnimation(Self.selectionAnimation) {
                overlayVM.activeMode = mode
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.pillIcon)
                    .font(.system(size: 15, weight: .semibold))
                Text(mode.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isActive ? mode.accentColor : Color.primary.opacity(0.55))
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ModeSelectionHighlight(
            isActive: isActive,
            usesGlass: usesGlass,
            modeID: mode.id,
            tint: mode.accentColor,
            namespace: selectionNamespace
        ))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.barSpace))
        } action: { frame in
            modeFrames.frames[mode.id] = frame
        }
    }

}

// MARK: - ModeFrameStore

/// Contenitore non osservabile per i frame delle voci: scriverci non invalida
/// la view, che è esattamente ciò che serve per dati letti solo dai gesti.
private final class ModeFrameStore {
    var frames: [String: CGRect] = [:]
}

// MARK: - ModeSelectionHighlight

/// Vetro solo sulla voce attiva, con un id **unico per modalità**.
///
/// È la parte che avevo sbagliato: con un id costante SwiftUI vede sempre la
/// stessa forma e non ha nulla da morphare. Dando a ogni voce il proprio id,
/// al cambio di selezione una forma scompare e un'altra compare, e
/// `glassEffectTransition(.matchedGeometry)` le fonde l'una nell'altra — è la
/// deformazione a goccia. Perché avvenga le due devono rientrare nello
/// `spacing` del container, che per questo è molto più largo della barra.
private struct ModeSelectionHighlight: ViewModifier {
    let isActive: Bool
    let usesGlass: Bool
    let modeID: String
    /// Colore della modalità. Su fondo scuro e piatto il vetro non ha nulla da
    /// rifrangere e degrada a una macchia grigia: la tinta gli restituisce
    /// identità senza dipendere dal contenuto sottostante.
    let tint: Color
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesGlass, #available(iOS 26.0, *) {
            if isActive {
                content
                    .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: Capsule())
                    .glassEffectID(modeID, in: namespace)
                    .glassEffectTransition(.matchedGeometry)
            } else {
                content
            }
        } else if isActive {
            content.background(Capsule().fill(Color.primary.opacity(0.10)))
        } else {
            content
        }
    }
}

// MARK: - ModeBarSurface

/// Sfondo della barra.
///
/// Usa `.regular` e NON `.clear`: la planimetria è un'immagine dell'utente, di
/// luminosità sconosciuta, e il tema di sistema può essere l'opposto del suo
/// (iOS scuro su planimetria chiara). `.clear` non stabilisce alcun fondo,
/// quindi `Color.primary` diventava bianco su bianco. `.regular` porta con sé
/// una superficie adattiva e rende le voci leggibili su qualunque sfondo —
/// costa un po' di trasparenza, ma l'alternativa è testo invisibile.
private struct ModeBarSurface: ViewModifier {
    let usesGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesGlass, #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    struct PreviewWrapper: View {
        @State private var vm = FloorplanOverlayViewModel(floorplanID: UUID())
        var body: some View {
            ZStack {
                Color.gray.ignoresSafeArea()
                VStack {
                    Spacer()
                    FloorplanModePill(
                        overlayVM: vm,
                        context: FloorplanOverlayContext(
                            hasEnvironmentData: true,
                            hasSecurityDevices: true,
                            hasAIService: true,
                            hasIntelligenceSuggestions: true
                        )
                    )
                    .padding(.bottom, 40)
                }
            }
        }
    }
    return PreviewWrapper()
}
#endif
