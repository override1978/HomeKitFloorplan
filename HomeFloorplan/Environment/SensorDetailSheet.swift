import SwiftUI
import Charts
import SwiftData

// MARK: - ChartMode

private enum ChartMode: String, CaseIterable {
    case average   = "average"
    case perSensor = "perSensor"

    var label: String {
        switch self {
        case .average:   return String(localized: "chart.mode.average",    defaultValue: "Average")
        case .perSensor: return String(localized: "chart.mode.perSensor",  defaultValue: "Per sensor")
        }
    }
}

// MARK: - SensorDetailSheet

/// Sheet con il dettaglio storico di un sensore: grafico 24h, min/max/media.
/// Le letture vengono caricate internamente all'apertura per evitare
/// il problema di SwiftUI che batchizza gli aggiornamenti di @State
/// (se passate dall'esterno il grafico risultava vuoto alla prima apertura).
struct SensorDetailSheet: View {

    let sensor: SensorData
    let modelContainer: ModelContainer

    @Environment(\.dismiss) private var dismiss

    @State private var readings: [SensorReading] = []
    @State private var chartMode: ChartMode = .average

    // MARK: - Dati per modalità media

    /// Letture aggregate per timestamp (media tra sensori nella stessa finestra temporale).
    /// Nel caso di un solo sensore coincide esattamente con `readings`.
    private var averagedReadings: [(timestamp: Date, value: Double)] {
        // Raggruppa per intervallo di 15 minuti, poi calcola la media
        let grouped = Dictionary(grouping: readings) { reading -> Date in
            let interval: TimeInterval = 15 * 60
            return Date(timeIntervalSinceReferenceDate:
                (reading.timestamp.timeIntervalSinceReferenceDate / interval).rounded(.down) * interval)
        }
        return grouped
            .map { (key, vals) in (timestamp: key, value: vals.map(\.value).reduce(0, +) / Double(vals.count)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Dati per modalità per sensore

    /// Letture raggruppate per accessoryUUID, ordinate per timestamp.
    private var readingsByAccessory: [(uuid: String, readings: [SensorReading])] {
        let grouped = Dictionary(grouping: readings, by: \.accessoryUUID)
        return grouped
            .map { (uuid: $0.key, readings: $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { $0.uuid < $1.uuid }
    }

    // MARK: - Statistiche (calcolate sempre sulla media)

    private var minValue: Double? { averagedReadings.map(\.value).min() }
    private var maxValue: Double? { averagedReadings.map(\.value).max() }
    private var avgValue: Double? {
        guard !averagedReadings.isEmpty else { return nil }
        return averagedReadings.map(\.value).reduce(0, +) / Double(averagedReadings.count)
    }

    private var urgency: SensorUrgency { sensor.urgency }
    private var accentColor: Color { urgency == .normal ? .accentColor : urgency.color }

    // Palette colori per le linee multi-sensore
    private let sensorColors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    currentValueHeader
                    chartSection
                    if !averagedReadings.isEmpty {
                        statsRow
                    }
                }
                .padding(16)
            }
            .navigationTitle(sensor.serviceType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                }
            }
            .onAppear { loadReadings() }
        }
    }

    // MARK: - Caricamento letture

