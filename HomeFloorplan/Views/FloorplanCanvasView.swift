import SwiftUI

struct FloorplanCanvasView<OverlayLayer: View, EditLayer: View, MarkerContent: View, EmptyContent: View, OverMarkerLayer: View>: View {
    let image: UIImage
    /// La stessa planimetria in stile scuro, quando esiste.
    let darkImage: UIImage?
    let containerSize: CGSize
    let chrome: FloorplanChromeLayout
    /// La luce che illumina il disegno. `.night` lascia il raster com'è.
    let light: DaylightGround.Light
    /// I fuochi di luce: il sole che entra da un'apertura, le lampade accese.
    let glows: [CircadianGlow]
    let showOverlayLayer: Bool
    let showEditLayer: Bool
    let showMarkers: Bool
    let markerItems: [FloorplanMarkerRenderItem]
    let collisionOffsets: [UUID: CGSize]
    let overlayLayer: (CGSize, CGRect) -> OverlayLayer
    let editLayer: (CGSize, CGRect) -> EditLayer
    let markerContent: (FloorplanMarkerRenderItem, CGRect, CGSize) -> MarkerContent
    let emptyContent: () -> EmptyContent
    /// Layer disegnato SOPRA i marker: per la chrome ancorata alla planimetria
    /// che deve restare tappabile anche dove i marker si addensano (la pill di
    /// compressione della stanza espansa; in futuro le azioni in-place).
    let overMarkerLayer: (CGSize, CGRect) -> OverMarkerLayer

    init(
        image: UIImage,
        darkImage: UIImage? = nil,
        containerSize: CGSize,
        chrome: FloorplanChromeLayout = .legacy,
        light: DaylightGround.Light = .night,
        glows: [CircadianGlow] = [],
        showOverlayLayer: Bool,
        showEditLayer: Bool,
        showMarkers: Bool,
        markerItems: [FloorplanMarkerRenderItem],
        collisionOffsets: [UUID: CGSize],
        @ViewBuilder overlayLayer: @escaping (CGSize, CGRect) -> OverlayLayer,
        @ViewBuilder editLayer: @escaping (CGSize, CGRect) -> EditLayer,
        @ViewBuilder markerContent: @escaping (FloorplanMarkerRenderItem, CGRect, CGSize) -> MarkerContent,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent,
        @ViewBuilder overMarkerLayer: @escaping (CGSize, CGRect) -> OverMarkerLayer = { _, _ in EmptyView() }
    ) {
        self.image = image
        self.darkImage = darkImage
        self.containerSize = containerSize
        self.chrome = chrome
        self.light = light
        self.glows = glows
        self.showOverlayLayer = showOverlayLayer
        self.showEditLayer = showEditLayer
        self.showMarkers = showMarkers
        self.markerItems = markerItems
        self.collisionOffsets = collisionOffsets
        self.overlayLayer = overlayLayer
        self.editLayer = editLayer
        self.markerContent = markerContent
        self.emptyContent = emptyContent
        self.overMarkerLayer = overMarkerLayer
    }

    var body: some View {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: image.size,
            container: containerSize,
            topInset: chrome.topInset,
            bottomInset: chrome.bottomInset
        )

        ZStack(alignment: .topLeading) {
            Color.clear

            // La luce cade sul disegno, non solo attorno.
            //
            // Il raster ha i colori cotti dentro: lasciandolo fermo mentre il
            // fondo si schiarisce diventa un rettangolo scuro su una tovaglia
            // chiara, che è il difetto che si vede per primo. Il trattamento
            // sta qui e non più in alto perché marker, overlay e chrome non
            // devono riceverlo: i loro colori significano qualcosa e devono
            // restare quelli a qualunque ora.
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: rect.width, height: rect.height)

