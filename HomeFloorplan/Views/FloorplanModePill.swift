import SwiftUI

// MARK: - FloorplanModePill

/// Tab switcher delle modalità col modello "2d" del design v3: ogni tab è
/// una pill a DUE righe — etichetta stabile sopra, stato vivo sotto — e non
/// esiste una barra di stato separata. Tre stati per tab:
/// - selezionata: fill nel colore del modo (activeBackground/Foreground);
/// - non selezionata ma in allarme: bordo 1.5pt e sottotitolo nel colore
///   d'allarme (arancio Sicurezza, rosso Intelligenza);
/// - quieta: trasparente, sottotitolo #a99f8c.
/// NIENTE badge numerici: lo stato è nel sottotitolo.
struct FloorplanModePill: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let context: FloorplanOverlayContext

    /// Segnali vivi per i sottotitoli (v3). `nil` = tab senza sottotitolo.
    var status: FloorplanStatusStripState? = nil

    /// iPhone: font ridotti (11.5/9.5) e segmenti che dividono la larghezza.
    var isCompact: Bool = false

    /// Larghezza della barra in cui questa pill deve convivere con il titolo a
    /// sinistra e le azioni a destra (solo regular: la pill è centrata in uno
    /// ZStack e non partecipa al flusso orizzontale).
    var availableWidth: CGFloat = .infinity
    var sideChromeWidth: CGFloat = 0

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
                // Un filo d'aria interna: i segmenti non toccano il bordo
                // della capsula (feedback 26/08, "ossigeno" — dosato due volte).
                .padding(isCompact ? 9 : 4)
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
                        Text(mode.compactTabLabel)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    } else {
                        HStack(spacing: 5) {
                            ModeDot(color: mode.accentColor,
                                    pulses: status?.pulses(for: mode) == true && !isActive)
                            Text(mode.label)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                // "Intelligenza" non deve mai diventare "Intelligen…":
                                // meglio un filo più piccola che tagliata.
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                .foregroundStyle(isActive
                                 ? mode.activeForegroundColor
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
            fill: mode.activeBackgroundColor,
            tint: mode.accentColor,
            isCompact: isCompact,
            // Il bordo d'allarme veste il colore DEL TAB (rosa Sicurezza,
            // viola Intelligenza — feedback 26/08): l'urgenza la dice già il
            // sottotitolo col suo semantico; il bordo dice solo "guarda qui".
            // SOLO su regular: su un segmento a tutta larghezza diventava un
            // anellone — nella tab bar compatta parla il sottotitolo colorato.
            alarmBorder: (isActive || alarmColor == nil || isCompact) ? nil : mode.accentColor
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
        if isActive { return mode.activeForegroundColor.opacity(0.85) }
        if let alarmColor { return alarmColor }
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
    var compactTabLabel: String {
        switch self {
        case .controls:
            return String(localized: "overlay.mode.controls.compact", defaultValue: "Ctrl")
        case .environment:
            return String(localized: "overlay.mode.environment.compact", defaultValue: "Amb.")
        case .security:
            return String(localized: "overlay.mode.security.compact", defaultValue: "Sic.")
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

/// Superficie della singola tab 2d: fill pieno nel colore del modo da
/// selezionata, bordo d'allarme da non selezionata, nulla da quieta.
private struct ModeSelectionHighlight: ViewModifier {
    let isActive: Bool
    let usesGlass: Bool
    /// Fill della tab selezionata (activeBackground del modo).
    let fill: Color
    /// Tinta per il ramo vetro.
    let tint: Color
    let isCompact: Bool
    /// Bordo 1.5pt della tab non selezionata in allarme; nil = quieta.
    let alarmBorder: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            if usesGlass, #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(tint.opacity(isCompact ? 0.22 : 0.28)).interactive(), in: Capsule())
            } else {
                content.background(Capsule().fill(fill))
            }
        } else if let alarmBorder {
            content.overlay(Capsule().strokeBorder(alarmBorder, lineWidth: 1.5))
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
            // Lo sheet ora è trasparente (.clear): l'isola È la superficie
            // visibile, quindi la porta con sé in entrambi i rami — vetro
            // .clear (sottile, non lastra) o materiale nel legacy. Il colore
            // resta tutto sulle selezioni.
            if usesGlass, #available(iOS 26.0, *) {
                content.glassEffect(.clear, in: Capsule())
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        } else if usesGlass, #available(iOS 26.0, *) {
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
