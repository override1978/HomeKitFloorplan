import SwiftUI

// MARK: - FloorplanContextPanel

/// Floating cards panel for floorplan overlays.
/// A small dismiss button (GlassCircle) anchors to the top-right edge.
struct FloorplanContextPanel<Content: View>: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let title: String
    let accentColor: Color
    let content: Content

    init(
        overlayVM: FloorplanOverlayViewModel,
        title: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.overlayVM = overlayVM
        self.title = title
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Floating cards ────────────────────────────────────────────
            ScrollView {
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .safeAreaPadding(.top, 14)

            // ── Dismiss button — bottom centre ────────────────────────────
            //
            // Resta un bottone e non diventa "tocca fuori per chiudere": il
            // tocco sulla planimetria è già impegnato — `handleBackgroundTap`
            // risolve i tap sulle stanze e piazza i marker — e assegnargli anche
            // la chiusura renderebbe ambiguo ogni tocco fuori dal pannello.
            // Tondo e senza etichetta: la ✕ da sola è un'affordance di chiusura
            // universale, e la scritta "Chiudi" costringeva a una capsula larga
            // in fondo al pannello. 52 punti è un bersaglio comodo — più grande
            // dei 40 della chrome, perché questo è l'unico modo per uscire.
            // `size` è l'area contenuto: con il padding del vetro attorno, 44
            // qui rende un controllo sui 56-60 punti — più generoso della
            // chrome, perché è l'unico modo per chiudere il pannello.
            GlassIconButton(size: 44, action: overlayVM.dismissPanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
            // L'etichetta accessibile prende il posto del testo rimosso: senza,
            // VoiceOver leggerebbe solo "xmark".
            .accessibilityLabel(String(localized: "common.dismiss", defaultValue: "Chiudi"))
            .padding(.bottom, 16)
        }
    }
}

// MARK: - FloorplanContextPanelContainer

/// Wraps `FloorplanContextPanel` with a slide-in animation from the right.
/// No dim backdrop — the panel is transparent so the floorplan stays fully visible.
struct FloorplanContextPanelContainer<Content: View>: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerWidth: CGFloat
    let title: String
    let accentColor: Color
    let content: Content

    init(
        overlayVM: FloorplanOverlayViewModel,
        containerWidth: CGFloat,
        title: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.overlayVM = overlayVM
        self.containerWidth = containerWidth
        self.title = title
        self.accentColor = accentColor
        self.content = content()
    }

    private var panelWidth: CGFloat {
        min(containerWidth * 0.72, 320)
    }

    var body: some View {
        // No ZStack dim layer — panel slides in as a pure overlay
        HStack(spacing: 0) {
            Spacer()
            FloorplanContextPanel(
                overlayVM: overlayVM,
                title: title,
                accentColor: accentColor
            ) {
                content
            }
            .frame(width: panelWidth)
            .offset(x: overlayVM.isPanelVisible ? 0 : panelWidth + 20)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: overlayVM.isPanelVisible)
        }
        .ignoresSafeArea(edges: .vertical)
        .zIndex(100)
    }
}

// MARK: - FloorplanDockedContextPanel

/// Pannello contestuale AFFIANCATO alla mappa (redesign, novità E) —
/// larghezza regular. Non è un overlay: vive come colonna nell'HStack del
/// canvas, così la mappa si riscala e nessuna stanza resta coperta.
///
/// Ha un header proprio (titolo modalità + ✕) invece del bottone di chiusura
/// in fondo dell'overlay compact: da docked il pannello è una colonna
/// persistente, e la chiusura sta dove stanno le chiusure delle colonne.
struct FloorplanDockedContextPanel: View {

    static let width: CGFloat = 340

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let floorplan: Floorplan
    let environmentViewModel: EnvironmentViewModel
    /// Per il dettaglio clima (novità D).
    var adapterMap: [UUID: any AccessoryAdapter] = [:]
    /// Il momento scelto sul nastro, quando il pannello lo sta mostrando.
    var selectedMoment: DayMoment? = nil
    /// Il gesto scelto nella corsia sotto l'asse.
    var selectedGesture: HumanGesture? = nil
    /// Il periodo scelto fra le barre dentro l'asse.
    var selectedSpan: DaySpan? = nil
    /// Fascia riservata alla chrome a piena larghezza (opzione A, 27/08): il
    /// contenuto parte sotto di lei, come la mappa. Il vetro della barra
    /// scorre anche su questa colonna.
    var topInset: CGFloat = 0

    var body: some View {
        // Niente header: il titolo lo dice già il tab attivo e la chiusura
        // sta nel bottone "Chiudi" della barra — ogni cosa una volta sola.
        ScrollView {
            FloorplanContextDashboardRouter(
                overlayVM: overlayVM,
                floorplan: floorplan,
                environmentViewModel: environmentViewModel,
                adapterMap: adapterMap,
                selectedMoment: selectedMoment,
                selectedGesture: selectedGesture,
                selectedSpan: selectedSpan
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .frame(maxHeight: .infinity)
        // NESSUNO sfondo proprio: il pannello è trasparente sul fondo unico
        // che il canvas dipinge per mappa e colonna insieme — solo così le
        // due zone sono davvero la stessa superficie, senza ombre al confine
        // (feedback 27/08). Le card galleggiano, il resto è planimetria.
    }
}

// Lo sheet compatto di sistema non esiste più: su iPhone il pannello è
// FloorplanBottomPane (stile Dov'è), custom di proposito — vedi quel file.
