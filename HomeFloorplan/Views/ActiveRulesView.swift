import SwiftUI
import HomeKit

// MARK: - ActiveRulesView

/// Lista delle regole di automazione approvate.
/// Badge: HomeKit (blu) | In-App (grigio) | AI (viola).
/// Supporta toggle attiva/disattiva, swipe-to-delete, tap per editor.
struct ActiveRulesView: View {

    @Environment(RuleEngineService.self) private var ruleEngine
    @Environment(HomeKitService.self) private var homeKit

    @State private var editingRule: Rule?
    @State private var pendingDelete: Rule?
    @State private var executingRule: Rule?

    var body: some View {
        Group {
            if ruleEngine.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
        // Sheet a livello della view, non del ForEach, per evitare dismiss immediato
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule) { updatedDraft in
                guard let updatedDraft else { return }
                ruleEngine.updateRule(rule, from: updatedDraft)
            }
        }
        .alert(String(localized: "rules.delete.title", defaultValue: "Eliminare la regola?"),
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { rule in
            Button(String(localized: "rules.delete.confirm", defaultValue: "Elimina"), role: .destructive) {
                Task {
                    try? await ruleEngine.deleteRule(rule, home: homeKit.currentHome)
                }
            }
            Button(String(localized: "rules.delete.cancel", defaultValue: "Annulla"), role: .cancel) {}
        } message: { rule in
            Text(rule.ruleDescription)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "rules.empty.title", defaultValue: "Nessuna regola attiva"))
                .font(.headline)
            Text(String(localized: "rules.empty.subtitle",
                        defaultValue: "Approva un'abitudine per creare la prima regola automatica."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private var rulesList: some View {
        ForEach(ruleEngine.rules) { rule in
            ruleRow(rule)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        runNow(rule)
                    } label: {
                        Label(String(localized: "rules.action.run", defaultValue: "Esegui ora"), systemImage: "play.fill")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = rule
                    } label: {
                        Label(String(localized: "rules.action.delete", defaultValue: "Elimina"), systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: Rule) -> some View {
        Button {
            editingRule = rule
        } label: {
            HStack(spacing: 12) {
                // Icona azione
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: actionIcon(for: rule.actionType))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(rule.ruleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    // Badge row
                    HStack(spacing: 6) {
                        // Modalità
                        badgeView(
                            icon: rule.executionModeIcon,
                            label: rule.executionModeLabel,
                            color: rule.executionMode == "homeKit" ? .blue : .gray
                        )
                        // AI badge
                        if rule.generatedByAI {
                            badgeView(icon: "brain", label: "AI", color: .purple)
                        }
                    }

                    // Ultima esecuzione
                    if let label = lastExecutedLabel(for: rule) {
                        Label(label, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Spinner durante esecuzione
                if executingRule?.id == rule.id {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 32)
                } else {
                    // Toggle attiva/disattiva
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { _ in ruleEngine.toggleRule(rule) }
                    ))
                    .labelsHidden()
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badgeView(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// Testo leggibile dell'ultima esecuzione: "Oggi 21:04", "Ieri 08:30", "3 giu 14:22", ecc.
    private func lastExecutedLabel(for rule: Rule) -> String? {
        guard let date = rule.lastExecutedAt else { return nil }
        let cal = Calendar.current
        let now = Date()
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) {
            return "Oggi \(timeStr)"
        } else if cal.isDateInYesterday(date) {
            return "Ieri \(timeStr)"
        } else if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            let dayName = date.formatted(.dateTime.weekday(.wide))
            return "\(dayName) \(timeStr)"
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
    }

    private func actionIcon(for actionType: String) -> String {
        switch actionType {
        case "on":       return "lightbulb.fill"
        case "off":      return "lightbulb.slash"
        case "dim":      return "sun.min.fill"
        case "open":     return "arrow.up.square"
        case "close":    return "arrow.down.square"
        case "setMode":  return "slider.horizontal.3"
        case "setTemp":  return "thermometer.medium"
        case "setSpeed": return "wind"
        default:         return "bolt.fill"
        }
    }

    // MARK: - Run now

    private func runNow(_ rule: Rule) {
        guard let home = homeKit.currentHome else { return }
        executingRule = rule
        Task {
            await ruleEngine.executeNow(rule, home: home)
            executingRule = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
