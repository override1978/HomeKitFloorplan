import SwiftUI

// MARK: - RoomSectionView
//
// Card stanza redesignata — filosofia Apple Health:
// la risposta alla domanda "questa stanza sta bene?" è IMMEDIATA e visiva,
// senza dover leggere numeri.
//
// COLLASSATA (default):
//   • Icona stanza + nome + health score (cerchio colore) + badge urgency
//   • Riga di micro-indicatori colorati (un dot per sensore — verde/arancio/rosso)
//   • Nessun numero esposto — solo stato
//
// ESPANSA (tap):
//   • Header invariato
//   • Riga barra-progresso per ogni sensore (nome + valore + barra colorata)
//   • AI insight inline (se presente) con azioni rapide
//
// Design rules:
//   - Altezza collassata stabile: non dipende dal numero di sensori (max 1 riga dot)
//   - Bordo colorato solo se c'è urgency — card normale è neutra
//   - Icona stanza SEMPRE nel cerchio colorato (accentColor.opacity(0.12))
//   - Health score come cerchio di progresso compatto a destra dell'header

struct RoomSectionView: View {

    let room: RoomEnvironmentData
    let onSensorTap: (SensorData) -> Void
    var aiInsights: [AmbientalAIInsight] = []
    var onDismissInsight: ((AmbientalAIInsight, DismissalReason) -> Void)? = nil
    var onExecuteAction: ((AINextAction, AmbientalAIInsight) async -> Bool)? = nil
    var onReviewAutomation: ((AutomationProposal, AmbientalAIInsight) -> Void)? = nil

    @State private var isExpanded = false

    // Score 0-1 pesato della stanza (stesso algoritmo del globale)
    private var roomScore: Double {
        let sensors = room.sensors
        guard !sensors.isEmpty else { return 1.0 }
        var ws = 0.0; var tw = 0.0
        for s in sensors {
            let w = s.serviceType.qualityWeight
            let sc: Double
            switch s.urgency {
            case .normal:  sc = 1.0
            case .warning: sc = 0.4
            case .danger:  sc = 0.0
            }
            ws += w * sc; tw += w
        }
        return tw > 0 ? ws / tw : 1.0
    }

    private var scoreColor: Color {
        switch roomScore {
        case 0.85...1.0:  return .green
        case 0.60..<0.85: return Color(red: 0.55, green: 0.80, blue: 0.20) // chartreuse
        case 0.35..<0.60: return .orange
        default:           return .red
        }
    }

    private var accentColor: Color {
        switch room.worstUrgency {
        case .danger:  return .red
        case .warning: return .orange
        case .normal:  return BrandColor.primary
        }
    }

