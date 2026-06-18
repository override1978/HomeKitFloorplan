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
    @State private var blockedEditRule: Rule?
    @State private var pendingDelete: Rule?
    @State private var executingRule: Rule?

    var body: some View {
        Group {
            if ruleEngine.rules.isEmpty {
                emptyState
            } else {
                List {
                    rulesList
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(String(localized: "habits.automations.title", defaultValue: "Automations"))
        .navigationBarTitleDisplayMode(.large)
        // Sheet a livello della view, non del ForEach, per evitare dismiss immediato
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule) { updatedDraft in
                guard let updatedDraft else { return }
                ruleEngine.updateRule(rule, from: updatedDraft)
            }
        }
        .alert(String(localized: "rules.homekitEdit.title", defaultValue: "Modifica da Apple Home"),
               isPresented: Binding(
                get: { blockedEditRule != nil },
                set: { if !$0 { blockedEditRule = nil } }
               ),
               presenting: blockedEditRule) { _ in
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: { rule in
            Text(String(
                localized: "rules.homekitEdit.message",
                defaultValue: "Questa automazione è già sincronizzata con HomeKit. Per ora puoi attivarla, disattivarla, eseguirla o eliminarla dall'app; la modifica completa va fatta da Apple Home."
            ))
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
        let isScene = rule.actionSceneName != nil
        Button {
            if rule.executionMode == "homeKit" {
                blockedEditRule = rule
            } else {
                editingRule = rule
            }
        } label: {
            HStack(spacing: 12) {
                // Icona azione — viola per scene multi-azione, accent per azioni singole
                ZStack {
                    Circle()
                        .fill((isScene ? Color.indigo : Color.accentColor).opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: isScene ? "sparkles" : actionIcon(for: rule.actionType))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isScene ? Color.indigo : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if rule.generatedByAI {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "quote.bubble.fill")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .padding(.top, 1)
                            Text(
                                String(localized: "rules.aiRequest.prefix", defaultValue: "Richiesta AI: ")
                                + rule.ruleDescription
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                        }
                    } else {
                        Text(rule.ruleDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Scena multi-azione collegata
                    if let sceneName = rule.actionSceneName {
                        Label(sceneName, systemImage: "theatermasks.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.indigo.opacity(0.10), in: Capsule())
                    }

                    Label(triggerSummary(for: rule), systemImage: triggerIcon(for: rule))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.10), in: Capsule())

                    Label(actionSummary(for: rule), systemImage: actionIcon(for: rule.actionType))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isScene ? .indigo : .accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((isScene ? Color.indigo : Color.accentColor).opacity(0.10), in: Capsule())

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

                    // Condizione sensore
                    if let condSummary = conditionSummary(for: rule) {
                        Label(condSummary, systemImage: conditionIcon(for: rule))
                            .font(.caption2)
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.teal.opacity(0.10), in: Capsule())
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
                        set: { _ in ruleEngine.toggleRule(rule, home: homeKit.currentHome) }
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

    private func conditionSummary(for rule: Rule) -> String? {
        guard let charID = rule.triggerCharacteristicID, let threshold = rule.triggerThreshold else { return nil }
        let parts = charID.split(separator: "|").map(String.init)
        guard let sensorTypeRaw = parts.first else { return nil }
        let sensorName = SensorServiceType(rawValue: sensorTypeRaw)?.displayName ?? sensorTypeRaw
        let room      = parts.count > 1 ? parts[1] : nil
        let direction = parts.count > 2 ? parts[2] : "below"
        let dirSymbol = direction == "above" ? ">" : "<"
        let roomStr   = room.map { " (\($0))" } ?? ""
        let unit: String
        switch sensorTypeRaw {
        case "lightSensor":   unit = " lux"
        case "temperature":   unit = "°C"
        case "humidity":      unit = "%"
        case "carbonDioxide": unit = " ppm"
        default:              unit = ""
        }
        return "\(sensorName)\(roomStr) \(dirSymbol) \(String(format: "%.1f", threshold))\(unit)"
    }

    private func conditionIcon(for rule: Rule) -> String {
        guard let charID = rule.triggerCharacteristicID,
              let sensorTypeRaw = charID.split(separator: "|").first.map(String.init) else {
            return "sensor.tag.radiowaves.forward"
        }
        switch sensorTypeRaw {
        case "lightSensor":    return "sun.max.fill"
        case "temperature":    return "thermometer.medium"
        case "humidity":       return "humidity.fill"
        case "carbonDioxide":  return "carbon.dioxide.cloud.fill"
        case "carbonMonoxide": return "aqi.medium"
        case "airQuality":     return "aqi.low"
        default:               return "sensor.tag.radiowaves.forward"
        }
    }

    private func triggerSummary(for rule: Rule) -> String {
        switch rule.triggerType {
        case "calendar":
            let time = rule.triggerTime ?? "--:--"
            let weekdays = weekdaySummary(for: rule.weekdaysArray)
            return weekdays.isEmpty ? time : "\(time) · \(weekdays)"
        case "characteristic":
            return conditionSummary(for: rule) ?? String(localized: "rules.trigger.sensor", defaultValue: "Sensor trigger")
        default:
            return String(localized: "rules.trigger.ondemand", defaultValue: "On-demand")
        }
    }

    private func triggerIcon(for rule: Rule) -> String {
        switch rule.triggerType {
        case "calendar": return "calendar.badge.clock"
        case "characteristic": return conditionIcon(for: rule)
        default: return "bolt"
        }
    }

    private func weekdaySummary(for weekdays: [Int]) -> String {
        guard !weekdays.isEmpty else { return "" }
        let normalized = Set(weekdays)
        if normalized == Set(1...7) {
            return String(localized: "rules.weekdays.everyDay", defaultValue: "Every day")
        }
        if normalized == Set([2, 3, 4, 5, 6]) {
            return String(localized: "rules.weekdays.weekdays", defaultValue: "Weekdays")
        }
        if normalized == Set([1, 7]) {
            return String(localized: "rules.weekdays.weekend", defaultValue: "Weekend")
        }

        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().compactMap { day in
            guard day >= 1, day <= symbols.count else { return nil }
            return symbols[day - 1]
        }.joined(separator: ", ")
    }

    private func actionSummary(for rule: Rule) -> String {
        if let sceneName = rule.actionSceneName {
            return String(
                format: String(localized: "rules.action.scene.format", defaultValue: "Scene: %@"),
                sceneName
            )
        }

        switch rule.actionType {
        case "on": return String(localized: "rules.action.on", defaultValue: "Turn on")
        case "off": return String(localized: "rules.action.off", defaultValue: "Turn off")
        case "dim":
            let percent = Int((rule.actionValue ?? 0.3) * 100)
            return String(
                format: String(localized: "rules.action.dim.format", defaultValue: "Dim %d%%"),
                percent
            )
        case "open": return String(localized: "rules.action.open", defaultValue: "Open")
        case "close": return String(localized: "rules.action.close", defaultValue: "Close")
        case "setSpeed":
            let percent = Int((rule.actionValue ?? 0.5) * 100)
            return String(
                format: String(localized: "rules.action.speed.format", defaultValue: "Speed %d%%"),
                percent
            )
        case "setTemp":
            let temp = rule.actionValue ?? 22.0
            return String(
                format: String(localized: "rules.action.temp.format", defaultValue: "Set %d°C"),
                Int(temp)
            )
        case "setMode":
            return String(localized: "rules.action.mode", defaultValue: "Set mode")
        default:
            return rule.actionType
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
