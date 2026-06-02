import SwiftUI
import HomeKit

// MARK: - RuleEditorView

/// Sheet per creare o modificare una regola automatica.
/// Supporta sia RuleDraft (nuovo) che Rule esistente.
/// Il callback `onSave` riceve il RuleDraft aggiornato con tutte le modifiche utente.
struct RuleEditorView: View {

    /// Callback: nil = regola esclusa/annullata, non-nil = salva il draft modificato.
    let onSave: (RuleDraft?) -> Void
    /// Callback opzionale: esegui subito l'azione senza salvare la regola.
    /// Se nil, il pulsante "Esegui ora" non viene mostrato.
    let onExecuteNow: ((RuleDraft) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit

    /// Sheet dettaglio accessorio (aperto dal tap sulla riga accessorio)
    @State private var showAccessoryDetail = false

    // MARK: - Stato editabile

    @State private var name: String
    @State private var triggerType: String          // "inApp" | "calendar"
    @State private var scheduledTime: Date
    @State private var selectedWeekdays: Set<Int>
    @State private var actionType: String           // "on" | "off" | "dim" | "open" | "close"
    @State private var actionValue: Double          // 0.05…1.0 per dim; o modalità per setMode
    @State private var actionValue2: Double         // temperatura °C secondaria (solo setMode su termostato)
    @State private var threshold: Double            // 0…100 per characteristic
    @State private var includeRule: Bool = true     // toggle per escludere la regola

    // Campi read-only (non modificabili dall'utente)
    private let accessoryName: String
    private let accessoryID: String
    private let confidenceScore: Double
    private let generatedByAI: Bool
    private let triggerCharacteristicID: String?

    // MARK: - Init da RuleDraft

    init(draft: RuleDraft, onSave: @escaping (RuleDraft?) -> Void, onExecuteNow: ((RuleDraft) -> Void)? = nil) {
        self.onSave                  = onSave
        self.onExecuteNow            = onExecuteNow
        self.accessoryID             = draft.actionAccessoryID
        self.accessoryName           = draft.actionAccessoryName.isEmpty ? draft.name : draft.actionAccessoryName
        self.confidenceScore         = draft.confidenceScore
        self.generatedByAI           = draft.generatedByAI
        self.triggerCharacteristicID = draft.triggerCharacteristicID
        _name             = State(initialValue: draft.name)
        // "characteristic" non è selezionabile dall'utente nel picker — lo mappiamo a inApp
        let tType = (draft.triggerType == "calendar") ? "calendar" : "inApp"
        _triggerType      = State(initialValue: tType)
        _scheduledTime    = State(initialValue: Self.dateFromTimeStr(draft.triggerTime))
        _selectedWeekdays = State(initialValue: Set(draft.triggerWeekdays ?? []))
        _actionType       = State(initialValue: draft.actionType)
        // setTemp arriva in °C (es. 22.0) → normalizza a 0…1 per lo slider
        let rawVal = draft.actionValue ?? 0.5
        let normVal = draft.actionType == "setTemp" ? max(0, min(1, (rawVal - 10) / 30)) : rawVal
        _actionValue      = State(initialValue: normVal)
        _actionValue2     = State(initialValue: draft.actionValue2 ?? 22.0)
        _threshold        = State(initialValue: draft.triggerThreshold ?? 80.0)
    }

    // MARK: - Init da Rule esistente

    init(rule: Rule, onSave: @escaping (RuleDraft?) -> Void, onExecuteNow: ((RuleDraft) -> Void)? = nil) {
        self.onSave                  = onSave
        self.onExecuteNow            = onExecuteNow
        self.accessoryID             = rule.actionAccessoryID
        self.accessoryName           = rule.name
        self.confidenceScore         = rule.confidenceScore
        self.generatedByAI           = rule.generatedByAI
        self.triggerCharacteristicID = rule.triggerCharacteristicID
        _name             = State(initialValue: rule.name)
        let tType = (rule.triggerType == "calendar") ? "calendar" : "inApp"
        _triggerType      = State(initialValue: tType)
        _scheduledTime    = State(initialValue: Self.dateFromTimeStr(rule.triggerTime))
        _selectedWeekdays = State(initialValue: Set(rule.weekdaysArray))
        _actionType       = State(initialValue: rule.actionType)
        let rawValR = rule.actionValue ?? 0.5
        let normValR = rule.actionType == "setTemp" ? max(0, min(1, (rawValR - 10) / 30)) : rawValR
        _actionValue      = State(initialValue: normValR)
        _actionValue2     = State(initialValue: rule.actionValue2 ?? 22.0)
        _threshold        = State(initialValue: rule.triggerThreshold ?? 80.0)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {

                // ── 1. Nome ──────────────────────────────────────────────
                Section {
                    HStack {
                        Text(String(localized: "rule.editor.name", defaultValue: "Nome"))
                            .foregroundStyle(.secondary)
                        TextField(
                            String(localized: "rule.editor.name.placeholder", defaultValue: "Nome della regola"),
                            text: $name
                        )
                        .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text(String(localized: "rule.editor.name.header", defaultValue: "Regola"))
                }

                // ── 2. Trigger (tipo esecuzione) ─────────────────────────
                Section {
                    Picker(
                        String(localized: "rule.editor.trigger.type", defaultValue: "Esecuzione"),
                        selection: $triggerType
                    ) {
                        Label(
                            String(localized: "rule.trigger.ondemand", defaultValue: "On-demand"),
                            systemImage: "bolt"
                        ).tag("inApp")
                        Label(
                            String(localized: "rule.trigger.scheduled", defaultValue: "Schedulata"),
                            systemImage: "calendar.clock"
                        ).tag("calendar")
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)

                    if triggerType == "calendar" {
                        DatePicker(
                            String(localized: "rule.editor.time", defaultValue: "Orario"),
                            selection: $scheduledTime,
                            displayedComponents: .hourAndMinute
                        )
                        weekdayPicker
                    }
                } header: {
                    Text(String(localized: "rule.editor.trigger.header", defaultValue: "Quando"))
                } footer: {
                    if triggerType == "inApp" {
                        Text(String(localized: "rule.editor.inapp.footer",
                                    defaultValue: "On-demand: la regola si attiva ad ogni aggiornamento sensori. Aggiungi un orario per limitarla a una fascia specifica."))
                            .font(.caption)
                    } else {
                        Text(String(localized: "rule.editor.calendar.footer",
                                    defaultValue: "La regola verrà eseguita da HomeKit all'orario indicato, anche con l'app chiusa."))
                            .font(.caption)
                    }
                }

                // ── 3. Accessorio e azione ───────────────────────────────
                Section {
                    // Riga accessorio — icona + nome accessorio in primo piano
                    // Tap apre AccessoryDetailView per vedere lo stato live
                    Button {
                        if let uuid = UUID(uuidString: accessoryID),
                           homeKit.accessory(for: uuid) != nil {
                            showAccessoryDetail = true
                        }
                    } label: {
                        HStack(spacing: 14) {
                            // Icona accessorio (dall'adapter o fallback per tipo azione)
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(accessoryIconColor.opacity(0.12))
                                    .frame(width: 44, height: 44)
                                AccessoryIconView(iconName: accessoryIconName)
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(accessoryIconColor)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(accessoryName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                // Azione proposta come sottotitolo
                                Label(actionLabel, systemImage: actionIcon)
                                    .font(.caption)
                                    .foregroundStyle(actionColor)
                                    .lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                // Badge "incluso / escluso"
                                includeBadge
                                // Freccia solo se l'accessorio è raggiungibile
                                if let uuid = UUID(uuidString: accessoryID),
                                   homeKit.accessory(for: uuid) != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(.tertiaryLabel))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showAccessoryDetail) {
                        if let uuid = UUID(uuidString: accessoryID),
                           let acc = homeKit.accessory(for: uuid) {
                            AccessoryDetailView(accessory: acc)
                        }
                    }

                    // Picker tipo azione — filtra in base all'accessorio reale
                    Picker(
                        String(localized: "rule.editor.action.type", defaultValue: "Azione"),
                        selection: $actionType
                    ) {
                        ForEach(availableActionTypes, id: \.self) { type in
                            actionPickerLabel(for: type).tag(type)
                        }
                    }
                    .onChange(of: actionType) { _, newType in
                        // Reset valore sensato per ogni tipo
                        switch newType {
                        case "dim":      actionValue = 0.7
                        case "setSpeed": actionValue = 0.5
                        case "setTemp":  actionValue = (22.0 - 10) / 30  // 22°C normalizzato
                        case "setMode":  actionValue = 0; actionValue2 = 22.0  // Auto + 22°C
                        default:         break
                        }
                    }

                    // Controllo valore — prominente, con numero ben visibile
                    if actionType == "dim" {
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min.fill")
                                .foregroundStyle(.yellow)
                                .frame(width: 20)
                            Slider(value: $actionValue, in: 0.05...1.0, step: 0.05)
                                .tint(.yellow)
                            Text("\(Int(actionValue * 100))%")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.yellow)
                                .frame(width: 42, alignment: .trailing)
                                .monospacedDigit()
                        }
                    } else if actionType == "setSpeed" {
                        HStack(spacing: 12) {
                            Image(systemName: "wind")
                                .foregroundStyle(.cyan)
                                .frame(width: 20)
                            Slider(value: $actionValue, in: 0.0...1.0, step: 0.05)
                                .tint(.cyan)
                            Text("\(Int(actionValue * 100))%")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.cyan)
                                .frame(width: 42, alignment: .trailing)
                                .monospacedDigit()
                        }
                    } else if actionType == "setTemp" {
                        HStack(spacing: 12) {
                            Image(systemName: "thermometer.medium")
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                            // Slider 0…1 → 10…40°C
                            Slider(value: $actionValue, in: 0.0...1.0, step: 1.0/30)
                                .tint(.orange)
                            Text(String(format: "%.0f°C", actionValue * 30 + 10))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 48, alignment: .trailing)
                                .monospacedDigit()
                        }
                    } else if actionType == "setMode" {
                        Stepper(
                            value: Binding(
                                get: { Int(actionValue) },
                                set: { actionValue = Double($0) }
                            ),
                            in: 0...setModeMaxValue
                        ) {
                            HStack {
                                Image(systemName: setModeIcon(for: Int(actionValue)))
                                    .foregroundStyle(setModeColor(for: Int(actionValue)))
                                    .frame(width: 20)
                                Text(String(localized: "rule.editor.mode", defaultValue: "Modalità"))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(modeLabel(for: Int(actionValue)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(setModeColor(for: Int(actionValue)))
                            }
                        }
                        // Slider temperatura associato — visibile solo per termostati
                        if isThermostatAccessory {
                            HStack(spacing: 12) {
                                Image(systemName: "thermometer.medium")
                                    .foregroundStyle(.orange)
                                    .frame(width: 20)
                                Slider(value: $actionValue2, in: 16...30, step: 0.5)
                                    .tint(.orange)
                                Text(String(format: "%.0f°C", actionValue2))
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .frame(width: 48, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        }
                    }

                    // Toggle includi/escludi
                    Toggle(
                        String(localized: "rule.editor.include", defaultValue: "Includi questa regola"),
                        isOn: $includeRule
                    )
                    .tint(.accentColor)
                } header: {
                    Text(String(localized: "rule.editor.action.header", defaultValue: "Cosa farà"))
                } footer: {
                    if !includeRule {
                        Text(String(localized: "rule.editor.excluded.hint",
                                    defaultValue: "La regola non verrà salvata."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // ── 4. Info esecuzione ───────────────────────────────────
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: executionModeIcon)
                            .foregroundStyle(triggerType == "calendar" ? .blue : .gray)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(triggerType == "calendar"
                                 ? String(localized: "rule.editor.homekit.badge",
                                          defaultValue: "Verrà eseguita da HomeKit")
                                 : String(localized: "rule.editor.inapp.badge",
                                          defaultValue: "Verrà eseguita dall'app"))
                                .font(.subheadline.weight(.medium))
                            Text(triggerType == "calendar"
                                 ? String(localized: "rule.editor.homekit.hint",
                                          defaultValue: "Funziona anche con l'app chiusa.")
                                 : String(localized: "rule.editor.inapp.hint",
                                          defaultValue: "Richiede l'app aperta o in background."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if confidenceScore > 0 {
                        HStack {
                            Text(String(localized: "rule.editor.confidence", defaultValue: "Confidenza AI"))
                            Spacer()
                            Text("\(Int(confidenceScore * 100))%")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "rule.editor.execution.header", defaultValue: "Esecuzione"))
                }
            }
            .navigationTitle(String(localized: "rule.editor.title", defaultValue: "Regola automatica"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "rule.editor.cancel", defaultValue: "Annulla")) {
                        onSave(nil)
                        dismiss()
                    }
                }
                // Pulsante "Esegui ora" — visibile solo se il chiamante supporta l'esecuzione immediata
                if let executeNow = onExecuteNow {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            let draft = buildDraft()
                            dismiss()
                            executeNow(draft)
                        } label: {
                            Label(
                                String(localized: "rule.editor.execute", defaultValue: "Esegui ora"),
                                systemImage: "bolt.fill"
                            )
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tint(.orange)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "rule.editor.save", defaultValue: "Salva regola")) {
                        saveAndDismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Save

    /// Costruisce il RuleDraft corrente dallo stato della form.
    private func buildDraft() -> RuleDraft {
        let resolvedTriggerType = triggerType
        let weekdays = selectedWeekdays.sorted()
        let resolvedValue: Double?
        switch actionType {
        case "dim":      resolvedValue = actionValue
        case "setSpeed": resolvedValue = actionValue
        case "setMode":  resolvedValue = actionValue
        case "setTemp":  resolvedValue = actionValue * 30 + 10  // riconverti da slider 0…1 a °C
        default:         resolvedValue = nil
        }
        // actionValue2: temperatura in °C solo per setMode su termostato
        let resolvedValue2: Double? = (actionType == "setMode" && isThermostatAccessory) ? actionValue2 : nil
        // Converte DatePicker → "HH:mm" solo per trigger schedulati
        let resolvedTimeStr: String?
        if resolvedTriggerType == "calendar" {
            let cal = Calendar.current
            let h = cal.component(.hour,   from: scheduledTime)
            let m = cal.component(.minute, from: scheduledTime)
            resolvedTimeStr = String(format: "%02d:%02d", h, m)
        } else {
            resolvedTimeStr = nil
        }
        return RuleDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            description: name.trimmingCharacters(in: .whitespaces),
            triggerType: resolvedTriggerType,
            triggerTime: resolvedTimeStr,
            triggerWeekdays: weekdays.isEmpty ? nil : weekdays,
            triggerCharacteristicID: triggerCharacteristicID,
            triggerThreshold: resolvedTriggerType == "characteristic" ? threshold : nil,
            actionAccessoryID: accessoryID,
            actionAccessoryName: accessoryName,
            actionType: actionType,
            actionValue: resolvedValue,
            actionValue2: resolvedValue2,
            confidenceScore: confidenceScore,
            generatedByAI: generatedByAI
        )
    }

    private func saveAndDismiss() {
        guard includeRule else {
            onSave(nil)
            dismiss()
            return
        }
        onSave(buildDraft())
        dismiss()
    }

    // MARK: - Time helpers

    /// Converte una stringa "HH:mm" in un `Date` con oggi come data base.
    /// Se la stringa è nil o malformata, usa l'ora corrente.
    static func dateFromTimeStr(_ timeStr: String?) -> Date {
        let cal = Calendar.current
        guard let str = timeStr else { return Date() }
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return Date() }
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = parts[0]
        comps.minute = parts[1]
        return cal.date(from: comps) ?? Date()
    }

    // MARK: - Include badge

    private var includeBadge: some View {
        Text(includeRule
             ? String(localized: "rule.editor.included", defaultValue: "Inclusa")
             : String(localized: "rule.editor.excluded", defaultValue: "Esclusa"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(includeRule ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.12))
            )
            .foregroundStyle(includeRule ? Color.accentColor : Color.orange)
    }

    // MARK: - Accessory display helpers

    /// Icona dell'accessorio reale (dall'adapter) o fallback generico.
    private var accessoryIconName: String {
        if let uuid = UUID(uuidString: accessoryID),
           let acc = homeKit.accessory(for: uuid) {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            return adapter.iconName
        }
        // Fallback basato sul tipo di azione
        return actionIcon
    }

    /// Colore icona accessorio: usa il colore dello stato live se disponibile,
    /// altrimenti torna al colore dell'azione.
    private var accessoryIconColor: Color {
        if let uuid = UUID(uuidString: accessoryID),
           let acc = homeKit.accessory(for: uuid) {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            return AccessoryAppearance.from(adapter).statusColor
        }
        return actionColor
    }

    // MARK: - Available action types (filtered by accessory capabilities)

    /// Tipi di azione disponibili per l'accessorio corrente.
    /// Se l'accessorio non è trovato, mostra tutti i tipi come fallback.
    private var availableActionTypes: [String] {
        guard let uuid = UUID(uuidString: accessoryID),
              let acc = homeKit.accessory(for: uuid) else {
            return ["on", "off", "dim", "open", "close", "setSpeed", "setMode", "setTemp"]
        }
        let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
        let allChars = acc.services.flatMap(\.characteristics)
        func has(_ type: String) -> Bool {
            allChars.contains { $0.characteristicType.lowercased() == type.lowercased() }
        }
        // Termostato / HeaterCooler
        if adapter is ThermostatAdapter {
            var types = ["on", "off"]
            if has("000000b2-0000-1000-8000-0026bb765291") { types.append("setMode") }
            if has("00000035-0000-1000-8000-0026bb765291") ||
               has("00000012-0000-1000-8000-0026bb765291") ||
               has("0000000d-0000-1000-8000-0026bb765291") { types.append("setTemp") }
            if has("00000029-0000-1000-8000-0026bb765291") { types.append("setSpeed") }
            return types
        }
        // Purificatore
        if adapter is AirPurifierAdapter {
            var types = ["on", "off"]
            if has("00000029-0000-1000-8000-0026bb765291") { types.append("setSpeed") }
            if has("000000a8-0000-1000-8000-0026bb765291") { types.append("setMode") }
            return types
        }
        // Luce dimmerabile
        if has("00000008-0000-1000-8000-0026bb765291") { return ["on", "off", "dim"] }
        // Tenda / tapparella
        if has("0000007c-0000-1000-8000-0026bb765291") { return ["open", "close", "dim"] }
        // Ventilatore con velocità
        if has("00000029-0000-1000-8000-0026bb765291") { return ["on", "off", "setSpeed"] }
        // On/Off generico
        return ["on", "off"]
    }

    /// Label del Picker per ogni tipo di azione.
    @ViewBuilder
    private func actionPickerLabel(for type: String) -> some View {
        switch type {
        case "on":       Label(String(localized: "rule.action.on",       defaultValue: "Accendi"),          systemImage: "lightbulb.fill")
        case "off":      Label(String(localized: "rule.action.off",      defaultValue: "Spegni"),           systemImage: "lightbulb.slash.fill")
        case "dim":      Label(String(localized: "rule.action.dim",      defaultValue: "Dimmerizza"),       systemImage: "sun.min.fill")
        case "open":     Label(String(localized: "rule.action.open",     defaultValue: "Apri"),             systemImage: "arrow.up.square.fill")
        case "close":    Label(String(localized: "rule.action.close",    defaultValue: "Chiudi"),           systemImage: "arrow.down.square.fill")
        case "setSpeed": Label(String(localized: "rule.action.setSpeed", defaultValue: "Velocità"),         systemImage: "wind")
        case "setMode":  Label(String(localized: "rule.action.setMode",  defaultValue: "Modalità"),         systemImage: "slider.horizontal.3")
        case "setTemp":  Label(String(localized: "rule.action.setTemp",  defaultValue: "Temperatura"),      systemImage: "thermometer.medium")
        default:         Label(type, systemImage: "bolt.fill")
        }
    }

    /// True se l'accessorio è un termostato/AC (mostra slider temperatura secondaria).
    private var isThermostatAccessory: Bool {
        guard let uuid = UUID(uuidString: accessoryID),
              let acc = homeKit.accessory(for: uuid) else { return false }
        return AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) is ThermostatAdapter
    }

    /// Valore massimo per il Stepper modalità — 1 per purificatore (0=Manuale,1=Auto), 5 per gli altri.
    private var setModeMaxValue: Int {
        guard let uuid = UUID(uuidString: accessoryID),
              let acc = homeKit.accessory(for: uuid) else { return 5 }
        let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
        return (adapter is AirPurifierAdapter) ? 1 : 5
    }

    /// Icona colorata per la modalità nello Stepper.
    private func setModeIcon(for mode: Int) -> String {
        guard let uuid = UUID(uuidString: accessoryID),
              let acc = homeKit.accessory(for: uuid) else {
            return "slider.horizontal.3"
        }
        let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
        if adapter is AirPurifierAdapter {
            return mode == 1 ? "a.circle" : "hand.tap.fill"
        }
        switch mode {
        case 0: return "a.circle"
        case 1: return "flame.fill"
        case 2: return "snowflake"
        case 3: return "drop.fill"
        case 4: return "wind"
        case 5: return "moon.fill"
        default: return "slider.horizontal.3"
        }
    }

    /// Colore per la modalità nello Stepper.
    private func setModeColor(for mode: Int) -> Color {
        guard let uuid = UUID(uuidString: accessoryID),
              let acc = homeKit.accessory(for: uuid) else { return .purple }
        let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
        if adapter is AirPurifierAdapter {
            return mode == 1 ? .green : .orange
        }
        switch mode {
        case 0: return .green
        case 1: return .orange
        case 2: return .blue
        case 3: return .cyan
        case 4: return .gray
        case 5: return .indigo
        default: return .purple
        }
    }

    // MARK: - Action display helpers

    private var actionIcon: String {
        switch actionType {
        case "on":       return "lightbulb.fill"
        case "off":      return "lightbulb.slash.fill"
        case "dim":      return "sun.min.fill"
        case "open":     return "arrow.up.square.fill"
        case "close":    return "arrow.down.square.fill"
        case "setSpeed": return "wind"
        case "setMode":  return "slider.horizontal.3"
        case "setTemp":  return "thermometer.medium"
        default:         return "bolt.fill"
        }
    }

    private var actionColor: Color {
        switch actionType {
        case "on":       return .yellow
        case "off":      return .gray
        case "dim":      return .orange
        case "open":     return .green
        case "close":    return .red
        case "setSpeed": return .cyan
        case "setMode":  return .purple
        case "setTemp":  return .orange
        default:         return .accentColor
        }
    }

    private var actionLabel: String {
        switch actionType {
        case "on":       return String(localized: "rule.action.on",    defaultValue: "Accendi")
        case "off":      return String(localized: "rule.action.off",   defaultValue: "Spegni")
        case "open":     return String(localized: "rule.action.open",  defaultValue: "Apri")
        case "close":    return String(localized: "rule.action.close", defaultValue: "Chiudi")
        case "dim":      return String(format: String(localized: "rule.action.dim.value", defaultValue: "Luminosità %d%%"), Int(actionValue * 100))
        case "setSpeed": return String(format: String(localized: "rule.action.speed.value", defaultValue: "Velocità %d%%"), Int(actionValue * 100))
        case "setTemp":  return String(format: String(localized: "rule.action.temp.value", defaultValue: "Temperatura %.1f°C"), actionValue * 30 + 10)
        case "setMode":
            let base = modeLabel(for: Int(actionValue))
            if isThermostatAccessory {
                return "\(base) · \(String(format: "%.0f°C", actionValue2))"
            }
            return base
        default:         return String(localized: "rule.action.other", defaultValue: "Esegui azione")
        }
    }

    private func modeLabel(for mode: Int) -> String {
        switch mode {
        case 0: return String(localized: "rule.mode.auto",    defaultValue: "Automatico")
        case 1: return String(localized: "rule.mode.heat",    defaultValue: "Caldo")
        case 2: return String(localized: "rule.mode.cool",    defaultValue: "Freddo")
        case 3: return String(localized: "rule.mode.dry",     defaultValue: "Asciuga")
        case 4: return String(localized: "rule.mode.fan",     defaultValue: "Solo ventola")
        case 5: return String(localized: "rule.mode.sleep",   defaultValue: "Notte")
        default: return "\(mode)"
        }
    }

    private var executionModeIcon: String {
        triggerType == "calendar" ? "house.fill" : "iphone"
    }

    // MARK: - Weekday Picker

    @ViewBuilder
    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "rule.editor.weekdays", defaultValue: "Giorni"))
                .font(.subheadline)
            HStack(spacing: 6) {
                ForEach(weekdayItems, id: \.day) { item in
                    let selected = selectedWeekdays.contains(item.day)
                    Button {
                        if selected {
                            selectedWeekdays.remove(item.day)
                        } else {
                            selectedWeekdays.insert(item.day)
                        }
                    } label: {
                        Text(item.label)
                            .font(.caption.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle().fill(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                            )
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var weekdayItems: [(day: Int, label: String)] {
        [
            (1, "D"), (2, "L"), (3, "M"), (4, "M"),
            (5, "G"), (6, "V"), (7, "S"),
        ]
    }
}
