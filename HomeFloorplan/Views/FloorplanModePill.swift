import SwiftUI

// MARK: - FloorplanModePill

/// Tab switcher delle modalità.
///
/// Due regole, e la seconda è nata da un errore mio.
///
/// **Il colore vuol dire "guarda qui", mai "sei qui".** Prima ne aveva due —
/// la tinta del modo diceva quale scheda era selezionata, il colore d'allarme
/// quale aveva bisogno di te — e con Controlli tinto di blu accanto a
/// Sicurezza tinta d'arancio l'occhio non poteva sapere quale delle due lo
/// stesse chiamando. La selezione è acromatica; la tinta resta agli allarmi,
/// che sono rari, e quando compare significa qualcosa.
///
/// **La struttura è identica su tutte le schede**: etichetta sopra,
/// sottotitolo sotto, sempre, anche sulle quiete. Avevo provato a nascondere
/// i sottotitoli quieti per abbassare la densità, ed era sbagliato: con
/// Controlli selezionato che mostrava il grigio, Ambiente muto e Sicurezza in
/// arancio, la barra esibiva tre trattamenti diversi su quattro voci e la
/// regola non era deducibile guardandola — sembrava che Ambiente non avesse
/// dati, mentre ce li aveva e se li teneva. La densità si è rivelata il costo
/// minore: una fila di schede si legge come insieme solo se le voci sono
/// confrontabili, e confrontabili vuol dire fatte allo stesso modo.
///
/// Resta quindi UNA sola cosa a variare fra una scheda e l'altra, ed è il
/// colore del sottotitolo: grigio quando è a posto, arancio o rosso quando
/// non lo è.
struct FloorplanModePill: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let context: FloorplanOverlayContext

    /// Segnali vivi per i sottotitoli (v3). `nil` = tab senza sottotitolo.
    var status: FloorplanStatusStripState? = nil

    /// iPhone: font ridotti (11.5/9.5) e segmenti che dividono la larghezza.
    var isCompact: Bool = false

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
            // Stesso principio della chrome alta: un container coordina le
            // superfici vetro, ma i frame per il drag restano fuori dallo stato
            // osservabile per evitare update multipli per frame.
            LiquidGlassContainer(spacing: isCompact ? 16 : 36) {
                HStack(spacing: isCompact ? 4 : 4) {
                    ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                        modeButton(mode, index: index)
                    }
                }
                // Su compact niente padding: non c'è più una capsula interna,
                // l'aria la danno i margini sul platter dello sheet.
                .padding(isCompact ? 0 : 4)
                .modifier(ModeBarSurface(usesGlass: usesGlass,
                                         isCompact: isCompact))
            }
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
            // cambia la geometria a ogni fotogramma della transizione.
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
    private func modeButton(_ mode: FloorplanOverlayMode, index: Int) -> some View {
        let isActive = overlayVM.activeMode == mode
        let alarmColor = status?.alarmColor(for: mode)
        let subtitle = status?.subtitle(for: mode, compact: isCompact)

        Button {
            withAnimation(Self.selectionAnimation) {
                overlayVM.activeMode = mode
            }
        } label: {
            VStack(spacing: isCompact ? 3 : 2) {
                VStack(spacing: isCompact ? 4 : 2) {
                    if isCompact {
                        Image(systemName: mode.pillIcon)
                            .font(.system(size: 19, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                        Text(mode.tabLabel)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    } else {
                        HStack(spacing: 5) {
                            // Solo allarme. Non segna più la selezione: quello
                            // lo fa la capsula, e due segnali per la stessa
                            // cosa sono uno di troppo.
                            if let alarmColor {
                                ModeDot(color: alarmColor,
                                        pulses: status?.pulses(for: mode) == true)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text(mode.tabLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                // "Intelligenza" non deve mai diventare "Intelligen…":
                                // meglio un filo più piccola che tagliata.
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                .foregroundStyle(isActive
                                 ? FloorplanTokens.Text.primary
                                 : Color.primary.opacity(0.75))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: isCompact ? 10.5 : 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(subtitleColor(isActive: isActive,
                                                       mode: mode,
                                                       alarmColor: alarmColor))
                }
            }
            .fixedSize(horizontal: !isCompact, vertical: false)
            .padding(.horizontal, isCompact ? 6 : 13)
            .padding(.vertical, isCompact ? 8 : 6)
            .frame(minWidth: isCompact ? 70 : 44)
            .frame(maxWidth: isCompact ? .infinity : nil)
            .contentShape(Rectangle())
            // VoiceOver (v3): "Etichetta, stato, scheda N di 4".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(mode: mode,
                                                  subtitle: subtitle,
                                                  index: index))
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
        }
        .buttonStyle(.plain)
        .modifier(ModeSelectionHighlight(
            isActive: isActive,
            usesGlass: usesGlass,
            isCompact: isCompact
        ))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.barSpace))
        } action: { frame in
            modeFrames.frames[mode.id] = frame
        }
    }

    private func subtitleColor(isActive: Bool,
                               mode: FloorplanOverlayMode,
                               alarmColor: Color?) -> Color {
        if let alarmColor { return alarmColor }
        if isActive { return FloorplanTokens.Text.primary.opacity(0.85) }
        return FloorplanTokens.Text.tabSubtitleQuiet
    }

    private func accessibilityText(mode: FloorplanOverlayMode,
                                   subtitle: String?,
                                   index: Int) -> String {
        var parts = [mode.label]
        if let subtitle { parts.append(subtitle) }
        parts.append(String(localized: "floorplan.tab.position",
                            defaultValue: "tab \(index + 1) of \(modes.count)"))
        return parts.joined(separator: ", ")
    }
}

