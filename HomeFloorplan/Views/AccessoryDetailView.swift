import SwiftUI
import HomeKit

/// Vista di dettaglio unificata per un accessorio HomeKit.
/// Composta in 4 sezioni dall'alto verso il basso:
/// 1. Header iconato (icona + nome + stanza + reachability)
/// 2. Quick info dell'adapter (primaryStatusText, se presente)
/// 3. Controlli specializzati (forniti dall'adapter via makeControlSection)
/// 4. Dettagli tecnici (raw characteristics, in DisclosureGroup collassabile)
struct AccessoryDetailView: View {
    let accessory: HMAccessory
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(MatterEnergyLiveStore.self) private var matterEnergy
    @Environment(\.dismiss) private var dismiss
    
    @State private var isObserving: Bool = false
    @State private var rawExpanded: Bool = false
    
    private var adapter: any AccessoryAdapter {
        AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
    }
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
    }

    private var energySnapshot: MatterEnergyDeviceSnapshot? {
        matterEnergy.snapshot(for: accessory.uniqueIdentifier)
    }
    
    @ViewBuilder
    private var quickInfoSection: some View {
        // Non mostra la sezione "Stato" generica se l'adapter ha già un control
        // specializzato (sarebbe ridondante).
        if adapter.makeControlSection(homeKit: homeKit) == nil,
           let text = adapter.primaryStatusText, !text.isEmpty {
            Section {
                HStack {
                    Text(String(localized: "accessory.detail.status", defaultValue: "Stato"))
                    Spacer()
                    Text(text)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                headerSection
                
                if let quickInfo = adapter.primaryStatusText, !quickInfo.isEmpty {
                    quickInfoSection
                }
                
                if let controlView = adapter.makeControlSection(homeKit: homeKit) {
                    Section(String(localized: "accessory.detail.controls", defaultValue: "Controls")) {
                        controlView
                    }
                }

                matterEnergySection
                
                rawSection
            }
            .navigationTitle(accessory.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
            .onAppear {
                if !isObserving {
                    homeKit.startObserving(accessoryUUIDs: [accessory.uniqueIdentifier])
                    isObserving = true
                }
            }
            .onDisappear {
                if isObserving {
                    homeKit.stopObserving(accessoryUUIDs: [accessory.uniqueIdentifier])
                    isObserving = false
                }
            }
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AccessoryIconView(iconName: iconName)
                    .foregroundStyle(AccessoryAppearance.from(adapter).statusColor)
                    .frame(width: 36, height: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessory.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(accessory.room?.name ?? "—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !homeKit.isReachable(accessory) {
                            Text("• \(String(localized: "accessory.unreachable", defaultValue: "Unreachable"))")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        } else if homeKit.isLikelyOffline(accessory) {
                            Text("• \(String(localized: "accessory.recentCommandFailed", defaultValue: "Recent command failed"))")
                                .font(.subheadline)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                Spacer()
                
                if let battery = adapter.batteryInfo {
                        BatteryBadgeView(info: battery)
                    }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func quickInfoSection(_ text: String) -> some View {
        Section {
            HStack {
                Text(String(localized: "accessory.detail.status", defaultValue: "Stato"))
                Spacer()
                Text(text)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var matterEnergySection: some View {
        if let snapshot = energySnapshot {
            Section("Energia") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        energyMetricCard(
                            title: "Potenza",
                            value: formattedWatts(snapshot.activePowerWatts),
                            symbolName: "bolt.fill",
                            accent: .yellow,
                            status: snapshot.powerStatus
                        )

                        energyMetricCard(
                            title: "Consumo",
                            value: formattedKilowattHours(snapshot.cumulativeEnergyKilowattHours),
                            symbolName: "chart.bar.fill",
                            accent: .green,
                            status: snapshot.energyStatus
                        )
                    }

                    HStack(spacing: 8) {
                        Text(snapshot.source.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(.tertiarySystemGroupedBackground))
                            )

                        Spacer()

                        Text(snapshot.measuredAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func energyMetricCard(
        title: String,
        value: String,
        symbolName: String,
        accent: Color,
        status: String
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(status == "ok" ? Color.primary : Color.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())

                Text(status == "ok" ? title : status)
                    .font(.caption2)
                    .foregroundStyle(status == "ok" ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(status == "ok" ? Color(.tertiarySystemGroupedBackground) : Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder((status == "ok" ? accent : Color.red).opacity(status == "ok" ? 0.15 : 0.35), lineWidth: 1)
                )
        )
    }
    
    private var rawSection: some View {
        Section {
            DisclosureGroup(
                String(format: String(localized: "accessory.detail.rawTitle", defaultValue: "Dettagli tecnici (%d)"), totalCharacteristicsCount),
                isExpanded: $rawExpanded
            ) {
                ForEach(accessory.services, id: \.uniqueIdentifier) { service in
                    serviceBlock(service)
                }
            }
        }
    }
    
    @ViewBuilder
    private func serviceBlock(_ service: HMService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(serviceLabel(service))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            ForEach(service.characteristics, id: \.uniqueIdentifier) { ch in
                characteristicRow(ch)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func characteristicRow(_ ch: HMCharacteristic) -> some View {
        let value = homeKit.value(for: ch) ?? ch.value
        HStack(alignment: .firstTextBaseline) {
            Text(ch.localizedDescription)
                .font(.callout)
            Spacer()
            Text(formattedValue(value))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    // MARK: - Helpers
    
    private var totalCharacteristicsCount: Int {
        accessory.services.reduce(0) { $0 + $1.characteristics.count }
    }
    
    private func serviceLabel(_ service: HMService) -> String {
        let name = service.name
        return name.isEmpty ? service.localizedDescription : name
    }
    
    private func formattedValue(_ any: Any?) -> String {
        switch any {
        case let b as Bool: return b ? "On" : "Off"
        case let i as Int: return "\(i)"
        case let d as Double: return String(format: "%.2f", d)
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case .none: return "—"
        default: return String(describing: any!)
        }
    }

    private func formattedWatts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(decimal(value, maximumFractionDigits: 1)) W"
    }

    private func formattedKilowattHours(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(decimal(value, maximumFractionDigits: 3)) kWh"
    }

    private func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
