import SwiftUI

struct FloorplanTopBarView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    let size: CGSize
    let floorplan: Floorplan
    let presentationStyle: FloorplanEditorView.PresentationStyle
    let columnVisibility: NavigationSplitViewVisibility
    let pinnedFloorplans: [Floorplan]
    let primaryFloorplanID: String
    let isEditing: Bool
    let overlayVM: FloorplanOverlayViewModel?
    let overlayContext: FloorplanOverlayContext
    /// Segnali della barra di stato unificata; nil finché l'editor non ha dati.
    let statusStrip: FloorplanStatusStripState?
    /// Conteggi per la riga chips del filtro categoria (tab Controlli);
    /// vuota = riga assente.
    let categoryCounts: [FloorplanRoomCluster.CategoryCount]
    let environmentSensorTypes: [SensorServiceType]
    let isCloudKitMaster: Bool
    let smartLightingStatus: SmartLightingFloorplanStatus?
    let securityAdapter: SecuritySystemAdapter?
    let securityActivationDate: Date?
    let onOpenSidebar: () -> Void
    let onDismiss: () -> Void
    let onSelectFloorplan: ((UUID) -> Void)?
    /// Dispositivi con stanza sul piano ma senza marker (fase 6): quando > 0
    /// il menu strumenti offre il posizionamento guidato.
    let unplacedCount: Int
    let onStartPlacement: () -> Void
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void
    let onView3D: () -> Void
    let onShowScenes: () -> Void
    let onToggleEditing: () -> Void
    let onPauseSmartLighting: () -> Void
    let onResumeSmartLighting: () -> Void

    /// Scene e Modifica finiscono nel menu solo quando la barra è stretta.
    ///
    /// Tenerli sempre nel menu costava un tocco in più *sempre*, per risolvere
    /// una collisione che esiste solo in verticale — e questo iPad vive al muro
    /// in orizzontale. Collassare in base allo spazio è anche il comportamento
    /// normale delle toolbar di sistema, quindi non sorprende nessuno.
    ///
    /// La soglia è la somma di ciò che deve stare in riga: titolo e bottone
    /// sidebar (~290), azioni per esteso (~450), la pill con quattro etichette
    /// (~480) e i margini (~40). Dato che ora le azioni di setup sono estratte
    /// occupano più spazio, quindi alzo la soglia per evitare overlap.
    ///
    /// In modalità Controlli la riga porta anche filtro e vista esplosa: due
    /// cerchi da 36 più spaziatura, una cinquantina di punti. La soglia li
    /// somma invece di ignorarli — è lo stesso conto di sopra con un termine in
    /// più, e il termine si paga solo quando quei bottoni ci sono davvero.
    /// Qui sotto è già successo che un controllo cresciuto di una sessantina di
    /// punti finisse sopra la pill delle modalità, centrata: la collisione non
    /// si vede su questo file, si vede sull'iPad.
    private var collapsesActions: Bool {
        size.width < (showsCategoryControls ? 1300 : 1250)
    }

    /// Quando la barra porta i due bottoni dei controlli — filtro e vista
    /// esplosa. Era ripetuta in tre punti; averla in uno solo e' anche cio' che
    /// permette alla soglia qui sopra di sapere quando pagarli.
    private var showsCategoryControls: Bool {
        guard !isEditing, let overlayVM else { return false }
        return overlayVM.activeMode == .controls && categoryCounts.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // La mode pill sta FUORI da questo container, non dentro.
            //
            // Dentro, ereditava lo `spacing: 12` pensato per i controlli della
            // barra, mentre le sue voci distano un centinaio di punti: si
            // chiedeva al vetro di fondersi a 12pt su forme lontane 100, e la
            // deformazione a goccia non poteva avvenire. Da qui la conclusione
            // sbagliata che il morph fosse esclusiva della tab bar di sistema.
            // La pill si porta ora il proprio container, con lo spacing giusto;
            // non essendo più annidato non torna il warning
            // `glassEffect() tried to update multiple times per frame` che
            // aveva motivato la rimozione.
            ZStack {
                // Su iPhone la planimetria è **solo controllo**: niente cambio
                // modalità e niente modifica. La pill delle quattro modalità
                // misura ~480 punti e su 390 finiva sopra al titolo; le
                // dashboard Ambiente/Sicurezza/Intelligenza restano comunque
                // raggiungibili dalla schermata iniziale, dove hanno lo spazio
                // per essere lette.
                if !isEditing, !isCompact, let overlayVM {
                    FloorplanModePill(overlayVM: overlayVM,
                                      context: overlayContext,
                                      status: statusStrip)
                }

                LiquidGlassContainer(spacing: 12) {
                    HStack {
                        HStack(spacing: 10) {
                            leadingNavigationButton

                            FloorplanTitleMenu(
                                currentFloorplan: floorplan,
                                pinnedFloorplans: pinnedFloorplans,
                                primaryFloorplanID: primaryFloorplanID,
                                onOpenSidebar: onOpenSidebar,
                                onSelectFloorplan: onSelectFloorplan
                            )
                        }

                        Spacer()

                        // Niente pill temperatura nell'header: la voleva il
                        // design v3, ma sull'iPad reale collideva con la tab
                        // Intelligenza — non c'è spazio (feedback 26/08). Le
                        // temperature restano nel pannello Ambiente.

                        if !isCompact {
                            // Filtro categoria su iPad (Option A): dietro un bottone singolo,
                            // allineato con il design mobile.
                            if showsCategoryControls, let overlayVM {
                                compactFilterMenu(overlayVM: overlayVM)
                                expandAllButton(overlayVM: overlayVM)
                            }
                            
                            FloorplanTopRightActions(
                                isEditing: isEditing,
                                isOverlayMode: (overlayVM?.activeMode ?? .controls) != .controls,
                                collapsesActions: collapsesActions,
                                isDrawingAvailable: floorplan.drawingDocumentJSON != nil,
                                isPanelVisible: overlayVM?.isPanelVisible ?? false,
                                unplacedCount: unplacedCount,
                                onStartPlacement: onStartPlacement,
                                onShowHelp: onShowHelp,
                                onShowDiagnostics: onShowDiagnostics,
                                onEditDrawing: onEditDrawing,
                                onView3D: onView3D,
                                onShowScenes: onShowScenes,
                                onToggleEditing: onToggleEditing,
                                onTogglePanel: toggleDockedPanel
                            )
                        } else {
                            // Filtro categoria su iPhone: dietro un bottone
                            // singolo (design v3, regola mobile 5 — mai una
                            // riga fissa). Ogni Menu ha la PROPRIA superficie.
                            if showsCategoryControls, let overlayVM {
                                compactFilterMenu(overlayVM: overlayVM)
                                expandAllButton(overlayVM: overlayVM)
                            }

                            // Le due porte verso le altre facce della stessa
                            // casa — l'editor 2D e la 3D — vivono bene sul
                            // telefono. UN solo Menu con la propria superficie:
                            // la regola «mai due Menu su una superficie» regge.
                            Menu {
                                if unplacedCount > 0 {
                                    Button {
                                        onStartPlacement()
                                    } label: {
                                        Label(String(format: String(localized: "placement.menu.start",
                                                                    defaultValue: "Place devices (%d)"),
                                                     unplacedCount),
                                              systemImage: "plus.viewfinder")
                                    }

                                    Divider()
                                }

                                Button {
                                    onEditDrawing()
                                } label: {
                                    Label(String(localized: "floorplan.drawing.edit", defaultValue: "Edit 2D drawing"),
                                          systemImage: "pencil.and.ruler")
                                }
                                .disabled(floorplan.drawingDocumentJSON == nil)

                                Button {
                                    onView3D()
                                } label: {
                                    Label(String(localized: "floorplan.preview3D", defaultValue: "View in 3D"),
                                          systemImage: "cube")
                                }
                                .disabled(floorplan.drawingDocumentJSON == nil)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .semibold))
                                    // `Color.primary` esplicito: dentro Menu lo
                                    // stile gerarchico perde contro il tint.
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 36, height: 36)
                                    .glassChromeSurface(in: Circle())
                            }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.4), value: columnVisibility)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Su iPhone i tab NON stanno più qui: sono l'isola in basso
            // (stile Dov'è), montata dall'editor sopra il pannello a
            // trascinamento. In alto resta solo la barra minima.

            statusBanners

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.35), value: overlayVM?.activeMode)
        .animation(.spring(response: 0.35), value: floorplan.linkedRooms.isEmpty)
        // Questa barra non viene più misurata: nessuno ha bisogno della sua
        // altezza. Era l'unica ragione dell'anello misura → stato → posizione
        // dell'immagine → rilayout → rimisura, con tutta la meccanica di soglie
        // che serviva a smorzarlo.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Il controllo del filtro categoria: sempre la stessa icona tonda da 36
    /// punti, piena quando un filtro è attivo e vuota quando non lo è.
    ///
    /// Ha avuto per poco una forma che si allargava a dire il nome della
    /// categoria, ed era informazione utile — un filtro che nasconde marker
    /// senza dire cosa sta nascondendo si legge come un guasto. Ma cresceva
    /// di una sessantina di punti proprio dove la barra non li ha: il budget
    /// di riga somma già a 1260 contro la propria soglia di 1250, e a
    /// schermo intero andava a sbattere nella pill delle modalità, centrata.
    /// Un controllo che collide è peggio di un controllo laconico.
    ///
    /// Il nome ora lo dice il pannello, che è anche il posto in cui si
    /// sceglie: là c'è spazio per tutte le categorie insieme, e «Tutti» in
    /// cima toglie il filtro.
    ///
    /// Su iPad l'icona apre quel pannello; su iPhone, dove una colonna
    /// laterale non esiste, apre la tendina.
    @ViewBuilder
    private func compactFilterMenu(overlayVM: FloorplanOverlayViewModel) -> some View {
        filterOpener(overlayVM: overlayVM) {
            Image(systemName: overlayVM.categoryFilter != nil
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        // Il vetro sta FUORI dal bottone, con la forma da toccare dentro:
        // «il vetro non offre hit-test affidabile» è scritto due volte in
        // questo progetto, e averlo invertito è già costato un bottone muto.
        .glassChromeSurface(in: Circle())
        .accessibilityLabel(overlayVM.categoryFilter != nil
            ? String(localized: "floorplan.filter.menu.active",
                     defaultValue: "Filter by category, \(overlayVM.categoryFilter?.displayName ?? "")")
            : String(localized: "floorplan.filter.menu",
                     defaultValue: "Filter by category"))
    }

    /// La vista esplosa a portata di un tocco, accanto al filtro.
    ///
    /// La voce nel pannello resta — e' il posto dove si spiega, con la sua
    /// etichetta — ma per un comando che si usa a raffica due tocchi sono
    /// troppi: aprire il pannello e poi scegliere.
    ///
    /// ⚠️ Non e' un terzo filtro, ed e' il rischio di metterlo qui: «Tutti»
    /// toglie il filtro e torna ai cluster per stanza, questo apre ogni marker
    /// di ogni stanza. Per questo porta l'icona delle frecce e non un
    /// pallino, e si riempie quando e' attivo — deve leggersi come un
    /// interruttore di vista, non come una categoria.
    @ViewBuilder
    private func expandAllButton(overlayVM: FloorplanOverlayViewModel) -> some View {
        let isExpanded = overlayVM.areAllRoomsExpanded || overlayVM.expandedRoomID != nil

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if isExpanded {
                    overlayVM.collapseAllRooms()
                } else {
                    overlayVM.expandAllRooms()
                }
            }
        } label: {
            Image(systemName: isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Il vetro fuori dal bottone, la forma da toccare dentro: stessa
        // regola del filtro qui accanto.
        .glassChromeSurface(in: Circle())
        .accessibilityLabel(isExpanded
            ? String(localized: "floorplan.filter.collapseAll", defaultValue: "Close all rooms")
            : String(localized: "floorplan.filter.expandAll", defaultValue: "Show all devices"))
        .accessibilityAddTraits(overlayVM.areAllRoomsExpanded ? [.isSelected] : [])
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isExpanded)
    }

    /// Il gesto d'apertura: pannello su iPad, tendina su iPhone.
    @ViewBuilder
    private func filterOpener<Label: View>(overlayVM: FloorplanOverlayViewModel,
                                           @ViewBuilder label: () -> Label) -> some View {
        if isCompact {
            Menu { filterMenuItems(overlayVM: overlayVM) } label: { label() }
                .menuOrder(.fixed)
        } else {
            Button { toggleFilterPanel(overlayVM) } label: { label() }
                .buttonStyle(.plain)
        }
    }

    /// Apre il pannello sui filtri, o lo chiude se è già lì.
    ///
    /// Scrive le due proprietà e basta, invece di passare per
    /// `closeDetailContent()` / `dismissPanel()`: il primo, in Controlli,
    /// CHIUDE il pannello — l'opposto di quel che serve qui — e la versione
    /// precedente si reggeva sull'assegnazione successiva per disfarlo. Una
    /// riga in meno e nessun effetto da annullare.
    ///
    /// `panelContent = .dashboard` in entrambi i rami: col pannello reduce da
    /// un tap sul nastro il router mostrerebbe ancora quel momento, e l'icona
    /// del filtro aprirebbe qualcosa che coi filtri non c'entra.
    private func toggleFilterPanel(_ vm: FloorplanOverlayViewModel) {
        let alreadyOnFilters = vm.isPanelVisible && vm.panelContent == .dashboard
        withAnimation(.easeInOut(duration: 0.35)) {
            vm.panelContent = .dashboard
            vm.isPanelVisible = !alreadyOnFilters
        }
    }

    /// Voci della tendina, usate solo su iPhone.
    @ViewBuilder
    private func filterMenuItems(overlayVM: FloorplanOverlayViewModel) -> some View {
        Button {
            overlayVM.categoryFilter = nil
        } label: {
            if overlayVM.categoryFilter == nil {
                Label(String(localized: "floorplan.filter.all.plain", defaultValue: "All"),
                      systemImage: "checkmark")
            } else {
                Text(String(localized: "floorplan.filter.all.plain", defaultValue: "All"))
            }
        }
        ForEach(categoryCounts) { count in
            Button {
                overlayVM.categoryFilter =
                    overlayVM.categoryFilter == count.category ? nil : count.category
            } label: {
                if overlayVM.categoryFilter == count.category {
                    Label("\(count.category.displayName) · \(count.total)",
                          systemImage: "checkmark")
                } else {
                    Text("\(count.category.displayName) · \(count.total)")
                }
            }
        }

        // La vista esplosa in una sezione a parte: non è un filtro, è l'unico
        // modo di vedere tutti i marker insieme invece che raggruppati per
        // stanza. Mescolarla alle categorie la farebbe leggere come un'altra
        // riga di «Tutti», che fa un'altra cosa.
        Section {
            let isExpanded = overlayVM.areAllRoomsExpanded || overlayVM.expandedRoomID != nil
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isExpanded {
                        overlayVM.collapseAllRooms()
                    } else {
                        overlayVM.expandAllRooms()
                    }
                }
            } label: {
                Label(isExpanded
                      ? String(localized: "floorplan.filter.collapseAll", defaultValue: "Close all rooms")
                      : String(localized: "floorplan.filter.expandAll", defaultValue: "Show all devices"),
                      systemImage: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    /// Toggle del pannello docked dal bottone "Dettagli / Chiudi" in barra.
    private func toggleDockedPanel() {
        guard let overlayVM else { return }
        if overlayVM.isPanelVisible {
            overlayVM.dismissPanel()
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                overlayVM.isPanelVisible = true
            }
        }
    }

    @ViewBuilder
    private var leadingNavigationButton: some View {
        switch presentationStyle {
        case .splitView:
            if columnVisibility == .detailOnly {
                GlassIconButton(size: 28, action: onOpenSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                }
                // Sola opacità: scalare una superficie di vetro ne cambia la
                // geometria a ogni fotogramma, e il vetro deve rivalutarsi
                // altrettante volte. Stessa scelta già fatta per la mode pill.
                .transition(.opacity)
            }
        case .pushed:
            GlassIconButton(size: 28, action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !isEditing,
           overlayVM?.activeMode == .controls,
           isCloudKitMaster,
           let smartLightingStatus {
            FloorplanSmartLightingStatusPill(
                status: smartLightingStatus,
                onPause: onPauseSmartLighting,
                onResume: onResumeSmartLighting
            )
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        // Filtri sensore Ambiente: riga fissa SOLO su regular. Su iPhone
        // vivono nel pannello Dov'è, sotto il titolo (regola mobile 5).
        if !isEditing, !isCompact, let overlayVM, overlayVM.activeMode == .environment {
            EnvironmentFilterBar(
                overlayVM: overlayVM,
                availableTypes: environmentSensorTypes
            )
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        // La riga AlarmStatusPill non c'è più (design v3): lo stato antifurto
        // vive nel sottotitolo della tab Sicurezza e nella card del pannello —
        // ogni informazione appare UNA volta per schermata.

        if isEditing {
            FloorplanEditModeBanner(onOpenDiagnostics: onShowDiagnostics)
                .padding(.top, 6)
                .transition(.opacity)
        }

        if !isEditing && floorplan.linkedRooms.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(String(localized: "floorplan.editor.banner.noRooms",
                            defaultValue: "No rooms linked — open the 2D editor (✏️) to draw the areas and unlock the Environment layer."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassChromeSurface(in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Superficie della pill Smart Lighting.
///
/// Era rimasta l'ultima della chrome superiore in `.regularMaterial`, con un
/// bordo bianco fisso: in mezzo alle superfici di vetro si notava, ed era anche
/// invisibile su planimetria chiara. Niente `.interactive()`, perché la pill
/// contiene due bottoni e il vetro interattivo ne ruberebbe i tocchi.
private struct SmartLightingPillSurface: ViewModifier {
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(legacyGlassBorderColor(colorScheme), lineWidth: 0.5)
                )
        }
    }
}

struct FloorplanSmartLightingStatusPill: View {
    let status: SmartLightingFloorplanStatus
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(status.state))
                    .font(.subheadline.weight(.semibold))
                Text(statusTitle(status))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if status.state == .active, status.activeCount > 0 {
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(status.activeCount)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(statusColor(status.state))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if status.state == .active || status.isUserPaused {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 16)

                Button {
                    onPause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(status.isUserPaused ? Color.secondary.opacity(0.4) : statusColor(status.state))
                        .frame(width: 44, height: 38)
                        .contentShape(Rectangle())
                }
                .disabled(status.isUserPaused)
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "smartlighting.floorplan.pause", defaultValue: "Pause Smart Lighting"))

                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(status.isUserPaused ? statusColor(status.state) : Color.secondary.opacity(0.4))
                        .frame(width: 44, height: 38)
                        .contentShape(Rectangle())
                        .padding(.trailing, 2)
                }
                .disabled(!status.isUserPaused)
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "smartlighting.floorplan.resume", defaultValue: "Resume Smart Lighting"))
            }
        }
        .modifier(SmartLightingPillSurface())
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }

    private func statusTitle(_ status: SmartLightingFloorplanStatus) -> String {
        switch status.state {
        case .active:
            return String(localized: "smartlighting.floorplan.status.active", defaultValue: "Smart Lighting active")
        case .paused:
            if status.isUserPaused {
                return String(localized: "smartlighting.floorplan.status.paused", defaultValue: "Smart Lighting paused")
            }
            if let nextResumeAt = status.nextResumeAt {
                return String(format: String(localized: "smartlighting.floorplan.status.pausedUntil",
                                             defaultValue: "Smart Lighting paused until %@"),
                              shortTime(nextResumeAt))
            }
            return String(localized: "smartlighting.floorplan.status.paused", defaultValue: "Smart Lighting paused")
        case .disabled:
            return String(localized: "smartlighting.floorplan.status.disabled", defaultValue: "Smart Lighting disabled")
        case .needsAttention:
            return String(format: String(localized: "smartlighting.floorplan.status.issues",
                                         defaultValue: "%d Smart Lighting issues"),
                          status.issueCount)
        }
    }

    private func statusIcon(_ state: SmartLightingFloorplanStatus.State) -> String {
        switch state {
        case .active: return "sparkles"
        case .paused: return "pause.circle.fill"
        case .disabled: return "power.circle"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ state: SmartLightingFloorplanStatus.State) -> Color {
        switch state {
        case .active: return BrandColor.primary
        case .paused: return BrandColor.secondary
        case .disabled: return .secondary
        case .needsAttention: return .orange
        }
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct FloorplanEditModeBanner: View {
    let onOpenDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                // Stessa chiave della voce di menu che ci porta qui: se la
                // porta si chiama «Gestione planimetria», la stanza non può
                // chiamarsi «Modifica planimetria».
                Text(String(localized: "floorplan.manage", defaultValue: "Edit"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "floorplan.edit.banner.subtitle.maintenance", defaultValue: "Drag markers to move them. Tap one to rename, change icon or remove."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            Button {
                onOpenDiagnostics()
            } label: {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "floorplan.status.accessibility", defaultValue: "Floorplan status"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        // La tinta prende il posto del bordo di brand: nel vetro un bordo
        // disegnato a mano stona, mentre la tinta porta lo stesso significato
        // — "sei in modifica" — con il mezzo che il materiale prevede.
        .glassChromeSurface(
            in: Capsule(),
            tint: BrandColor.primary.opacity(0.18),
            legacyBorder: BrandColor.primary.opacity(0.18)
        )
        // FUORI dalla capsula, non dentro. Stando prima della superficie
        // questi venti punti finivano dentro il vetro: la pastiglia nasceva
        // quaranta punti più larga del proprio contenuto e si leggeva come una
        // lastra, mentre il banner gemello del posizionamento — stessa tinta,
        // stessi padding — restava una pastiglia. Era tutta lì la differenza
        // di famiglia fra i due.
        .padding(.horizontal, 20)
    }
}

struct FloorplanTopRightActions: View {
    let isEditing: Bool
    let isOverlayMode: Bool
    /// Vero quando la barra è stretta: Scene e Modifica passano nel menu.
    let collapsesActions: Bool
    let isDrawingAvailable: Bool
    /// Stato del pannello docked, per il bottone "Dettagli ☰ / Chiudi ✕"
    /// che prende il posto delle azioni nelle modalità overlay.
    let isPanelVisible: Bool
    let unplacedCount: Int
    let onStartPlacement: () -> Void
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void
    let onView3D: () -> Void
    let onShowScenes: () -> Void
    let onToggleEditing: () -> Void
    let onTogglePanel: () -> Void

    private var hidesActions: Bool {
        isOverlayMode && !isEditing
    }

    // Cosa entra davvero nella pill, in ordine. Serve a sapere se un divisore
    // ha qualcosa alla propria sinistra: finché «Modifica» c'era sempre, la
    // domanda non si poneva e i divisori erano scritti fissi. Tolto quello,
    // con tutti i dispositivi già posizionati la pill iniziava con una riga
    // verticale sospesa nel vuoto.
    /// Fuori dalla modifica la barra offre la MODALITÀ; dentro, il compito.
    ///
    /// «Posiziona dispositivi (41)» stava fuori, in arancio e in grassetto, ed
    /// era l'unico elemento della riga con un peso suo: un compito travestito
    /// da modalità. Ora fuori c'è «Modifica», della stessa stoffa di «Scene»,
    /// e il posizionamento compare dentro, dove si posiziona.
    private var showsEdit: Bool { !isEditing }
    private var showsPlace: Bool { isEditing && unplacedCount > 0 }
    private var showsScenesInline: Bool { !collapsesActions && !isEditing }
    private var showsDone: Bool { isEditing }
    private var hasLeadingItem: Bool {
        showsEdit || showsPlace || showsScenesInline || showsDone
    }

    var body: some View {
        // Nelle modalità overlay le azioni di editing non hanno senso e prima
        // sparivano del tutto; al loro posto ora sta il toggle del pannello
        // docked (novità E), che è l'unica azione utile in quel contesto.
        if hidesActions {
            panelToggle
                .transition(.opacity)
        } else {
            actionsPill
                .transition(.opacity)
        }
    }

    private var panelToggle: some View {
        Button(action: onTogglePanel) {
            HStack(spacing: 6) {
                Image(systemName: isPanelVisible ? "xmark" : "sidebar.trailing")
                Text(isPanelVisible
                     ? String(localized: "floorplan.panel.close.short", defaultValue: "Close")
                     : String(localized: "floorplan.panel.details", defaultValue: "Details"))
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(Color.primary.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassChromeSurface(in: Capsule())
        .accessibilityLabel(isPanelVisible
            ? String(localized: "floorplan.panel.close", defaultValue: "Close panel")
            : String(localized: "floorplan.panel.details", defaultValue: "Details"))
    }

    private var actionsPill: some View {
        GlassTitlePill {
            HStack(spacing: 0) {
                // Qui restano solo i COMPITI: posizionare ciò che manca, le
                // scene, e l'uscita dalla gestione. La gestione in sé — che è
                // una modalità, non un compito — si apre dal menu del titolo,
                // perché parla di questa planimetria.
                //
                // Il "+" non vive più qui (decisione 28/08): aggiungere
                // dispositivi è compito del flusso guidato. Il picker libero
                // sopravvive dietro le quinte per il posizionamento assistito
                // dalla diagnostica.
                if !hidesActions {
                    
                    if showsEdit {
                        // UN tap, non due.
                        //
                        // Con dei dispositivi da posizionare porta dritto nel
                        // flusso guidato invece di fermarsi in modifica a
                        // offrire un secondo bottone «Posiziona»: il
                        // posizionamento È la manutenzione, quando c'è da
                        // farlo, e il flusso permette già di spostare i marker
                        // posati — «tocca un marker per spostarlo» lo dice la
                        // sua stessa istruzione.
                        //
                        // Accendere ANCHE `isEditing` sarebbe stato il modo
                        // ovvio di fare «tutto insieme», ed è sbagliato:
                        // `exitPlacementOnboarding` non lo spegne, quindi il
                        // bottone «Vai ai Controlli» della schermata finale
                        // avrebbe lasciato l'utente in modifica — cioè non
                        // nei Controlli.
                        Button(action: {
                            if unplacedCount > 0 {
                                onStartPlacement()
                            } else {
                                onToggleEditing()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                // Col conteggio quando c'è da posizionare: il
                                // numero è l'unica cosa che dice, da fuori,
                                // che c'è del lavoro da fare là dentro.
                                // Toglierlo aveva reso la barra uniforme al
                                // prezzo di nascondere quarantuno dispositivi
                                // fuori dalla mappa.
                                Text(unplacedCount > 0
                                     ? String(format: String(localized: "floorplan.manage.count",
                                                             defaultValue: "Edit (%d)"),
                                              unplacedCount)
                                     : String(localized: "floorplan.manage", defaultValue: "Edit"))
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Il compito vive DENTRO la modalità: se sei entrato a
                    // sistemare la planimetria, i dispositivi ancora fuori
                    // dalla mappa sono esattamente ciò che devi vedere.
                    if showsPlace {
                        Divider().frame(height: 20)

                        Button(action: onStartPlacement) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.subheadline.weight(.bold))
                                Text(String(format: String(localized: "placement.menu.start",
                                                           defaultValue: "Place devices (%d)"),
                                            unplacedCount))
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(BrandColor.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                        if showsScenesInline {
                            if showsEdit || showsPlace {
                                Divider().frame(height: 20)
                            }

                            Button {
                                onShowScenes()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.rectangle.on.rectangle")
                                    Text(String(localized: "scenes.title", defaultValue: "Scenes"))
                                }
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .accessibilityLabel(String(localized: "scenes.title", defaultValue: "Scenes"))
                        }

                    // "Fatto" resta SEMPRE visibile in modifica: l'uscita da una modalità non si nasconde.
                    if showsDone {
                        if showsPlace {
                            Divider().frame(height: 20)
                        }

                        Button {
                            onToggleEditing()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                Text(String(localized: "common.done", defaultValue: "Done"))
                            }
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(BrandColor.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if hasLeadingItem {
                        Divider().frame(height: 20)
                    }

                    // Menu ⋯ ora contiene solo Strumenti/Aiuto secondari (Diagnostica, Aiuto, Editor 2D, 3D)
                    FloorplanToolsMenu(
                        isDrawingAvailable: isDrawingAvailable,
                        showsScenes: collapsesActions && !isEditing,
                        unplacedCount: unplacedCount,
                        onShowHelp: onShowHelp,
                        onShowDiagnostics: onShowDiagnostics,
                        onEditDrawing: onEditDrawing,
                        onView3D: onView3D,
                        onShowScenes: onShowScenes
                    )
                }
            }
        }
    }
}

struct FloorplanToolsMenu: View {
    let isDrawingAvailable: Bool
    let showsScenes: Bool
    let unplacedCount: Int
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void
    let onView3D: () -> Void
    let onShowScenes: () -> Void

    var body: some View {
        Menu {
            if showsScenes {
                Button {
                    onShowScenes()
                } label: {
                    Label(String(localized: "scenes.title", defaultValue: "Scenes"),
                          systemImage: "play.rectangle.on.rectangle")
                }

                Divider()
            }

            // Aiuto e Diagnostica non stanno più qui: il menu resta alle
            // porte verso le altre facce della stessa casa — il disegno 2D e
            // la 3D — più le Scene quando la barra è stretta. La diagnostica
            // ha comunque il proprio bottone nel banner della modifica, che è
            // il momento in cui serve.

            Button {
                onEditDrawing()
            } label: {
                Label(String(localized: "floorplan.drawing.edit", defaultValue: "Edit 2D drawing"), systemImage: "pencil.and.ruler")
            }
            .disabled(!isDrawingAvailable)

            Button {
                onView3D()
            } label: {
                Label(String(localized: "floorplan.preview3D", defaultValue: "View in 3D"),
                      systemImage: "cube")
            }
            .disabled(!isDrawingAvailable)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "floorplan.tools.open", defaultValue: "Floorplan tools"))
        .help(String(localized: "floorplan.tools.open", defaultValue: "Floorplan tools"))
    }
}

struct FloorplanTitleMenu: View {
    let currentFloorplan: Floorplan
    let pinnedFloorplans: [Floorplan]
    let primaryFloorplanID: String
    let onOpenSidebar: () -> Void
    let onSelectFloorplan: ((UUID) -> Void)?

    var body: some View {
        Menu {
            if pinnedFloorplans.isEmpty {
                Button {
                    onOpenSidebar()
                } label: {
                    Label(String(localized: "sidebar.open", defaultValue: "Open sidebar"), systemImage: "sidebar.left")
                }
            } else {
                Section(String(localized: "floorplan.quickAccess", defaultValue: "Quick Access")) {
                    ForEach(pinnedFloorplans) { item in
                        Button {
                            guard item.id != currentFloorplan.id else { return }
                            onSelectFloorplan?(item.id)
                        } label: {
                            Label {
                                HStack {
                                    Text(item.name)
                                    if item.id == currentFloorplan.id {
                                        Text(String(localized: "floorplan.current", defaultValue: "Current"))
                                    }
                                }
                            } icon: {
                                Image(systemName: titleMenuIcon(for: item))
                            }
                        }
                        .disabled(item.id == currentFloorplan.id || onSelectFloorplan == nil)
                    }
                }

                Button {
                    onOpenSidebar()
                } label: {
                    Label(String(localized: "sidebar.show", defaultValue: "Show sidebar"), systemImage: "sidebar.left")
                }
            }
        } label: {
            GlassTitlePill {
                HStack(spacing: 8) {
                    Text(currentFloorplan.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    private func titleMenuIcon(for item: Floorplan) -> String {
        if item.id == currentFloorplan.id {
            return "checkmark.circle.fill"
        }
        if item.id.uuidString == primaryFloorplanID {
            return "star.square.fill"
        }
        return "pin.circle.fill"
    }
}
