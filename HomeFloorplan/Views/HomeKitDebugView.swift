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
        .searchable(text: $searchText, prompt: "Filtra accessori")
        .navigationTitle("Debug HomeKit")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var filteredAccessories: [HMAccessory] {
        let sorted = homeKit.allAccessories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Dettaglio accessorio

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
                    Label("Copia diagnostica", systemImage: "doc.on.doc")
                }
            }
        }
        .alert("Diagnostica copiata negli appunti", isPresented: $copyConfirm) {
            Button("OK", role: .cancel) {}
        }
    }
    
    // MARK: Sezione identità
    
    @ViewBuilder
    private var identitySection: some View {
        Section("Identità") {
            kvRow("Nome", accessory.name)
            kvRow("UUID", accessory.uniqueIdentifier.uuidString)
            kvRow("Categoria (raw)", accessory.category.categoryType)
            kvRow("Categoria (display)", accessory.category.localizedDescription)
            kvRow("Adapter", adapterName)
            kvRow("Categoria UI", uiCategory.displayName)
            kvRow("Categoria AI", AccessoryCategorizer.categorize(accessory))
            kvRow("Stanza", accessory.room?.name ?? "—")
            // HMCharacteristicTypeManufacturer/Model/FirmwareVersion/SerialNumber sono
            // deprecated da iOS 11 ma restano funzionali; soppressiamo i warning qui
            // perché non esiste un'API sostitutiva pubblica per recuperare questi valori.
            kvRow("Manufacturer", accessoryInfoValue(for: "00000020-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Model", accessoryInfoValue(for: "00000021-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Firmware", accessoryInfoValue(for: "00000052-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Serial", accessoryInfoValue(for: "00000030-0000-1000-8000-0026BB765291") ?? "—")
            kvRow("Hardware", accessoryInfoValue(for: HMCharacteristicTypeHardwareVersion) ?? "—")
            kvRow("Reachable raw", accessory.isReachable ? "sì" : "no")
            kvRow("Reachable app", homeKit.isReachable(accessory) ? "sì" : "no")
            kvRow("Reachability settled", homeKit.reachabilitySettled ? "sì" : "no")
            kvRow("Reachability map", reachabilityMapText)
            kvRow("Recent command failed", homeKit.isLikelyOffline(accessory) ? "sì" : "no")
            kvRow("Bridged", accessory.isBridged ? "sì" : "no")
            kvRow("Blocked", accessory.isBlocked ? "sì" : "no")
        }
    }
    
    // MARK: Sezione servizi
    
    @ViewBuilder
    private var servicesSection: some View {
        Section("Servizi (\(accessory.services.count))") {
            ForEach(accessory.services, id: \.uniqueIdentifier) { service in
                DisclosureGroup {
                    serviceBody(service)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(service.name.isEmpty ? "Servizio" : service.name)
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
            kvRow("characteristics", "\(service.characteristics.count)")
            
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
        return mapped ? "sì" : "no"
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