    private func loadReadings() {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let typeRaw = sensor.serviceType.rawValue
        let room    = sensor.roomName

        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.serviceTypeRaw == typeRaw &&
                $0.roomName == room &&
                $0.timestamp > cutoff
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        readings = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Subviews

    private var currentValueHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: sensor.serviceType.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(accentColor)
                Text(sensor.serviceType.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if urgency != .normal {
                    Label(urgency.label, systemImage: urgency.sfSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(urgency.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(urgency.color.opacity(0.12)))
                }
            }

            // Valore attuale grande
            Text(sensor.formattedValue)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())

            Text(String(localized: "sensor.detail.room", defaultValue: "Room: \(sensor.roomName)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header con titolo e toggle (solo se più sensori)
            HStack {
                Text(String(localized: "sensor.detail.last24h", defaultValue: "Last 24 hours"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if sensor.sourceCount > 1 {
                    Picker("", selection: $chartMode) {
                        ForEach(ChartMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 4)

            if readings.isEmpty {
                ContentUnavailableView(
                    String(localized: "sensor.detail.noHistory.title", defaultValue: "No historical data"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(String(localized: "sensor.detail.noHistory.description", defaultValue: "Historical data will appear here after the first sample."))
                )
                .frame(height: 200)
            } else if chartMode == .average || sensor.sourceCount <= 1 {
                averageChart
            } else {
                perSensorChart
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Grafico media (vista default)

    private var averageChart: some View {
        Chart {
            // Area gradient
            ForEach(averagedReadings, id: \.timestamp) { point in
                AreaMark(
                    x: .value("Ora", point.timestamp),
                    y: .value("Valore", point.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor.opacity(0.3), accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }

            // Linea principale
            ForEach(averagedReadings, id: \.timestamp) { point in
                LineMark(
                    x: .value("Ora", point.timestamp),
                    y: .value("Valore", point.value)
                )
                .foregroundStyle(accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }

            // Soglia warning
            RuleMark(y: .value("Attenzione", sensor.warningThreshold))
                .foregroundStyle(.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Soglia danger
            RuleMark(y: .value("Critico", sensor.dangerThreshold))
                .foregroundStyle(.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXAxis { sharedXAxis }
        .chartYAxis { sharedYAxis }
        .frame(height: 200)
    }

    // MARK: Grafico per sensore (linee distinte)

    private var perSensorChart: some View {
        VStack(spacing: 10) {
            Chart {
                ForEach(Array(readingsByAccessory.enumerated()), id: \.element.uuid) { index, group in
                    let color = sensorColors[index % sensorColors.count]
                    ForEach(group.readings, id: \.id) { reading in
                        LineMark(
                            x: .value("Ora", reading.timestamp),
                            y: .value("Valore", reading.value),
                            series: .value("Sensore", group.uuid)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }

                // Soglia warning
                RuleMark(y: .value("Attenzione", sensor.warningThreshold))
                    .foregroundStyle(.orange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // Soglia danger
                RuleMark(y: .value("Critico", sensor.dangerThreshold))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXAxis { sharedXAxis }
            .chartYAxis { sharedYAxis }
            .frame(height: 200)

            // Legenda sensori
            sensorLegend
        }
    }

    // MARK: Legenda sensori

    private var sensorLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(readingsByAccessory.enumerated()), id: \.element.uuid) { index, group in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(sensorColors[index % sensorColors.count])
                        .frame(width: 16, height: 3)
                    Text(String(format: String(localized: "sensor.detail.sensorIndex",
                                               defaultValue: "Sensor %d"),
                                index + 1))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = group.readings.last {
                        Text(formatStat(last.value))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Assi condivisi

    private var sharedXAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    private var sharedYAxis: some AxisContent {
        AxisMarks { _ in
            AxisGridLine()
            AxisValueLabel()
        }
    }

    // MARK: - Statistiche

    private var statsRow: some View {
        HStack(spacing: 12) {
            if let min = minValue {
                StatPill(label: "Min", value: formatStat(min))
            }
            if let avg = avgValue {
                StatPill(label: "Media", value: formatStat(avg))
            }
            if let max = maxValue {
                StatPill(label: "Max", value: formatStat(max))
            }
        }
    }

    private func formatStat(_ value: Double) -> String {
        let unit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        ) ?? .celsius
        switch sensor.serviceType {
        case .temperature:    return unit.format(value)
        case .humidity:       return String(format: "%.0f%%", value)
        case .airQuality:     return String(format: "%.1f", value)
        case .carbonMonoxide: return String(format: "%.1f ppm", value)
        case .carbonDioxide:  return String(format: "%.0f ppm", value)
        case .smoke:
            return value >= 1
                ? String(localized: "smoke.detected",    defaultValue: "Sì")
                : String(localized: "smoke.notDetected", defaultValue: "No")
        case .vocDensity:         return String(format: "%.0f µg/m³", value)
        case .pm25, .pm10:        return String(format: "%.0f µg/m³", value)
        case .lightSensor:        return String(format: "%.0f lux", value)
        case .outdoorTemperature: return unit.format(value)
        case .outdoorHumidity:    return String(format: "%.0f%%", value)
        }
    }
}

// MARK: - StatPill

/// Pillola statistica con label e valore.
private struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }
}