    private var hasAIInsight: Bool { !aiInsights.isEmpty }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header (sempre visibile) ──────────────────────────────
            header
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                }

            // ── Contenuto adattivo ────────────────────────────────────
            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)
                expandedBody
            } else {
                collapsedIndicators
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            room.worstUrgency == .normal
                                ? Color(.separator).opacity(0.20)
                                : accentColor.opacity(0.40),
                            lineWidth: room.worstUrgency == .normal ? 0.5 : 1.5
                        )
                )
        )
        .shadow(
            color: room.worstUrgency == .normal
                ? Color.black.opacity(0.05)
                : accentColor.opacity(0.08),
            radius: 8, x: 0, y: 3
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {

            // Icona stanza
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.10))
                    .frame(width: 42, height: 42)
                Image(systemName: roomIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            // Nome + sottotitolo
            VStack(alignment: .leading, spacing: 2) {
                Text(room.roomName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(room.sensors.count == 1
                         ? String(localized: "environment.room.sensorCount.one", defaultValue: "1 sensor")
                         : String(localized: "environment.room.sensorCount.many", defaultValue: "\(room.sensors.count) sensors"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Badge AI se c'è insight attivo
                    if hasAIInsight {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            // Score cerchio + chevron
            HStack(spacing: 10) {
                RoomScoreRing(score: roomScore, color: scoreColor)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Collassato: micro-indicatori (dot colorati)

    private var collapsedIndicators: some View {
        HStack(spacing: 10) {
            ForEach(room.sensors) { sensor in
                SensorMicroIndicator(sensor: sensor)
            }
            Spacer()
            // Label urgency compatta solo se c'è problema
            if room.worstUrgency != .normal {
                Label(room.worstUrgency.label, systemImage: room.worstUrgency.sfSymbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    // MARK: - Espanso: barre sensore + AI insight

    private var expandedBody: some View {
        VStack(spacing: 0) {

            // Sensori come barre metriche
            ForEach(Array(room.sensors.enumerated()), id: \.element.id) { idx, sensor in
                Button { onSensorTap(sensor) } label: {
                    SensorBarRow(sensor: sensor)
                }
                .buttonStyle(.plain)

                if idx < room.sensors.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }

            // AI insight — mostrato solo in espanso, dopo i sensori
            if hasAIInsight {
                Divider()
                    .padding(.horizontal, 0)
                    .padding(.top, 4)

                ForEach(aiInsights) { insight in
                    AIInsightRow(
                        insight: insight,
                        fallbackAccessoryID: room.sensors.first?.accessoryUUIDs.first,
                        onDismiss: { reason in onDismissInsight?(insight, reason) },
                        onExecuteAction: { action in
                            guard let onExecuteAction else { return false }
                            return await onExecuteAction(action, insight)
                        },
                        onReviewAutomation: { proposal in onReviewAutomation?(proposal, insight) }
                    )
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Icona stanza (euristica nome)

    private var roomIcon: String {
        let n = room.roomName.lowercased()
        if n.contains("cucina") || n.contains("kitchen")                                    { return "frying.pan" }
        if n.contains("bagno") || n.contains("bathroom") || n.contains("toilet")           { return "shower" }
        if n.contains("camera") || n.contains("letto") || n.contains("bedroom")            { return "bed.double" }
        if n.contains("soggiorno") || n.contains("salotto") || n.contains("living")        { return "sofa" }
        if n.contains("studio") || n.contains("ufficio") || n.contains("office")           { return "desktopcomputer" }
        if n.contains("garage")                                                              { return "car" }
        if n.contains("giardino") || n.contains("terrazzo") || n.contains("balcon")        { return "tree" }
        if n.contains("ingresso") || n.contains("entrance") || n.contains("hallway")       { return "door.left.hand.open" }
        if n.contains("lavanderia") || n.contains("laundry")                                { return "washer" }
        return "house"
    }
}

// MARK: - RoomScoreRing

/// Cerchio di progresso compatto che mostra l'health score della stanza.
/// Analogo al ring di Apple Health — colore semantico + numero al centro.
private struct RoomScoreRing: View {

    let score: Double   // 0.0–1.0
    let color: Color

    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            // Traccia di sfondo
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 4)
                .frame(width: 40, height: 40)

            // Arco progresso
            Circle()
                .trim(from: 0, to: animated)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: animated)

            // Numero score al centro
            Text("\(Int(score * 100))")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .onAppear { animated = score }
        .onChange(of: score) { _, v in animated = v }
    }
}

// MARK: - SensorMicroIndicator

/// Micro-indicatore collassato: icona tipo sensore + dot stato.
/// Risponde a "ci sono problemi" senza esporre il numero grezzo.
private struct SensorMicroIndicator: View {

    let sensor: SensorData

    private var dotColor: Color {
        switch sensor.urgency {
        case .danger:  return .red
        case .warning: return .orange
        case .normal:  return .green
        }
    }

    private var bgColor: Color {
        switch sensor.urgency {
        case .danger:  return .red.opacity(0.09)
        case .warning: return .orange.opacity(0.09)
        case .normal:  return Color(.tertiarySystemGroupedBackground)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: sensor.serviceType.sfSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dotColor)
            // Mostra il valore solo se urgency != normal, per non sovraccaricare
            if sensor.urgency != .normal {
                Text(sensor.formattedValue)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(dotColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(bgColor, in: Capsule())
    }
}

// MARK: - SensorBarRow

/// Riga sensore nello stato espanso.
/// Mostra: icona | nome | barra-progresso colorata | valore
/// La barra dà un'idea immediata di quanto il valore sia lontano dalla soglia.
private struct SensorBarRow: View {

    let sensor: SensorData

    private var accentColor: Color {
        switch sensor.urgency {
        case .danger:  return .red
        case .warning: return .orange
        case .normal:  return BrandColor.primary
        }
    }

    // Progresso normalizzato 0–1 rispetto alla soglia danger
    private var barProgress: Double {
        guard sensor.dangerThreshold > 0 else { return 0 }
        return min(1.0, sensor.currentValue / sensor.dangerThreshold)
    }

    var body: some View {
        HStack(spacing: 12) {

            // Icona cerchio
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: sensor.serviceType.sfSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            // Nome + barra progresso
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(sensor.serviceType.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    if sensor.sourceCount > 1 {
                        Text("×\(sensor.sourceCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Valore allineato a destra
                    HStack(spacing: 4) {
                        if sensor.urgency != .normal {
                            Image(systemName: sensor.urgency.sfSymbol)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accentColor)
                        }
                        Text(sensor.formattedValue)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(sensor.urgency == .normal ? .secondary : accentColor)
                            .monospacedDigit()
                    }
                }

                // Barra progresso slim
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(accentColor.opacity(0.10))
                            .frame(height: 4)
                        Capsule()
                            .fill(accentColor.opacity(0.75))
                            .frame(width: max(4, geo.size.width * barProgress), height: 4)
                    }
                }
                .frame(height: 4)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - AIInsightRow

/// Sezione AI inline nella card espansa.
/// Tono editoriale: icona sparkles + messaggio + azioni rapide.
private struct AIInsightRow: View {

    let insight: AmbientalAIInsight
    let fallbackAccessoryID: String?
    let onDismiss: (DismissalReason) -> Void
    let onExecuteAction: (AINextAction) async -> Bool
    let onReviewAutomation: (AutomationProposal) -> Void

    @State private var showDismissDialog = false

    private var insightColor: Color {
        switch insight.severity {
        case .info:    return .blue
        case .warning: return .orange
        case .anomaly: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header: sparkles + etichetta + dismiss
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(insightColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "ai.short", defaultValue: "AI"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(insightColor)
                    Text(insight.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    showDismissDialog = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    String(localized: "insight.dismiss.dialog.title", defaultValue: "Perché vuoi ignorare questo insight?"),
                    isPresented: $showDismissDialog,
                    titleVisibility: .visible
                ) {
                    Button(DismissalReason.userActedManually.localizedLabel) { onDismiss(.userActedManually) }
                    Button(DismissalReason.irrelevant.localizedLabel)        { onDismiss(.irrelevant) }
                    Button(DismissalReason.unclear.localizedLabel)           { onDismiss(.unclear) }
                    Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                }
            }

            // Azioni rapide
            if !insight.nextActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(insight.nextActions) { action in
                            NextActionButtonView(
                                action: action,
                                insight: insight,
                                insightColor: insightColor,
                                fallbackAccessoryID: fallbackAccessoryID,
                                onExecuteAction: onExecuteAction,
                                onReviewAutomation: onReviewAutomation
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(insightColor.opacity(0.04))
    }
}

// MARK: - NextActionButtonView

private struct NextActionButtonView: View {

    let action: AINextAction
    let insight: AmbientalAIInsight
    let insightColor: Color
    let fallbackAccessoryID: String?
    let onExecuteAction: (AINextAction) async -> Bool
    let onReviewAutomation: (AutomationProposal) -> Void

    enum ButtonState { case idle, executing, completed, error }
    @State private var state: ButtonState = .idle

    var body: some View {
        // I tip sono chip statici: nessuna azione da eseguire, solo un suggerimento visibile.
        if action.isTip {
            tipChip
        } else {
            suggestButton
        }
    }

    // Chip informativo per i tip manuali — non interattivo, stile "nota"
    private var tipChip: some View {
        HStack(spacing: 5) {
            Image(systemName: action.iconName ?? "lightbulb.fill")
                .font(.system(size: 10, weight: .medium))
            Text(action.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(insightColor.opacity(0.8))
        .background(
            Capsule()
                .fill(insightColor.opacity(0.08))
                .overlay(Capsule().stroke(insightColor.opacity(0.20), lineWidth: 1))
        )
    }

    // Pulsante eseguibile per le azioni suggest HomeKit
    private var suggestButton: some View {
        Button {
            guard state == .idle else { return }
            Task { await handleTap() }
        } label: {
            HStack(spacing: 5) {
                switch state {
                case .executing:
                    ProgressView().scaleEffect(0.7).frame(width: 12, height: 12)
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                case .idle:
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(labelText)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().stroke(insightColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(insightColor)
        }
        .buttonStyle(.plain)
        .disabled(state == .executing || state == .completed)
    }

    private var labelText: String {
        switch state {
        case .completed: return "Fatto"
        case .error:     return "Errore"
        default:         return action.label
        }
    }

    private func handleTap() async {
        // "suggest" actions execute immediately via HomeKit — no rule panel
        if action.actionType == "suggest" {
            state = .executing
            let success = await onExecuteAction(action)
            if success {
                state = .completed
            } else {
                state = .error
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); state = .idle }
            }
            return
        }

        guard let proposal = AmbientalAutomationProposalFactory.proposal(
            from: action,
            insight: insight,
            fallbackAccessoryID: fallbackAccessoryID
        ) else {
            state = .error
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); state = .idle }
            return
        }

        onReviewAutomation(proposal)
    }
}

// MARK: - Preview

#Preview("Room Cards — vari stati") {
    let now = Date()
    let rooms = [
        RoomEnvironmentData(
            id: UUID(), roomName: "Cucina",
            sensors: [
                SensorData(id: UUID(), accessoryUUIDs: ["a1"], serviceType: .temperature,
                           roomName: "Cucina", currentValue: 24.5, lastUpdated: now,
                           warningThreshold: 28, dangerThreshold: 32, sourceCount: 1),
                SensorData(id: UUID(), accessoryUUIDs: ["a2"], serviceType: .humidity,
                           roomName: "Cucina", currentValue: 68.0, lastUpdated: now,
                           warningThreshold: 65, dangerThreshold: 75, sourceCount: 1),
            ]
        ),
        RoomEnvironmentData(
            id: UUID(), roomName: "Camera da letto",
            sensors: [
                SensorData(id: UUID(), accessoryUUIDs: ["c1"], serviceType: .temperature,
                           roomName: "Camera da letto", currentValue: 33.0, lastUpdated: now,
                           warningThreshold: 28, dangerThreshold: 32, sourceCount: 1),
                SensorData(id: UUID(), accessoryUUIDs: ["c2"], serviceType: .carbonMonoxide,
                           roomName: "Camera da letto", currentValue: 26.0, lastUpdated: now,
                           warningThreshold: 10, dangerThreshold: 25, sourceCount: 1),
            ]
        ),
    ]
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            ForEach(rooms) { room in
                RoomSectionView(room: room, onSensorTap: { _ in })
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