private extension FloorplanOverlayMode {
    /// Etichette dei TAB, su entrambe le piattaforme: estese tranne
    /// Intelligenza, dove "AI" batte la parola intera (scelta utente
    /// 27-28/08). VoiceOver e pannelli continuano a dire "Intelligenza".
    var tabLabel: String {
        switch self {
        case .controls:     return label
        case .environment:  return label
        case .security:     return label
        case .intelligence:
            return String(localized: "overlay.mode.intelligence.compact", defaultValue: "AI")
        }
    }
}

// MARK: - ModeDot

/// Pallino del colore del modo; pulsa (scale 1→1.15, ciclo 2s) sulla tab
/// Intelligenza quando c'è una situazione critica. Scala SOLO il pallino,
/// mai superfici.
private struct ModeDot: View {
    let color: Color
    let pulses: Bool

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .onAppear { startIfNeeded() }
            .onChange(of: pulses) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        guard pulses else {
            isPulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            isPulsing = true
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

/// Superficie della tab selezionata: acromatica, senza bordo.
///
/// La tinta è `Color.primary`, cioè il colore del testo, non una tinta in
/// senso cromatico: si adatta a chiaro e scuro e non porta identità. Vetro
/// puro su vetro puro era la scelta più letterale ma la capsula spariva —
/// `.regular` su `.regular` non ha stacco — e una selezione invisibile è un
/// problema peggiore di quello che risolve.
private struct ModeSelectionHighlight: ViewModifier {
    let isActive: Bool
    let usesGlass: Bool
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            if usesGlass, #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(Color.primary.opacity(isCompact ? 0.08 : 0.10)).interactive(), in: Capsule())
            } else {
                content.background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        } else {
            content
        }
    }
}

// MARK: - ModeBarSurface

/// Sfondo della barra.
///
/// In compatto usa `Glass.clear`: la barra vive già dentro uno sheet native e
/// non deve trasformarsi in una lastra grigia. Il colore resta sulle selezioni.
private struct ModeBarSurface: ViewModifier {
    let usesGlass: Bool
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCompact {
            // UNA superficie sola, come Dov'è: i tab poggiano direttamente
            // sul platter dello sheet, che è l'unico sfondo. Mezz'ora di
            // oscillazioni (feedback 26/08) è nata dal contendersi il ruolo
            // fra la capsula dell'isola e il platter: la capsula non esiste
            // più, in NESSUN ramo.
            content
        } else if usesGlass, #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    struct PreviewWrapper: View {
        @State private var vm = FloorplanOverlayViewModel(floorplanID: UUID())
        var body: some View {
            var status = FloorplanStatusStripState()
            status.controlsActiveCount = 13
            status.healthScore = 91
            status.healthLabel = "Ottima"
            status.openingsCount = 2
            status.alarmShortText = "Disins."
            status.situationsCount = 4
            status.criticalCount = 1

            return ZStack {
                Color(red: 0.98, green: 0.94, blue: 0.87).ignoresSafeArea()
                VStack(spacing: 30) {
                    FloorplanModePill(
                        overlayVM: vm,
                        context: FloorplanOverlayContext(
                            hasEnvironmentData: true,
                            hasSecurityDevices: true,
                            hasAIService: true,
                            hasIntelligenceSuggestions: true
                        ),
                        status: status
                    )

                    FloorplanModePill(
                        overlayVM: vm,
                        context: FloorplanOverlayContext(
                            hasEnvironmentData: true,
                            hasSecurityDevices: true,
                            hasAIService: true,
                            hasIntelligenceSuggestions: true
                        ),
                        status: status,
                        isCompact: true
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
    }
    return PreviewWrapper()
}
#endif
