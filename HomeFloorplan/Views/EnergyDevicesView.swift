import SwiftUI
import SwiftData

// MARK: - EnergyDeviceSummary

/// Una presa misurata riassunta per le view energia: identità, stanza,
/// potenza live e i giornalieri della finestra. Costruita una volta sola
/// (stessa logica per dashboard e dettaglio) da righe `EnergySample` + gli
/// snapshot live di `MatterEnergyLiveStore`.
struct EnergyDeviceSummary: Identifiable {
    let id: String
    let name: String
    let roomName: String
    let liveWatts: Double?
    let days: [EnergyDayTotal]

    var todayKilowattHours: Double { days.last?.kilowattHours ?? 0 }
    var yesterdayKilowattHours: Double { days.dropLast().last?.kilowattHours ?? 0 }

    static func build(samples: [EnergySample],
                      liveSnapshots: [MatterEnergyDeviceSnapshot],
                      windowDays: Int) -> [EnergyDeviceSummary] {
        Dictionary(grouping: samples.filter { $0.deviceID != EnergySample.houseMeterDeviceID },
                   by: \.deviceID)
            .compactMap { deviceID, rows -> EnergyDeviceSummary? in
                guard let latest = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                let points = rows.map {
                    EnergyStatsPoint(timestamp: $0.timestamp,
                                     cumulativeKilowattHours: $0.cumulativeKilowattHours)
                }
                let live = liveSnapshots.first { $0.id == deviceID }
                return EnergyDeviceSummary(
                    id: deviceID,
                    name: live?.accessoryName ?? latest.accessoryName,
                    roomName: latest.roomName,
                    liveWatts: live?.activePowerWatts,
                    days: EnergyStatsBuilder.dailyTotals(points: points, days: windowDays)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - EnergyDevicesView

/// Il dettaglio per accessorio, fuori dalla dashboard: totale delle prese
/// misurate in testa, poi una card per presa raggruppate per stanza HomeKit —
/// W live, oggi/ieri coi costi, sparkline della settimana. Si arriva qui dal
/// biglietto «Prese misurate» della dashboard.
struct EnergyDevicesView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(MatterEnergyLiveStore.self) private var matterEnergy
    @AppStorage("energy.tariffPerKWh") private var tariffPerKWh = 0.0
    @Query private var samples: [EnergySample]

    private static let windowDays = 7

    init() {
        // Un giorno in più dei 7 mostrati: i delta del primo giorno hanno
        // così il loro punto di partenza.
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.windowDays + 1),
            to: Calendar.current.startOfDay(for: .now)
        ) ?? .distantPast
        _samples = Query(
            filter: #Predicate<EnergySample> { $0.timestamp >= cutoff },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
    }

    private var devices: [EnergyDeviceSummary] {
        EnergyDeviceSummary.build(samples: samples,
                                  liveSnapshots: matterEnergy.snapshots,
                                  windowDays: Self.windowDays)
    }

    private var roomNames: [String] {
        Array(Set(devices.map(\.roomName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var totalWattsNow: Double? {
        let watts = matterEnergy.snapshots.compactMap(\.activePowerWatts)
        return watts.isEmpty ? nil : watts.reduce(0, +)
    }

    private var totalTodayKilowattHours: Double {
        devices.map(\.todayKilowattHours).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                totalCard

                ForEach(roomNames, id: \.self) { roomName in
                    Text(roomName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)

                    ForEach(devices.filter { $0.roomName == roomName }) { device in
                        deviceCard(device)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .navigationTitle(String(localized: "energy.plugs.section", defaultValue: "Measured outlets"))
        .background(Color(uiColor: .systemGroupedBackground))
        .task { await refreshLive() }
        .refreshable { await refreshLive(force: true) }
    }

    private func refreshLive(force: Bool = false) async {
        guard let home = homeKit.currentHome else { return }
        if force {
            await matterEnergy.refresh(home: home)
        } else {
            await matterEnergy.refreshIfNeeded(home: home, minimumInterval: 60)
        }
    }

    // MARK: Card

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "energy.total.today", defaultValue: "Today"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(EnergyFormat.kilowattHours(totalTodayKilowattHours))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                if let cost = EnergyFormat.cost(totalTodayKilowattHours, tariffPerKWh: tariffPerKWh) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(localized: "energy.total.cost", defaultValue: "Estimated cost"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(cost)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 6) {
                if let watts = totalWattsNow {
                    Label(EnergyFormat.watts(watts), systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Text(String(localized: "energy.measuredOnly", defaultValue: "Measured outlets only"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func deviceCard(_ device: EnergyDeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let watts = device.liveWatts {
                    Label(EnergyFormat.watts(watts), systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.yellow)
                }
            }

            HStack(alignment: .bottom, spacing: 14) {
                measure(String(localized: "energy.day.today", defaultValue: "Today"),
                        kilowattHours: device.todayKilowattHours)
                measure(String(localized: "energy.day.yesterday", defaultValue: "Yesterday"),
                        kilowattHours: device.yesterdayKilowattHours)
                Spacer(minLength: 8)
                sparkline(device.days)
                    .frame(width: 108, height: 34)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func measure(_ title: String, kilowattHours: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(EnergyFormat.kilowattHours(kilowattHours))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            if let cost = EnergyFormat.cost(kilowattHours, tariffPerKWh: tariffPerKWh) {
                Text(cost)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Sette barre, una per giorno, l'ultima (oggi) accesa. Scala sul massimo
    /// della finestra: la forma della settimana, non i valori assoluti.
    private func sparkline(_ days: [EnergyDayTotal]) -> some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let maximum = max(days.map(\.kilowattHours).max() ?? 0, 0.0001)
            let gap: CGFloat = 3
            let barWidth = (size.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count)
            for (index, day) in days.enumerated() {
                let height = max(2, size.height * CGFloat(day.kilowattHours / maximum))
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap),
                                  y: size.height - height,
                                  width: barWidth,
                                  height: height)
                let isToday = index == days.count - 1
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(isToday ? .yellow : .yellow.opacity(0.35)))
            }
        }
    }
}
