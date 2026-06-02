import SwiftUI
import HomeKit

// MARK: - Soglie ambientali (WHO/ASHRAE)

private struct EnvThreshold {
    struct Range {
        let good: ClosedRange<Double>
        let fair: ClosedRange<Double>
    }

    static let temperature = Range(good: 18...24, fair: 15...27)
    static let humidity    = Range(good: 40...60, fair: 30...70)
    static let co2         = Range(good: 0...800,  fair: 800...1200)
    static let pm25        = Range(good: 0...12,   fair: 12...35)
    static let pm10        = Range(good: 0...20,   fair: 20...50)
    static let voc         = Range(good: 0...200,  fair: 200...400)

    enum Level: Int, Comparable {
        case good = 0, fair = 1, poor = 2
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func level(for value: Double, range: Range) -> Level {
        if range.good.contains(value) { return .good }
        if range.fair.contains(value) { return .fair }
        return .poor
    }

    static func color(for level: Level) -> Color {
        switch level {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    static func label(for level: Level) -> String {
        switch level {
        case .good: return "Ottimo"
        case .fair: return "Accettabile"
        case .poor: return "Scarso"
        }
    }
}

// MARK: - Modello per singola stanza

private struct RoomReading {
    let roomName: String
    let value: Double
}

// MARK: - Aggregato per metrica (vista globale)

private struct MetricSummary {
    enum Kind: String {
        case temperature, humidity, co2, pm25, pm10, voc, airQuality, lightLevel
    }

    let kind: Kind
    let symbol: String
    let label: String
    let unit: String

    /// Valore medio di tutte le stanze
    let average: Double
    /// Livello peggiore presente in casa
    let worstLevel: EnvThreshold.Level
    /// Stanze con valore non-ottimo (fair o poor), ordinate per gravità
    let worstRooms: [String]
    /// Stanza con il valore migliore (solo se più di una stanza)
    let bestRoom: String?
    /// Tutti i valori per stanza
    let byRoom: [RoomReading]

    var formattedAverage: String { format(average) }

    /// Etichetta leggibile delle stanze problematiche.
    /// Es: "Cucina" / "Cucina, Mansarda" / "3 stanze"
    var worstRoomsLabel: String {
        switch worstRooms.count {
        case 0: return ""
        case 1: return worstRooms[0]
        case 2: return "\(worstRooms[0]), \(worstRooms[1])"
        default: return "\(worstRooms.count) stanze"
        }
    }

    func format(_ v: Double) -> String {
        switch kind {
        case .temperature:  return String(format: "%.1f°", v)
        case .humidity:     return String(format: "%.0f%%", v)
        case .co2:          return String(format: "%.0f ppm", v)
        case .pm25, .pm10, .voc: return String(format: "%.0f µg/m³", v)
        case .airQuality:
            switch Int(v) {
            case 1: return "Ottima"; case 2: return "Buona"; case 3: return "Media"
            case 4: return "Scarsa"; case 5: return "Pessima"; default: return "—"
            }
        case .lightLevel:
            let i = Int(v)
            if i < 10 { return "Buio" }
            if i > 5000 { return "Sole" }
            return "\(i) lx"
        }
    }
}

// MARK: - EnvironmentView

/// Dashboard ambientale globale: una tile per metrica (temperatura, umidità, CO₂, …)
/// con valore medio casa, livello qualità e indicazione della stanza peggiore.
/// Tap su una tile → sheet con breakout per stanza.
struct EnvironmentView: View {

    @Environment(HomeKitService.self) private var homeKit
    @State private var selectedMetric: MetricSummary?

    /// UUID degli accessori ambientali attualmente osservati.
    @State private var observedUUIDs: Set<UUID> = []

    // MARK: Computed

    private var allSensors: [any EnvironmentReadable] {
        guard let home = homeKit.currentHome else { return [] }
        return home.accessories.compactMap { acc in
            AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? (any EnvironmentReadable)
        }
    }

    private var metrics: [MetricSummary] {
        var result: [MetricSummary] = []

        func build<T: BinaryFloatingPoint>(
            kind: MetricSummary.Kind,
            symbol: String, label: String, unit: String,
            extract: (any EnvironmentReadable) -> T?,
            range: EnvThreshold.Range,
            higherIsBetter: Bool = false
        ) {
            let rooms: [RoomReading] = allSensors.compactMap { s in
                guard let v = extract(s) else { return nil }
                let name = s.accessory.room?.name ?? "Senza stanza"
                return RoomReading(roomName: name, value: Double(v))
            }
            // Deduplica per stanza (media se più sensori nella stessa stanza)
            let byRoom = Dictionary(grouping: rooms, by: \.roomName)
                .map { RoomReading(roomName: $0.key, value: $0.value.map(\.value).reduce(0,+) / Double($0.value.count)) }
                .sorted { $0.roomName < $1.roomName }
            guard !byRoom.isEmpty else { return }

            let avg = byRoom.map(\.value).reduce(0,+) / Double(byRoom.count)
            let levels = byRoom.map { EnvThreshold.level(for: $0.value, range: range) }
            let worst = levels.max() ?? .good

            let worstRooms: [String]
            let bestRoom: String?
            if higherIsBetter {
                // Per luminosità: peggiore = valore più basso
                worstRooms = []
                bestRoom  = byRoom.count > 1 ? byRoom.max(by: { $0.value < $1.value })?.roomName : nil
            } else {
                // Raccoglie tutte le stanze con livello non-ottimo, ordinate per gravità (poor prima)
                worstRooms = byRoom
                    .filter { EnvThreshold.level(for: $0.value, range: range) > .good }
                    .sorted {
                        EnvThreshold.level(for: $0.value, range: range).rawValue >
                        EnvThreshold.level(for: $1.value, range: range).rawValue
                    }
                    .map(\.roomName)
                bestRoom  = byRoom.count > 1
                    ? byRoom.indices
                        .filter { EnvThreshold.level(for: byRoom[$0].value, range: range) == .good }
                        .first.map { byRoom[$0].roomName }
                    : nil
            }

            result.append(MetricSummary(
                kind: kind, symbol: symbol, label: label, unit: unit,
                average: avg, worstLevel: worst,
                worstRooms: worst > .good ? worstRooms : [],
                bestRoom: bestRoom,
                byRoom: byRoom
            ))
        }

        build(kind: .temperature, symbol: "thermometer.medium", label: "Temperatura", unit: "°C",
              extract: \.environmentTemperature, range: EnvThreshold.temperature)
        build(kind: .humidity, symbol: "humidity", label: "Umidità", unit: "%",
              extract: \.environmentHumidity, range: EnvThreshold.humidity)
        build(kind: .co2, symbol: "carbon.dioxide.cloud", label: "CO₂", unit: "ppm",
              extract: \.environmentCO2, range: EnvThreshold.co2)
        build(kind: .pm25, symbol: "microbe", label: "PM2.5", unit: "µg/m³",
              extract: \.environmentPM25, range: EnvThreshold.pm25)
        build(kind: .pm10, symbol: "microbe.fill", label: "PM10", unit: "µg/m³",
              extract: \.environmentPM10, range: EnvThreshold.pm10)
        build(kind: .voc, symbol: "flame", label: "VOC", unit: "µg/m³",
              extract: \.environmentVOC, range: EnvThreshold.voc)

        // Qualità aria: usa scala numerica 1-5
        let aqRooms: [RoomReading] = allSensors.compactMap { s in
            guard let q = s.environmentAirQuality else { return nil }
            let v: Double
            switch q {
            case "Ottima": v = 1; case "Buona": v = 2; case "Media": v = 3
            case "Scarsa": v = 4; case "Pessima": v = 5; default: return nil
            }
            return RoomReading(roomName: s.accessory.room?.name ?? "Senza stanza", value: v)
        }
        let aqByRoom = Dictionary(grouping: aqRooms, by: \.roomName)
            .map { RoomReading(roomName: $0.key, value: $0.value.map(\.value).max() ?? 0) }
            .sorted { $0.roomName < $1.roomName }
        if !aqByRoom.isEmpty {
            let avgAq = aqByRoom.map(\.value).reduce(0,+) / Double(aqByRoom.count)
            let worstAq = aqByRoom.max(by: { $0.value < $1.value })
            let lvl: EnvThreshold.Level = (worstAq?.value ?? 0) >= 4 ? .poor : (worstAq?.value ?? 0) >= 3 ? .fair : .good
            let aqWorstRooms = lvl > .good
                ? aqByRoom
                    .filter { $0.value >= 3 }
                    .sorted { $0.value > $1.value }
                    .map(\.roomName)
                : []
            result.append(MetricSummary(
                kind: .airQuality, symbol: "aqi.medium", label: "Qualità aria", unit: "",
                average: avgAq, worstLevel: lvl,
                worstRooms: aqWorstRooms,
                bestRoom: nil,
                byRoom: aqByRoom
            ))
        }

        // Luminosità (solo informativa, sempre verde)
        build(kind: .lightLevel, symbol: "sun.max", label: "Luminosità", unit: "lx",
              extract: { s in s.environmentLightLevel.map(Double.init) },
              range: EnvThreshold.Range(good: 0...100000, fair: 0...100000),
              higherIsBetter: true)

        return result
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if metrics.isEmpty {
                    emptyState
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Ambiente")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $selectedMetric) { metric in
                MetricDetailSheet(metric: metric)
            }
        }
        .task {
            // Avvia l'osservazione di tutti gli accessori ambientali.
            // startObserving fa readValue iniziale + abilita notifiche push su ogni
            // caratteristica → la view si aggiorna in tempo reale senza polling.
            let uuids = Set(allSensors.map { $0.accessory.uniqueIdentifier })
            guard !uuids.isEmpty else { return }
            observedUUIDs = uuids
            homeKit.startObserving(accessoryUUIDs: uuids)
        }
        .onDisappear {
            // Smette di osservare per non consumare risorse inutilmente.
            if !observedUUIDs.isEmpty {
                homeKit.stopObserving(accessoryUUIDs: observedUUIDs)
                observedUUIDs = []
            }
        }
    }

    // MARK: Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun sensore ambientale", systemImage: "leaf.slash")
        } description: {
            Text("Aggiungi sensori di temperatura, umidità o qualità dell'aria in HomeKit per monitorarli qui.")
        }
    }

