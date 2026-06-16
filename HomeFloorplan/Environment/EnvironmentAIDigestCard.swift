import SwiftUI

// MARK: - EnvironmentAIDigestCard
//
// Card "AI Digest" stile Apple Intelligence: superfice editoriale che porta
// gli insight di tutte le stanze in primo piano, PRIMA delle card individuali.
//
// Filosofia: l'utente non deve aprire ogni stanza per trovare il problema.
// La card mostra max 3 insight ordinati per severità, con azioni rapide.
//
// Layout per ogni pagina insight:
//   ┌─────────────────────────────────────────────────────────────┐
//   │  [sparkles]  AI INSIGHTS                          [1 di 2]  │
//   │  ─────────────────────────────────────────────────────────  │
//   │  [⚠ icon]  Cucina                                           │
//   │  Umidità elevata (72%) da 3 ore, trend in salita.           │
//   │                                                             │
//   │  [  air.purifier  Accendi purificatore  ]  [  fan Ventila ] │
//   │                                                             │
//   │  ● ● ○  (page dots)                    [Ignora →]           │
//   └─────────────────────────────────────────────────────────────┘

struct EnvironmentAIDigestCard: View {

    let insights: [AmbientalAIInsight]
    let onDismissInsight: (AmbientalAIInsight, DismissalReason) -> Void
    let onExecuteAction: (AINextAction, AmbientalAIInsight) -> Void
    let onCreateRule: (RuleDraft, AmbientalAIInsight) -> Void

    @State private var currentPage: Int = 0