                // La variante scura sopra, in dissolvenza.
                //
                // Due raster incrociati e non uno commutato: fra chiaro e scuro
                // non c'è una regolazione ma due disegni diversi — muri scuri su
                // fondo chiaro, o il contrario — e scambiarli di colpo sarebbe
                // uno scatto proprio dove tutto il resto è un passaggio.
                // Attraversandosi, la planimetria diventa l'altra mentre la
                // luce cala, come una stanza che si spegne.
                if let darkImage {
                    Image(uiImage: darkImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: rect.width, height: rect.height)
                        .opacity(light.darkVariantOpacity)
                }
            }
            .brightness(light.imageBrightness)
            .contrast(light.imageContrast)
            .colorMultiply(light.imageTint)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 1.5), value: light)

            // I fuochi di luce cadono **sul** disegno e sotto tutto il resto.
            //
            // Sopra il raster perché la luce illumina la planimetria, non le sta
            // dietro; sotto marker e chrome perché quelli hanno colori che
            // significano qualcosa e non vanno scaldati. In somma additiva:
            // un velo opaco coprirebbe i tratti sottili dei muri, mentre la
            // luce si aggiunge — che è anche ciò che fa la luce.
            ForEach(Array(glows.enumerated()), id: \.offset) { _, glow in
                RadialGradient(colors: [glow.color.opacity(glow.intensity),
                                        glow.color.opacity(0)],
                               center: glow.centre,
                               startRadius: 0,
                               endRadius: max(rect.width, rect.height) * 0.75)
                    .frame(width: rect.width * 1.5, height: rect.height * 1.5)
                    .position(x: rect.midX, y: rect.midY)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 1.5), value: glows)

            if showOverlayLayer {
                overlayLayer(containerSize, rect)
            }

            if showEditLayer {
                editLayer(containerSize, rect)
            }

            Group {
                if showMarkers {
                    FloorplanMarkerLayer(
                        items: markerItems,
                        imageRect: rect,
                        collisionOffsets: collisionOffsets
                    ) { item, collisionOffset in
                        markerContent(item, rect, collisionOffset)
                    } emptyContent: {
                        emptyContent()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showMarkers)

            overMarkerLayer(containerSize, rect)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}

// MARK: - FloorplanChromeLayout

/// Descrive quali file di chrome flottante esistono sopra la planimetria in
/// questa sessione, e da lì calcola il margine superiore da riservare.
///
/// È il compromesso fra due esigenze che si erano scontrate: il margine deve
/// restare una **costante composta di costanti** (mai una misura a runtime —
/// il loop misura→stato→layout→rimisura è già stato smontato una volta), ma
/// il redesign aggiunge file di chrome che esistono solo in certe
/// configurazioni. La regola resta quella del vecchio commento: il layout non
/// dipende MAI dal modo attivo — cambierebbe la dimensione della planimetria
/// a ogni cambio tab — ma solo da fatti stabili per la sessione (la barra di
/// stato unificata, quando arriverà, è visibile in TUTTI i tab).
struct FloorplanChromeLayout: Equatable {
    /// Barra di stato unificata sotto la top bar (redesign, dalla fase 1).
    /// Presente in tutti i tab, quindi legittimamente parte del margine.
    var hasUnifiedStatusStrip = false

    /// Riga della mode pill su iPhone (redesign, fase 4): su compact la pill
    /// non sta nella barra — è una riga a sé sotto di essa. Dipende dalla
    /// size class, un fatto stabile per la sessione, non dal tab attivo.
    var hasCompactModeRow = false

    /// Tab 2d nella barra su regular (design v3): le pill a due righe alzano
    /// la barra rispetto al margine base tarato su quelle a riga singola.
    var hasTwoRowTabBar = false

    /// Pannello Dov'è + isola in basso (iPhone): la planimetria deve stare
    /// SOPRA il peek del pannello, non finirci sotto (feedback 26/08).
    var hasBottomPane = false

    /// Il nastro della giornata in fondo (iPad): la planimetria gli sta
    /// sopra, come già fa col peek del pannello su iPhone. Senza, il disegno
    /// continua sotto la card e le stanze in basso finiscono coperte.
    var hasDayRibbon = false

    /// Layout dell'app com'è oggi: solo top bar + superfici per-modo già
    /// coperte dal margine base.
    static let legacy = FloorplanChromeLayout()

    /// Altezza riservata alla barra di stato unificata (pill 8×16 di padding
    /// + respiro). Costante nominata, mai misurata. (Non più usata dal v3 —
    /// resta per il contratto del tipo e i suoi test.)
    static let statusStripHeight: CGFloat = 48

    /// Altezza riservata alla riga mode pill compatta (due righe, v3).
    static let compactModeRowHeight: CGFloat = 56

    /// Extra per la barra con tab 2d su regular: la pill cresce di ~una riga
    /// e sotto di lei scorre la fila per-modo (chips, banner).
    static let twoRowTabBarExtraHeight: CGFloat = 32

    /// Spazio riservato in basso a peek del pannello + isola (iPhone).
    static let bottomPaneInset: CGFloat = 132

    /// Spazio riservato al nastro della giornata: la card misurata più il
    /// respiro sotto e sopra.
    static let dayRibbonInset: CGFloat = 163

    var topInset: CGFloat {
        var inset = FloorplanCanvasGeometry.chromeTopInset
        if hasUnifiedStatusStrip { inset += Self.statusStripHeight }
        if hasCompactModeRow { inset += Self.compactModeRowHeight }
        if hasTwoRowTabBar { inset += Self.twoRowTabBarExtraHeight }
        return inset
    }

    /// I due non convivono mai — il nastro sta su regular, il peek su
    /// compact — ma sommarli invece di sceglierne uno sarebbe fragile se un
    /// domani convivessero: il massimo resta corretto in entrambi i casi.
    var bottomInset: CGFloat {
        max(hasBottomPane ? Self.bottomPaneInset : 0,
            hasDayRibbon ? Self.dayRibbonInset : 0)
    }
}

enum FloorplanCanvasGeometry {

    /// Spazio base riservato in alto alla chrome flottante (top bar + le
    /// superfici per-modo che già esistevano: chip filtro Ambiente, pill
    /// antifurto).
    ///
    /// Serve perché in Ambiente e Sicurezza sotto la barra compaiono altre
    /// superfici — chip filtro, pill antifurto — che finivano sopra il disegno.
    /// È una **costante**, non una misura: applicata qui dentro non cambia mai a
    /// runtime, quindi non invalida nulla e non ricrea l'anello che avevamo
    /// appena smontato con `topBarHeight`. È costante anche fra le modalità di
    /// proposito: farla dipendere dalla modalità attiva significherebbe far
    /// cambiare dimensione alla planimetria a ogni cambio, un movimento in più
    /// da guardare per un guadagno nullo.
    ///
    /// Le file di chrome aggiuntive del redesign non si sommano qui: si
    /// dichiarano in `FloorplanChromeLayout`, che compone il margine totale
    /// sempre e solo da costanti.
    ///
    /// Unico numero da ritoccare se il margine base risulta troppo o troppo
    /// poco: la barra da sola misura una sessantina di punti, un banner ne
    /// aggiunge una quarantina.
    static let chromeTopInset: CGFloat = 88

    /// Inscrive l'immagine nel contenitore, riservando `topInset` in alto.
    ///
    /// Il margine è un parametro con valore di default, non un termine che i
    /// chiamanti sommano per conto loro: renderer, marker, overlay, collisioni e
    /// risolutore dei tap passano tutti di qui, quindi lo ereditano senza poter
    /// divergere. È la differenza con `topBarHeight`, che viveva sommato in un
    /// punto e sottratto in un altro. Passare `topInset: 0` isola l'inscrizione
    /// pura, che è come i test la verificano.
    static func imageRect(imageSize: CGSize,
                          container: CGSize,
                          topInset: CGFloat = chromeTopInset,
                          bottomInset: CGFloat = 0) -> CGRect {
        let available = CGSize(width: container.width,
                               height: max(container.height - topInset - bottomInset, 1))
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = available.width / available.height
        var size = available
        if imageAspect > containerAspect {
            size.height = available.width / imageAspect
        } else {
            size.width = available.height * imageAspect
        }
        let origin = CGPoint(
            x: (available.width - size.width) / 2,
            y: topInset + (available.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }
}