    private var scrollContent: some View {
        ScrollView {
            // Layout: prima tile grande (temperatura se presente, altrimenti prima disponibile),
            // poi griglia 2 colonne per le restanti.
            LazyVStack(spacing: 16) {
                if let hero = metrics.first {
                    HeroMetricTile(metric: hero) { selectedMetric = hero }
                }
                if metrics.count > 1 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(metrics.dropFirst(), id: \.kind.rawValue) { metric in
                            SmallMetricTile(metric: metric) { selectedMetric = metric }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Tile hero (grande, prima metrica)

private struct HeroMetricTile: View {
    let metric: MetricSummary
    let onTap: () -> Void

    private var color: Color { EnvThreshold.color(for: metric.worstLevel) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: metric.symbol)
                        .font(.title3)
                        .foregroundStyle(color)
                    Text(metric.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    LevelBadge(level: metric.worstLevel)
                }

                Spacer().frame(height: 16)

                // Valore principale
                Text(metric.formattedAverage)
                    .font(.system(size: 52, weight: .light, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())

                Text("media casa · \(metric.byRoom.count) stanz\(metric.byRoom.count == 1 ? "a" : "e")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Spacer().frame(height: 14)

                // Barra per stanze
                RoomBarChart(metric: metric)

                // Nota stanze problematiche
                if !metric.worstRooms.isEmpty {
                    Spacer().frame(height: 10)
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(color)
                        Text("Attenzione: \(metric.worstRoomsLabel)")
                            .font(.caption2)
                            .foregroundStyle(color)
                            .lineLimit(2)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(color.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tile piccola (griglia 2 colonne)

private struct SmallMetricTile: View {
    let metric: MetricSummary
    let onTap: () -> Void

    private var color: Color { EnvThreshold.color(for: metric.worstLevel) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: metric.symbol)
                        .font(.subheadline)
                        .foregroundStyle(color)
                    Spacer()
                    LevelBadge(level: metric.worstLevel)
                }

                Text(metric.formattedAverage)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())

                Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !metric.worstRooms.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(color)
                        Text(metric.worstRoomsLabel)
                            .font(.caption2)
                            .foregroundStyle(color)
                            .lineLimit(2)
                    }
                } else {
                    // Placeholder per altezza uniforme
                    Text(" ").font(.caption2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(color.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Barra orizzontale per stanza (nella hero tile)

private struct RoomBarChart: View {
    let metric: MetricSummary

    private var maxVal: Double { metric.byRoom.map(\.value).max() ?? 1 }
    private var minVal: Double { metric.byRoom.map(\.value).min() ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(metric.byRoom, id: \.roomName) { reading in
                let level = levelFor(reading.value)
                let color = EnvThreshold.color(for: level)
                HStack(spacing: 8) {
                    Text(reading.roomName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                        .lineLimit(1)

                    GeometryReader { geo in
                        let fraction = maxVal > minVal
                            ? (reading.value - minVal) / (maxVal - minVal)
                            : 0.5
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(color.opacity(0.15))
                                .frame(height: 6)
                            Capsule()
                                .fill(color)
                                .frame(width: max(6, geo.size.width * fraction), height: 6)
                        }
                    }
                    .frame(height: 6)

                    Text(metric.format(reading.value))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color)
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)
                }
            }
        }
    }

    private func levelFor(_ v: Double) -> EnvThreshold.Level {
        switch metric.kind {
        case .temperature: return EnvThreshold.level(for: v, range: EnvThreshold.temperature)
        case .humidity:    return EnvThreshold.level(for: v, range: EnvThreshold.humidity)
        case .co2:         return EnvThreshold.level(for: v, range: EnvThreshold.co2)
        case .pm25:        return EnvThreshold.level(for: v, range: EnvThreshold.pm25)
        case .pm10:        return EnvThreshold.level(for: v, range: EnvThreshold.pm10)
        case .voc:         return EnvThreshold.level(for: v, range: EnvThreshold.voc)
        case .airQuality:  return v >= 4 ? .poor : v >= 3 ? .fair : .good
        case .lightLevel:  return .good
        }
    }
}

// MARK: - Badge livello

private struct LevelBadge: View {
    let level: EnvThreshold.Level

    var body: some View {
        Text(EnvThreshold.label(for: level))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(EnvThreshold.color(for: level))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(EnvThreshold.color(for: level).opacity(0.12))
            )
    }
}

// MARK: - Sheet dettaglio per stanza

private struct MetricDetailSheet: View {
    let metric: MetricSummary
    @Environment(\.dismiss) private var dismiss

    private var color: Color { EnvThreshold.color(for: metric.worstLevel) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Valore medio casa
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Media casa")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(metric.formattedAverage)
                                .font(.system(.largeTitle, design: .rounded).weight(.light))
                                .foregroundStyle(color)
                        }
                        Spacer()
                        LevelBadge(level: metric.worstLevel)
                    }
                    .padding(.vertical, 4)
                }

                Section("Per stanza") {
                    ForEach(metric.byRoom.sorted { $0.value > $1.value }, id: \.roomName) { reading in
                        let level = levelFor(reading.value)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reading.roomName)
                                    .font(.body)
                                Text(EnvThreshold.label(for: level))
                                    .font(.caption)
                                    .foregroundStyle(EnvThreshold.color(for: level))
                            }
                            Spacer()
                            Text(metric.format(reading.value))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(EnvThreshold.color(for: level))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(metric.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }

    private func levelFor(_ v: Double) -> EnvThreshold.Level {
        switch metric.kind {
        case .temperature: return EnvThreshold.level(for: v, range: EnvThreshold.temperature)
        case .humidity:    return EnvThreshold.level(for: v, range: EnvThreshold.humidity)
        case .co2:         return EnvThreshold.level(for: v, range: EnvThreshold.co2)
        case .pm25:        return EnvThreshold.level(for: v, range: EnvThreshold.pm25)
        case .pm10:        return EnvThreshold.level(for: v, range: EnvThreshold.pm10)
        case .voc:         return EnvThreshold.level(for: v, range: EnvThreshold.voc)
        case .airQuality:  return v >= 4 ? .poor : v >= 3 ? .fair : .good
        case .lightLevel:  return .good
        }
    }
}

// MARK: - Identifiable per sheet

extension MetricSummary: Identifiable {
    var id: String { kind.rawValue }
}
