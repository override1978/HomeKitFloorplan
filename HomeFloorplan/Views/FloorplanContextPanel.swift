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
    /// Sfondo del canvas (dipende dalla planimetria): la colonna lo prosegue,
    /// separata solo da un filo, così il pannello appartiene alla stessa
    /// superficie e non sembra una sheet appoggiata sopra.
    let background: Color
    /// Per il dettaglio clima (novità D).
    var adapterMap: [UUID: any AccessoryAdapter] = [:]

    private var mode: FloorplanOverlayMode { overlayVM.activeMode }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                FloorplanContextDashboardRouter(
                    overlayVM: overlayVM,
                    floorplan: floorplan,
                    environmentViewModel: environmentViewModel,
                    adapterMap: adapterMap
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity)
        // Nessun filo di separazione: la colonna prosegue lo sfondo della
        // planimetria senza confini, e sono le card — superfici piene con
        // ombra — a galleggiare sopra. (Feedback utente del 26/08: il pannello
        // non deve leggersi come una sheet laterale.)
        .background(background.ignoresSafeArea(edges: .vertical))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mode.accentColor)
                .frame(width: 8, height: 8)
            Text(mode.label)
                .font(.headline)
                .foregroundStyle(Color.primary)

            Spacer()

            Button(action: overlayVM.dismissPanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassChromeSurface(in: Circle())
            .accessibilityLabel(String(localized: "floorplan.panel.close",
                                       defaultValue: "Close panel"))
        }
    }
}

// MARK: - FloorplanCompactPanelSheet

/// Contenuto del bottom sheet iPhone (redesign, fase 4): sostituisce il
/// pannello overlay laterale su compact. Due detent — compresso (maniglia +
/// titolo) ed esteso — con la mappa che resta interattiva sotto. Stesso
/// router dei contenuti del pannello docked; stessa regola delle superfici:
/// sfondo = planimetria, card piene che galleggiano.
struct FloorplanCompactPanelSheet: View {

    /// Altezze dei due detent, da design (~92pt compresso, ~46% esteso).
    static let collapsedDetent: PresentationDetent = .height(92)
    static let expandedDetent: PresentationDetent = .fraction(0.46)

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let floorplan: Floorplan
    let environmentViewModel: EnvironmentViewModel
    var adapterMap: [UUID: any AccessoryAdapter] = [:]

    private var mode: FloorplanOverlayMode { overlayVM.activeMode }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(mode.accentColor)
                    .frame(width: 8, height: 8)
                Text(mode.label)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView {
                FloorplanContextDashboardRouter(
                    overlayVM: overlayVM,
                    floorplan: floorplan,
                    environmentViewModel: environmentViewModel,
                    adapterMap: adapterMap
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }
}
