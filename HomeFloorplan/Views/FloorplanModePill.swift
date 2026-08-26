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
            // ⛔️ NIENTE `GlassEffectContainer` attorno a questa barra — il
            // container riposiziona i figli per fondere le forme e qui ha già
            // prodotto oscillazioni e il warning `glassEffect() tried to
            // update multiple times per frame`. Storia completa nel log.
            HStack(spacing: 4) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    modeButton(mode, index: index)
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
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    ModeDot(color: mode.accentColor,
                            pulses: status?.pulses(for: mode) == true && !isActive)
                    Text(mode.label)
                        .font(.system(size: isCompact ? 11.5 : 14, weight: .semibold))
                        .lineLimit(1)
                        // "Intelligenza" non deve mai diventare "Intelligen…":
                        // meglio un filo più piccola che tagliata.
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(isActive
                                 ? mode.activeForegroundColor
                                 : Color.primary.opacity(0.75))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: isCompact ? 9.5 : 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(subtitleColor(isActive: isActive,
                                                       mode: mode,
                                                       alarmColor: alarmColor))
                }
            }
            .fixedSize(horizontal: !isCompact, vertical: false)
            .padding(.horizontal, isCompact ? 6 : 13)
            .padding(.vertical, 6)
            .frame(minWidth: 44)
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
            // Il bordo d'allarme veste il colore DEL TAB (rosa Sicurezza,
            // viola Intelligenza — feedback 26/08): l'urgenza la dice già il
            // sottotitolo col suo semantico; il bordo dice solo "guarda qui".
            alarmBorder: (isActive || alarmColor == nil) ? nil : mode.accentColor
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
    /// Bordo 1.5pt della tab non selezionata in allarme; nil = quieta.
    let alarmBorder: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            if usesGlass, #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(tint.opacity(0.28)).interactive(), in: Capsule())
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
