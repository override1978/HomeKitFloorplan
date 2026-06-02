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
            .navigationTitle("Soglie Alert")
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
            Label("Nessuna soglia configurata", systemImage: "slider.horizontal.3")
        } description: {
            Text("Tocca + per aggiungere una soglia di alert per un tipo di sensore.")
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
                    Text("Globale")
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
                        label: "Attenzione",
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        value: $threshold.warningValue,
                        step: stepSize,
                        range: 0...threshold.dangerValue,
                        format: { formatValue($0) }
                    )
                    .onChange(of: threshold.warningValue) { _, _ in save() }

                    ThresholdValueRow(
                        label: "Critico",
                        icon: "exclamationmark.octagon.fill",
                        color: .red,
                        value: $threshold.dangerValue,
                        step: stepSize,
                        range: threshold.warningValue...9999,
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
        case .vocDensity:     return 50.0
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
        case .vocDensity:     return String(format: "%.0f µg/m³", value)
        }
    }

    private func save() { try? modelContext.save() }
}

// MARK: - ThresholdValueRow
//
// Riga singola per una soglia: label + valore bold centrato + bottoni –/+
// Layout fisso e ben spaziato, nessuna sovrapposizione.

private struct ThresholdValueRow: View {

    let label: String
    let icon: String
    let color: Color
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

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
                Button {
                    let newVal = max(range.lowerBound, value - step)
                    value = (newVal * 10).rounded() / 10
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(value <= range.lowerBound ? Color(.tertiaryLabel) : color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(color.opacity(0.08)))
                }
                .disabled(value <= range.lowerBound)
                .buttonStyle(.plain)

                // Valore
                Text(format(value))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .center)
                    .contentTransition(.numericText())

                // Bottone +
                Button {
                    let newVal = min(range.upperBound, value + step)
                    value = (newVal * 10).rounded() / 10
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(value >= range.upperBound ? Color(.tertiaryLabel) : color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(color.opacity(0.08)))
                }
                .disabled(value >= range.upperBound)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.06))
        )
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
                Section("Tipo sensore") {
                    Picker("Tipo", selection: $selectedType) {
                        ForEach(SensorServiceType.allCases) { type in
                            Label(type.displayName, systemImage: type.sfSymbol).tag(type)
                        }
                    }
                    .onChange(of: selectedType) { _, newType in
                        warningValue = newType.defaultWarning
                        dangerValue  = newType.defaultDanger
                    }
                }

                Section("Stanza (opzionale)") {
                    TextField("es. Cucina", text: $roomName)
                    Text("Lascia vuoto per una soglia globale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Soglie") {
                    LabeledContent("Attenzione") {
                        TextField("Warning", value: $warningValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Critico") {
                        TextField("Danger", value: $dangerValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Nuova soglia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiungi") { addThreshold() }
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
