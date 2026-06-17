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
    @Environment(\.dismiss) private var dismiss
    
    @State private var isObserving: Bool = false
    @State private var rawExpanded: Bool = false
    
    private var adapter: any AccessoryAdapter {
        AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
    }
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
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
                    Section(String(localized: "accessory.detail.controls", defaultValue: "Controlli")) {
                        controlView
                    }
                }
                
                rawSection
            }
            .navigationTitle(accessory.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "button.done", defaultValue: "Fine")) { dismiss() }
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
}
