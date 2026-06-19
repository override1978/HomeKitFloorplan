import SwiftUI
import SwiftData

// MARK: - AlertThresholdSettingsView

struct AlertThresholdSettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SensorAlertThreshold.serviceTypeRaw) private var thresholds: [SensorAlertThreshold]

    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if thresholds.isEmpty {
                    emptyState
                } else {
                    thresholdList
                }
            }
            .navigationTitle(String(localized: "alertThresholds.title", defaultValue: "Alert Thresholds"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddThresholdSheet()
            }
            .onAppear {
                seedDefaultThresholdsIfNeeded()
            }
        }
    }

    // MARK: Lista

    private var thresholdList: some View {
        List {
            ForEach(SensorServiceType.allCases) { serviceType in
                let matching = thresholds.filter { $0.serviceTypeRaw == serviceType.rawValue }
                if !matching.isEmpty {
                    Section {
                        ForEach(matching) { threshold in
                            ThresholdRow(threshold: threshold)
                        }
                    } header: {
                        Label(serviceType.displayName, systemImage: serviceType.sfSymbol)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "alertThresholds.empty.title", defaultValue: "No thresholds configured"), systemImage: "slider.horizontal.3")
        } description: {
            Text(String(localized: "alertThresholds.empty.description", defaultValue: "Tap + to add an alert threshold for a sensor type."))
        }
    }

    // MARK: Seeding

    private func seedDefaultThresholdsIfNeeded() {
        guard thresholds.isEmpty else { return }
        for t in SensorAlertThreshold.defaultThresholds() { modelContext.insert(t) }
        try? modelContext.save()
    }
}

// MARK: - ThresholdRow

private struct ThresholdRow: View {

    @Bindable var threshold: SensorAlertThreshold
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {

            // ── Header: scope + toggle ──────────────────────────────────
            HStack {
                if let room = threshold.roomName {
                    Label(room, systemImage: "house")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text(String(localized: "alertThresholds.scope.global", defaultValue: "Global"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $threshold.isEnabled)
                    .labelsHidden()
                    .onChange(of: threshold.isEnabled) { _, _ in save() }
            }
            .padding(.bottom, threshold.isEnabled ? 14 : 0)

            // ── Soglie: visibili solo se abilitato ──────────────────────
            if threshold.isEnabled {
                VStack(spacing: 10) {
                    ThresholdValueRow(
                        label: String(localized: "alertThresholds.warning", defaultValue: "Warning"),
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        value: $threshold.warningValue,
                        step: stepSize,
                        range: 0...max(threshold.dangerValue, 0),
                        format: { formatValue($0) }
                    )
                    .onChange(of: threshold.warningValue) { _, _ in save() }

                    ThresholdValueRow(
                        label: String(localized: "alertThresholds.critical", defaultValue: "Critical"),
                        icon: "exclamationmark.octagon.fill",
                        color: .red,
                        value: $threshold.dangerValue,
                        step: stepSize,
                        range: min(threshold.warningValue, 9999)...9999,
                        format: { formatValue($0) }
                    )
                    .onChange(of: threshold.dangerValue) { _, _ in save() }
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Helpers

    private var stepSize: Double {
        switch threshold.serviceType {
        case .temperature:    return 0.5
        case .humidity:       return 1.0
        case .airQuality:     return 1.0
        case .carbonMonoxide: return 1.0
        case .carbonDioxide:  return 50.0
        case .smoke:          return 1.0
        case .vocDensity:         return 50.0
        case .lightSensor:        return 100.0
        case .outdoorTemperature: return 0.5
        case .outdoorHumidity:    return 1.0
        }
    }

    private func formatValue(_ value: Double) -> String {
        let unit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        ) ?? .celsius
        switch threshold.serviceType {
        case .temperature:    return unit.format(value)
        case .humidity:       return String(format: "%.0f%%", value)
        case .airQuality:     return String(format: "%.0f/5", value)
        case .carbonMonoxide: return String(format: "%.0f ppm", value)
        case .carbonDioxide:  return String(format: "%.0f ppm", value)
        case .smoke:
            return value >= 1
                ? String(localized: "smoke.detected",    defaultValue: "Sì")
                : String(localized: "smoke.notDetected", defaultValue: "No")
        case .vocDensity:         return String(format: "%.0f µg/m³", value)
        case .lightSensor:        return String(format: "%.0f lux", value)
        case .outdoorTemperature: return unit.format(value)
        case .outdoorHumidity:    return String(format: "%.0f%%", value)
        }
    }

    private func save() { try? modelContext.save() }
}

// MARK: - ThresholdValueRow
//
// Riga singola per una soglia: label + valore bold centrato + bottoni –/+
// Supporta long-press con accelerazione: dopo 0.5s il passo raddoppia ogni secondo.

private struct ThresholdValueRow: View {

    let label: String
    let icon: String
    let color: Color
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    // Long-press repeat state
    @State private var repeatTimer: Timer?
    @State private var pressStartDate: Date?

    var body: some View {
        HStack(spacing: 12) {

            // Icona + label
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            // Controllo –  valore  +
            HStack(spacing: 0) {
                // Bottone –
                StepButton(
                    systemImage: "minus",
                    color: color,
                    isDisabled: value <= range.lowerBound
                ) {
                    applyStep(-step)
                } onLongPressStart: {
                    startRepeating(direction: -1)
                } onLongPressEnd: {
                    stopRepeating()
                }

                // Valore
                Text(format(value))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .center)
                    .contentTransition(.numericText())

                // Bottone +
                StepButton(
                    systemImage: "plus",
                    color: color,
                    isDisabled: value >= range.upperBound
                ) {
                    applyStep(+step)
                } onLongPressStart: {
                    startRepeating(direction: +1)
                } onLongPressEnd: {
                    stopRepeating()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.06))
        )
    }

    // MARK: - Long-press helpers

    private func applyStep(_ delta: Double) {
        let newVal = min(range.upperBound, max(range.lowerBound, value + delta))
        value = (newVal * 10).rounded() / 10
    }

    /// Avvia un timer che ripete il passo con accelerazione.
    /// Frequenza base: ogni 0.12s. Dopo 1s continuo: ogni 0.06s (2× il passo).
    /// Dopo 2s continuo: ogni 0.04s (3× il passo).
    private func startRepeating(direction: Double) {
        // Evita di avviare un secondo timer se uno è già in esecuzione
        guard repeatTimer == nil else { return }
        pressStartDate = Date()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(pressStartDate ?? Date())
            // Scala il moltiplicatore del passo in base al tempo premuto
            let multiplier: Double
            switch elapsed {
            case ..<1.0: multiplier = 1
            case 1.0..<2.0: multiplier = 5
            default: multiplier = 20
            }
            applyStep(direction * step * multiplier)
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        pressStartDate = nil
    }
}

// MARK: - StepButton
//
// Pulsante singolo +/– con supporto tap e long-press separati.
//
// Strategia gesture:
//   - Un unico DragGesture(minimumDistance: 0) gestisce onChanged (touch-down)
//     e onEnded (finger-up). È la soluzione affidabile per rilevare il rilascio.
//   - LongPressGesture in simultaneo attiva il timer dopo 0.3s.
//   - TapGesture in simultaneo gestisce il tap rapido.
//   - Due .gesture() separati sullo stesso view si sovrascrivono in SwiftUI,
//     quindi tutto è consolidato in un unico .simultaneousGesture sequenziale.

private struct StepButton: View {
    let systemImage: String
    let color: Color
    let isDisabled: Bool
    let onTap: () -> Void
    let onLongPressStart: () -> Void
    let onLongPressEnd: () -> Void

    // Traccia se il dito è attualmente premuto per mandare onLongPressEnd al rilascio.
    @GestureState private var isPressed: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isDisabled ? Color(.tertiaryLabel) : color)
            .frame(width: 36, height: 36)
            .background(Circle().fill(color.opacity(0.08)))
            // Unico DragGesture per rilevare touch-down e finger-up
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { _ in onLongPressEnd() }
            )
            // LongPress attiva il timer dopo 0.3s di pressione continua
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in onLongPressStart() }
            )
            // Tap rapido (< 0.3s) esegue un singolo step
            .simultaneousGesture(
                TapGesture()
                    .onEnded { onTap() }
            )
            // Safety net: GestureState torna false non appena il gesto si cancella
            // (es. scroll della lista che "ruba" il tocco). Ferma sempre il timer.
            .onChange(of: isPressed) { _, pressed in
                if !pressed { onLongPressEnd() }
            }
            .opacity(isDisabled ? 0.4 : 1)
    }
}