    // Insight ordinati: anomaly > warning > info
    private var sorted: [AmbientalAIInsight] {
        insights.sorted { $0.severity.priority > $1.severity.priority }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header sezione ─────────────────────────────────────────
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(String(localized: "digest.header.title", defaultValue: "AI Insights"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if sorted.count > 1 {
                    Text(String(format: String(localized: "digest.header.pageOf", defaultValue: "%1$d of %2$d"), currentPage + 1, sorted.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 0)

            // ── Carosello insight ──────────────────────────────────────
            TabView(selection: $currentPage) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, insight in
                    InsightPageView(
                        insight: insight,
                        onDismiss: { reason in
                            onDismissInsight(insight, reason)
                            // Torna alla pagina precedente se siamo all'ultima
                            if currentPage >= sorted.count - 1 && currentPage > 0 {
                                withAnimation { currentPage -= 1 }
                            }
                        },
                        onExecuteAction: { action in onExecuteAction(action, insight) },
                        onCreateRule: { draft in onCreateRule(draft, insight) }
                    )
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(minHeight: 170)

            // ── Page dots personalizzati ───────────────────────────────
            if sorted.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<sorted.count, id: \.self) { idx in
                        Circle()
                            .fill(idx == currentPage
                                  ? Color.blue
                                  : Color.secondary.opacity(0.3))
                            .frame(width: idx == currentPage ? 7 : 5,
                                   height: idx == currentPage ? 7 : 5)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.vertical, 12)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            Color.blue.opacity(0.15),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: Color.blue.opacity(0.08), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

// MARK: - InsightPageView

/// Pagina singola del carosello. Una per ogni insight attivo.
private struct InsightPageView: View {

    let insight: AmbientalAIInsight
    let onDismiss: (DismissalReason) -> Void
    let onExecuteAction: (AINextAction) -> Void
    let onCreateRule: (RuleDraft) -> Void

    @State private var showDismissDialog = false

    private var severityColor: Color { insight.severity.uiColor }

    private var intelligenceLevelColor: Color {
        switch insight.intelligenceLevel {
        case .observation:    return .blue
        case .pattern:        return .indigo
        case .prediction:     return .purple
        case .recommendation: return .green
        }
    }

    private var severitySymbol: String {
        switch insight.severity {
        case .anomaly: return "waveform.badge.exclamationmark"
        case .warning: return "exclamationmark.bubble.fill"
        case .info:    return "info.bubble.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Intestazione: stanza + dismiss ─────────────────────────
            HStack(alignment: .top, spacing: 10) {
                // Icona severità
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(severityColor.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: severitySymbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(severityColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(insight.roomName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let deviceName = insight.sourceAccessoryName {
                        Text(deviceName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(insight.severity.localizedLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(severityColor)

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Label(insight.intelligenceLevel.localizedLabel,
                              systemImage: insight.intelligenceLevel.sfSymbol)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(intelligenceLevelColor)
                    }
                }

                Spacer()

                // Pulsante Ignora
                Button {
                    showDismissDialog = true
                } label: {
                    Text(String(localized: "insight.action.dismiss", defaultValue: "Dismiss"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Color(.tertiarySystemGroupedBackground),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    String(localized: "insight.dismiss.dialog.title", defaultValue: "Why dismiss this insight?"),
                    isPresented: $showDismissDialog,
                    titleVisibility: .visible
                ) {
                    Button(DismissalReason.userActedManually.localizedLabel) { onDismiss(.userActedManually) }
                    Button(DismissalReason.irrelevant.localizedLabel)        { onDismiss(.irrelevant) }
                    Button(DismissalReason.unclear.localizedLabel)           { onDismiss(.unclear) }
                    Button(String(localized: "insight.dismiss.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
                }
            }

            // ── Messaggio insight ──────────────────────────────────────
            Text(insight.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            // ── Azioni rapide ──────────────────────────────────────────
            if !insight.nextActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(insight.nextActions) { action in
                            DigestActionButton(
                                action: action,
                                color: severityColor,
                                fallbackAccessoryID: nil,
                                onExecuteAction: onExecuteAction,
                                onCreateRule: onCreateRule
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - DigestActionButton

/// Pulsante/chip azione nel digest.
/// - "suggest": pulsante interattivo con stati idle/executing/completed/error
/// - "tip": chip statico informativo (lightbulb), non interattivo
private struct DigestActionButton: View {

    let action: AINextAction
    let color: Color
    let fallbackAccessoryID: String?
    let onExecuteAction: (AINextAction) -> Void
    let onCreateRule: (RuleDraft) -> Void

    enum ButtonState { case idle, executing, completed, error }
    @State private var state: ButtonState = .idle

    private var actionIcon: String {
        switch action.accessoryActionType {
        case "on":       return "power"
        case "off":      return "power"
        case "setMode":  return "slider.horizontal.3"
        case "setSpeed": return "fan.fill"
        case "setTemp":  return "thermometer.medium"
        case "open":     return "arrow.up.square"
        case "close":    return "arrow.down.square"
        case "dim":      return "light.max"
        default:         return "arrow.right.circle.fill"
        }
    }

    var body: some View {
        if action.isTip {
            tipChip
        } else {
            suggestButton
        }
    }

    // Chip statico per i tip manuali — stile nota/suggerimento
    private var tipChip: some View {
        HStack(spacing: 6) {
            Image(systemName: action.iconName ?? "lightbulb.fill")
                .font(.system(size: 12, weight: .medium))
            Text(action.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .foregroundStyle(color.opacity(0.75))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // Pulsante interattivo per le azioni suggest HomeKit
    private var suggestButton: some View {
        Button {
            guard state == .idle else { return }
            handleTap()
        } label: {
            HStack(spacing: 6) {
                switch state {
                case .executing:
                    ProgressView().scaleEffect(0.75).frame(width: 14, height: 14)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                case .idle:
                    Image(systemName: actionIcon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(color)
                }

                Text(buttonLabel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(state == .completed ? .green : state == .error ? .red : color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        state == .completed
                            ? Color.green.opacity(0.10)
                            : state == .error
                                ? Color.red.opacity(0.10)
                                : color.opacity(0.09)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                state == .completed
                                    ? Color.green.opacity(0.35)
                                    : state == .error
                                        ? Color.red.opacity(0.35)
                                        : color.opacity(0.30),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(state == .executing || state == .completed)
        .scaleEffect(state == .executing ? 0.97 : 1.0)
        .animation(.spring(response: 0.25), value: state)
    }

    private var buttonLabel: String {
        switch state {
        case .completed: return String(localized: "insight.action.done",  defaultValue: "Done")
        case .error:     return String(localized: "insight.action.error", defaultValue: "Error")
        default:         return action.label
        }
    }

    private func handleTap() {
        // "suggest" actions execute immediately via HomeKit — no rule panel
        if action.actionType == "suggest" {
            state = .executing
            onExecuteAction(action)
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                state = .completed
            }
            return
        }

        // "createRule" / legacy path
        let resolvedID = action.accessoryID ?? fallbackAccessoryID
        let rawType    = action.accessoryActionType ?? "on"
        let resolvedActionType: String
        switch rawType {
        case "setMode", "setSpeed", "setTemp", "on", "off", "dim", "open", "close":
            resolvedActionType = rawType
        default:
            resolvedActionType = "on"
        }

        guard let accessoryID = resolvedID else {
            state = .error
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                state = .idle
            }
            return
        }

        let draft = RuleDraft(
            name: action.label,
            description: action.label,
            triggerType: "inApp",
            actionAccessoryID: accessoryID,
            actionAccessoryName: "",
            actionType: resolvedActionType,
            actionValue: action.accessoryValue,
            confidenceScore: 0.8,
            generatedByAI: true
        )
        onCreateRule(draft)
    }
}

// MARK: - InsightSeverity helpers

private extension InsightSeverity {
    var priority: Int {
        switch self {
        case .anomaly: return 2
        case .warning: return 1
        case .info:    return 0
        }
    }

    var uiColor: Color {
        switch self {
        case .anomaly: return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }
}

// MARK: - Preview

#Preview("AI Digest Card") {
    let now = Date()
    let insights = [
        AmbientalAIInsight(
            roomName: "Cucina",
            message: "L'umidità è a 72%, sopra la baseline di 58% delle ultime 24h. Trend in salita.",
            severity: .warning,
            nextActions: [
                AINextAction(
                    label: "Accendi purificatore",
                    actionType: "suggest",
                    accessoryID: "uuid-1",
                    accessoryActionType: "setMode",
                    accessoryValue: 1
                )
            ]
        ),
        AmbientalAIInsight(
            roomName: "Camera",
            message: "CO₂ a 1450 ppm, insolito per quest'ora. Ventilare la stanza.",
            severity: .anomaly,
            nextActions: []
        ),
    ]

    ScrollView {
        EnvironmentAIDigestCard(
            insights: insights,
            onDismissInsight: { _, _ in },
            onExecuteAction: { _, _ in },
            onCreateRule: { _, _ in }
        )
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
