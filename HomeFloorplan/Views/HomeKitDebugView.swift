import SwiftUI
import HomeKit
import UIKit

struct HomeKitDebugView: View {
    @Environment(HomeKitService.self) private var homeKit
    @State private var searchText: String = ""
    
    var body: some View {
        List(filteredAccessories, id: \.uniqueIdentifier) { accessory in
            NavigationLink {
                HomeKitDebugAccessoryDetail(accessory: accessory)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessory.name).font(.body)
                    Text(accessory.category.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("homekit.debug.search.prompt"))
        .navigationTitle(Text("homekit.debug.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var filteredAccessories: [HMAccessory] {
        let sorted = homeKit.allAccessories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Accessory detail

struct HomeKitDebugAccessoryDetail: View {
    let accessory: HMAccessory
    @Environment(HomeKitService.self) private var homeKit
    @State private var copyConfirm: Bool = false
    
    var body: some View {
        List {
            identitySection
            servicesSection
        }
        .navigationTitle(accessory.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = diagnosticDump()
                    copyConfirm = true
                } label: {
                    Label(String(localized: "homekit.debug.copyDiagnostic", defaultValue: "Copy Diagnostic"), systemImage: "doc.on.doc")
                }
            }
        }
        .alert(String(localized: "homekit.debug.copyConfirm", defaultValue: "Diagnostic copied to clipboard"), isPresented: $copyConfirm) {
            Button("OK", role: .cancel) {}
        }
    }
    
    // MARK: Identity section
    
    @ViewBuilder
    private var identitySection: some View {
        Section(String(localized: "homekit.debug.section.identity", defaultValue: "Identity")) {
            kvRow(String(localized: "homekit.debug.name", defaultValue: "Name"), accessory.name)
            kvRow("UUID", accessory.uniqueIdentifier.uuidString)
            kvRow(String(localized: "homekit.debug.categoryRaw", defaultValue: "Category (raw)"), accessory.category.categoryType)
            kvRow(String(localized: "homekit.debug.categoryDisplay", defaultValue: "Category (display)"), accessory.category.localizedDescription)
            kvRow("Adapter", adapterName)
            kvRow(String(localized: "homekit.debug.uiCategory", defaultValue: "UI category"), uiCategory.displayName)
            kvRow(String(localized: "homekit.debug.aiCategory", defaultValue: "AI category"), AccessoryCategorizer.categorize(accessory))
            kvRow(String(localized: "homekit.debug.room", defaultValue: "Room"), accessory.room?.name ?? "—")
            // HMCharacteristicTypeManufacturer/Model/FirmwareVersion/SerialNumber sono
            // deprecated da iOS 11 ma restano funzionali; soppressiamo i warning qui
            // perché non esiste un'API sostitutiva pubblica per recuperare questi valori.
            kvRow("Manufacturer", accessoryInfoValue(for: "00000020-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Model", accessoryInfoValue(for: "00000021-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Firmware", accessoryInfoValue(for: "00000052-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Serial", accessoryInfoValue(for: "00000030-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Hardware", accessoryInfoValue(for: HMCharacteristicTypeHardwareVersion) ?? "—")
            kvRow(String(localized: "homekit.debug.battery", defaultValue: "Battery"), batteryText)
            kvRow(String(localized: "homekit.debug.reachableRaw", defaultValue: "Reachable raw"), yesNo(accessory.isReachable))
            kvRow(String(localized: "homekit.debug.reachableApp", defaultValue: "Reachable app"), yesNo(homeKit.isReachable(accessory)))
            kvRow(String(localized: "homekit.debug.reachabilitySettled", defaultValue: "Reachability settled"), yesNo(homeKit.reachabilitySettled))
            kvRow(String(localized: "homekit.debug.reachabilityMap", defaultValue: "Reachability map"), reachabilityMapText)
            kvRow(String(localized: "homekit.debug.recentCommandFailed", defaultValue: "Recent command failed"), yesNo(homeKit.isLikelyOffline(accessory)))
            kvRow(String(localized: "homekit.debug.bridged", defaultValue: "Bridged"), yesNo(accessory.isBridged))
            kvRow(String(localized: "homekit.debug.blocked", defaultValue: "Blocked"), yesNo(accessory.isBlocked))
        }
    }
    
    // MARK: Services section
    
    @ViewBuilder
    private var servicesSection: some View {
        Section(String(format: String(localized: "homekit.debug.services.count", defaultValue: "Services (%lld)"), accessory.services.count)) {
            ForEach(accessory.services, id: \.uniqueIdentifier) { service in
                DisclosureGroup {
                    serviceBody(service)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(service.name.isEmpty ? String(localized: "homekit.debug.service", defaultValue: "Service") : service.name)
                                .font(.body)
                            if service.isPrimaryService {
                                Text("PRIMARY")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(service.serviceType)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func serviceBody(_ service: HMService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kvRow("serviceType (raw)", service.serviceType)
            kvRow("uniqueIdentifier", service.uniqueIdentifier.uuidString)
            kvRow(String(localized: "homekit.debug.characteristics", defaultValue: "characteristics"), "\(service.characteristics.count)")
            
            ForEach(service.characteristics, id: \.uniqueIdentifier) { ch in
                Divider()
                characteristicRow(ch)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func characteristicRow(_ ch: HMCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ch.localizedDescription).font(.callout).bold()
            Text("type: \(ch.characteristicType)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("value: \(String(describing: homeKit.value(for: ch) ?? ch.value))")
                .font(.caption2)
            Text("props: \(ch.properties.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let format = ch.metadata?.format {
                Text("format: \(format), min=\(metadataNumber(ch.metadata?.minimumValue)), max=\(metadataNumber(ch.metadata?.maximumValue)), step=\(metadataNumber(ch.metadata?.stepValue)), units=\(ch.metadata?.units ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: Helpers
    
    @ViewBuilder
    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
    
    private func accessoryInfoValue(for charType: String) -> String? {
        guard let infoService = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }) else {
            return nil
        }
        guard let ch = infoService.characteristics.first(where: { $0.characteristicType == charType }) else {
            return nil
        }
        let raw = homeKit.value(for: ch) ?? ch.value
        return raw.map { "\($0)" }
    }
    
    private func metadataNumber(_ n: NSNumber?) -> String {
        guard let n else { return "—" }
        return n.stringValue
    }

    private func yesNo(_ value: Bool) -> String {
        value
        ? String(localized: "common.yes", defaultValue: "Yes")
        : String(localized: "common.no", defaultValue: "No")
    }

    private var batteryText: String {
        guard let battery = BatteryReader.read(from: accessory, via: homeKit) else {
            return "—"
        }
        if let level = battery.level {
            return battery.isLow
            ? "\(level)% low"
            : "\(level)%"
        }
        return battery.isLow ? "Low" : "OK"
    }
    
    // MARK: Diagnostic dump (clipboard)
    
    private func diagnosticDump() -> String {
        var out: [String] = []
        out.append("=== HomeKit Diagnostic ===")
        out.append("Name: \(accessory.name)")
        out.append("UUID: \(accessory.uniqueIdentifier)")
        out.append("Category raw: \(accessory.category.categoryType)")
        out.append("Category display: \(accessory.category.localizedDescription)")
        out.append("Adapter: \(adapterName)")
        out.append("UI category: \(uiCategory.rawValue)")
        out.append("AI category: \(AccessoryCategorizer.categorize(accessory))")
        out.append("Room: \(accessory.room?.name ?? "—")")
        out.append("Manufacturer: \(accessoryInfoValue(for: "00000020-0000-1000-8000-0026BB765291") ?? "—")")
        out.append("Model: \(accessoryInfoValue(for: "00000021-0000-1000-8000-0026BB765291") ?? "—")")
        out.append("Firmware: \(accessoryInfoValue(for: "00000052-0000-1000-8000-0026BB765291") ?? "—")")
        out.append("Hardware: \(accessoryInfoValue(for: HMCharacteristicTypeHardwareVersion) ?? "—")")
        out.append("Battery: \(batteryText)")
        out.append("Reachable raw: \(accessory.isReachable)")
        out.append("Reachable app: \(homeKit.isReachable(accessory))")
        out.append("Reachability settled: \(homeKit.reachabilitySettled)")
        out.append("Reachability map: \(reachabilityMapText)")
        out.append("Recent command failed: \(homeKit.isLikelyOffline(accessory))")
        out.append("Bridged: \(accessory.isBridged)  Blocked: \(accessory.isBlocked)")
        out.append("")
        out.append("Services (\(accessory.services.count)):")
        for service in accessory.services {
            out.append("─ Service: \(service.name.isEmpty ? "?" : service.name)  primary=\(service.isPrimaryService)")
            out.append("  serviceType: \(service.serviceType)")
            for ch in service.characteristics {
                let value = homeKit.value(for: ch) ?? ch.value
                out.append("  • \(ch.localizedDescription)")
                out.append("      type: \(ch.characteristicType)")
                out.append("      value: \(String(describing: value))")
                out.append("      props: \(ch.properties.joined(separator: ", "))")
                if let fmt = ch.metadata?.format {
                    out.append("      meta: format=\(fmt) min=\(metadataNumber(ch.metadata?.minimumValue)) max=\(metadataNumber(ch.metadata?.maximumValue)) step=\(metadataNumber(ch.metadata?.stepValue)) units=\(ch.metadata?.units ?? "—")")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private var reachabilityMapText: String {
        guard let mapped = homeKit.reachabilityMap[accessory.uniqueIdentifier] else {
            return "—"
        }
        return yesNo(mapped)
    }
    
    @MainActor
    private var adapter: any AccessoryAdapter {
        AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
    }
    
    @MainActor
    private var adapterName: String {
        String(describing: type(of: adapter))
    }
    
    @MainActor
    private var uiCategory: AccessoryCategory {
        AccessoryCategory.classify(adapter: adapter)
    }
}