// MARK: - AddThresholdSheet

private struct AddThresholdSheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: SensorServiceType = .temperature
    @State private var roomName: String = ""
    @State private var warningValue: Double = 28.0
    @State private var dangerValue: Double = 32.0

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "alertThresholds.sensorType.section", defaultValue: "Sensor Type")) {
                    Picker(String(localized: "alertThresholds.sensorType.picker", defaultValue: "Type"), selection: $selectedType) {
                        ForEach(SensorServiceType.allCases) { type in
                            Label(type.displayName, systemImage: type.sfSymbol).tag(type)
                        }
                    }
                    .onChange(of: selectedType) { _, newType in
                        warningValue = newType.defaultWarning
                        dangerValue  = newType.defaultDanger
                    }
                }

                Section(String(localized: "alertThresholds.room.section", defaultValue: "Room (optional)")) {
                    TextField(String(localized: "alertThresholds.room.placeholder", defaultValue: "e.g. Kitchen"), text: $roomName)
                    Text(String(localized: "alertThresholds.room.help", defaultValue: "Leave empty for a global threshold."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "alertThresholds.values.section", defaultValue: "Thresholds")) {
                    LabeledContent(String(localized: "alertThresholds.warning", defaultValue: "Warning")) {
                        TextField("Warning", value: $warningValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(String(localized: "alertThresholds.critical", defaultValue: "Critical")) {
                        TextField("Danger", value: $dangerValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle(String(localized: "alertThresholds.add.title", defaultValue: "New Threshold"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.add", defaultValue: "Add")) { addThreshold() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func addThreshold() {
        let t = SensorAlertThreshold(
            serviceType: selectedType,
            roomName: roomName.isEmpty ? nil : roomName,
            warningValue: warningValue,
            dangerValue: dangerValue
        )
        modelContext.insert(t)
        try? modelContext.save()
        dismiss()
    }
}
