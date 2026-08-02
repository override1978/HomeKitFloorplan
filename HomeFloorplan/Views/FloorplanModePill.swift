import SwiftUI

// MARK: - FloorplanModePill

/// Bottom-centre floating pill that lets the user switch overlay modes.
/// Only visible when 2+ modes are available; hidden (not removed) otherwise
/// so the layout doesn't shift.
struct FloorplanModePill: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let context: FloorplanOverlayContext

    /// Larghezza della barra in cui questa pill deve convivere con il titolo a
    /// sinistra e le azioni a destra.
    ///
    /// Serve perché la pill vive in uno `ZStack`: è centrata in assoluto e non
    /// partecipa al flusso orizzontale, quindi né lei né l'HStack accanto sanno
    /// dell'altro. Finché c'è spazio non si vede; ruotando l'iPad in verticale
    /// la somma supera la larghezza e le pill si sovrappongono. Senza questo
    /// numero la pill non ha modo di accorgersene — `ViewThatFits` qui non
    /// servirebbe, perché dentro uno ZStack vede sempre tutta la larghezza.
    let availableWidth: CGFloat

    /// Spazio occupato attorno alla pill: bottone sidebar più menu del titolo a
    /// sinistra, azioni a destra, margini esterni. Lo passa la barra, perché
    /// dipende da quanto le azioni si sono già compattate.
    let sideChromeWidth: CGFloat

    /// Larghezza di una voce con la sua etichetta ("Intelligenza" è la più lunga).
    private static let modeWidthWithLabel: CGFloat = 120

    /// Con quattro modalità servono circa 480 punti solo per la pill: sotto
    /// quella soglia le etichette cadono e restano le icone, tranne sulla voce
    /// attiva — che è l'unica che serve leggere, le altre sono bersagli.
    private var showsLabels: Bool {
        availableWidth - sideChromeWidth >= CGFloat(modes.count) * Self.modeWidthWithLabel
    }

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

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

    var body: some View {
        // Collapse when only one mode is available.
        if modes.count > 1 {
            // ⛔️ NIENTE `GlassEffectContainer` attorno a questa barra, e stavolta
            // è una conclusione, non un rinvio.
            //
            // Il container non si limita a disegnare: **riposiziona i propri
            // figli** per far combaciare le forme che fonde. Attorno a questa
            // barra vedeva la superficie e la capsula di selezione come due
            // superfici da unire, tirava insieme le voci, il layout si
            // riaffermava e lui ci riprovava — le due voci centrali si
            // sovrapponevano e tornavano a posto in ciclo continuo. È la stessa
            // proprietà che a luglio faceva sparire quattro badge su sei
            // nell'overlay Ambiente.
            //
            // Era stato rimesso qui per ottenere il morph a goccia della
            // selezione, e in una sola giornata ha prodotto tre difetti: il
            // warning `glassEffect() tried to update multiple times per frame`
            // (che ne aveva già causato la rimozione), il vetro dilatato sopra
            // le azioni della toolbar, e questa oscillazione. Il morph è un
            // dettaglio estetico che non si è mai visto funzionare: non vale il
            // prezzo. La barra e la capsula tinta restano, e stanno bene.
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
                if showsLabels || isActive {
                    Text(mode.label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? mode.accentColor : Color.primary.opacity(0.55))
            .padding(.horizontal, showsLabels ? 15 : 12)
            .padding(.vertical, 7)
            .frame(minWidth: 44)
            .contentShape(Rectangle())
            // L'etichetta accessibile resta anche quando il testo cade, come per
            // le modalità dell'antifurto.
            .accessibilityLabel(mode.label)
        }
        .buttonStyle(.plain)
        .modifier(ModeSelectionHighlight(
            isActive: isActive,
            usesGlass: usesGlass,
            tint: mode.accentColor
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

/// Vetro tinto sulla sola voce attiva.
///
/// Aveva anche `glassEffectID` + `glassEffectTransition(.matchedGeometry)` per
/// far morphare la capsula da una voce all'altra. Sono spariti insieme al
/// container: senza un `GlassEffectContainer` attorno non c'è nulla che possa
/// fondere due forme, quindi restavano configurazione morta che suggeriva un
/// comportamento inesistente.
private struct ModeSelectionHighlight: ViewModifier {
    let isActive: Bool
    let usesGlass: Bool
    /// Colore della modalità. Su fondo piatto il vetro non ha nulla da
    /// rifrangere e degrada a una macchia grigia: la tinta gli restituisce
    /// identità senza dipendere dal contenuto sottostante.
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesGlass, #available(iOS 26.0, *) {
            if isActive {
                content
                    .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: Capsule())
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
                        ),
                        // Larghezza da iPad in orizzontale: la preview mostra la
                        // forma estesa. Abbassandola sotto i ~1040 si vede quella
                        // compatta, che è ciò che compare ruotando in verticale.
                        availableWidth: 1366,
                        sideChromeWidth: 560
                    )
                    .padding(.bottom, 40)
                }
            }
        }
    }
    return PreviewWrapper()
}
#endif
