import SwiftUI
import HomeKit
import UIKit

struct HomeKitDebugView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(MatterEnergyLiveStore.self) private var matterEnergy
    @State private var searchText: String = ""
    @State private var isRunningVacuumProbe: Bool = false
    @State private var vacuumProbeReport: String?
    @State private var vacuumProbeCopied: Bool = false
    
    var body: some View {
        List {
            matterEnergySection
            matterVacuumProbeSection

            ForEach(filteredAccessories, id: \.uniqueIdentifier) { accessory in
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
        }
        .searchable(text: $searchText, prompt: Text("homekit.debug.search.prompt"))
        .navigationTitle(Text("homekit.debug.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Report Vacuum copiato", isPresented: $vacuumProbeCopied) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var matterEnergySection: some View {
        Section("Energia Matter Live") {
            Button {
                refreshMatterEnergy()
            } label: {
                if matterEnergy.isRefreshing {
                    ProgressView()
                } else {
                    Label("Aggiorna energia Matter", systemImage: "bolt.circle")
                }
            }
            .disabled(matterEnergy.isRefreshing || homeKit.currentHome == nil)

            if matterEnergy.snapshots.isEmpty {
                Text("Nessuna lettura in memoria. Usa refresh per leggere solo i device con cluster energia Matter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matterEnergy.snapshots) { snapshot in
                    matterEnergySnapshotRow(snapshot)
                }
            }

            if !matterEnergy.diagnostics.isEmpty {
                DisclosureGroup("Diagnostica (\(matterEnergy.diagnostics.count))") {
                    ForEach(matterEnergy.diagnostics, id: \.self) { diagnostic in
                        Text(diagnostic)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func matterEnergySnapshotRow(_ snapshot: MatterEnergyDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.accessoryName)
                        .font(.body.weight(.semibold))
                    Text("\(snapshot.manufacturer) · \(snapshot.source.rawValue) · \(snapshot.nodeIDText)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(snapshot.measuredAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                matterMetric("Potenza", formattedWatts(snapshot.activePowerWatts), snapshot.powerStatus, snapshot.powerLatencyMilliseconds)
                Spacer(minLength: 16)
                matterMetric("Energia", formattedKilowattHours(snapshot.cumulativeEnergyKilowattHours), snapshot.energyStatus, snapshot.energyLatencyMilliseconds)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func matterMetric(_ title: String, _ value: String, _ status: String, _ latency: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
            Text("\(status)\(latency.map { " · \($0) ms" } ?? "")")
                .font(.caption2)
                .foregroundStyle(status == "ok" ? Color.secondary : Color.red)
                .lineLimit(2)
        }
    }

    private func refreshMatterEnergy() {
        guard let home = homeKit.currentHome else {
            return
        }

        Task {
            await matterEnergy.refresh(home: home)
        }
    }

    @ViewBuilder
    private var matterVacuumProbeSection: some View {
        Section("Vacuum Matter Probe") {
            Button {
                runMatterVacuumProbe()
            } label: {
                if isRunningVacuumProbe {
                    ProgressView()
                } else {
                    Label("Esegui sonda Vacuum Matter", systemImage: "magnifyingglass")
                }
            }
            .disabled(isRunningVacuumProbe || homeKit.currentHome == nil)

            if let vacuumProbeReport {
                Button {
                    UIPasteboard.general.string = vacuumProbeReport
                    vacuumProbeCopied = true
                } label: {
                    Label("Copia report Vacuum", systemImage: "doc.on.doc")
                }

                Text(vacuumProbeReport)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Sonda read-only sui cluster Matter RVC: RVCRunMode, RVCCleanMode, RVCOperationalState e ServiceArea.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runMatterVacuumProbe() {
        guard let home = homeKit.currentHome else {
            return
        }

        isRunningVacuumProbe = true
        Task {
            let report = await MatterVacuumProbe().run(home: home)
            await MainActor.run {
                vacuumProbeReport = report.text
                isRunningVacuumProbe = false
            }
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
    @State private var isRefreshingValues: Bool = false
    @State private var refreshSummary: String?
    
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
                    Task { await refreshReadableValues() }
                } label: {
                    if isRefreshingValues {
                        ProgressView()
                    } else {
                        Label(String(localized: "homekit.debug.refreshValues", defaultValue: "Refresh Values"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingValues)
            }
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
            if let refreshSummary {
                Text(refreshSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if let knownDescription = knownHomeKitDescription(forServiceType: service.serviceType) {
                kvRow("known service", knownDescription)
            }
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
            if let knownDescription = knownHomeKitDescription(forCharacteristicType: ch.characteristicType) {
                Text(knownDescription)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("value: \(diagnosticValueText(homeKit.value(for: ch) ?? ch.value))")
                .font(.caption2)
            if let dataSummary = dataDiagnosticSummary(homeKit.value(for: ch) ?? ch.value) {
                Text(dataSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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

    private func knownHomeKitDescription(forServiceType type: String) -> String? {
        switch normalizedUUID(type) {
        case "00000236-0000-1000-8000-0026BB765291":
            return "HomeKit Data Stream Transport Management"
        case "E863F007-079E-48FF-8F27-9C2605A29F52":
            return "Eve custom service"
        case "E863F008-079E-48FF-8F27-9C2605A29F52":
            return "Eve Energy custom service"
        default:
            return nil
        }
    }

    private func knownHomeKitDescription(forCharacteristicType type: String) -> String? {
        switch normalizedUUID(type) {
        case "00000234-0000-1000-8000-0026BB765291":
            return "HomeKit Data Stream transport configuration; not a power/energy reading."
        case "00000235-0000-1000-8000-0026BB765291":
            return "HomeKit Data Stream transport setup; not a power/energy reading."
        case "E863F10A-079E-48FF-8F27-9C2605A29F52":
            return "Eve voltage reading, likely volts (V)."
        case "E863F10C-079E-48FF-8F27-9C2605A29F52":
            return "Eve energy/power counter candidate; verify against Eve app."
        case "E863F10D-079E-48FF-8F27-9C2605A29F52":
            return "Eve power reading, likely watts (W)."
        case "E863F116-079E-48FF-8F27-9C2605A29F52":
            return "Eve history/status data payload."
        case "E863F117-079E-48FF-8F27-9C2605A29F52":
            return "Eve history request/response payload."
        case "E863F11A-079E-48FF-8F27-9C2605A29F52":
            return "Eve outlet-specific counter/state value; verify before product use."
        case "E863F11C-079E-48FF-8F27-9C2605A29F52",
             "E863F11D-079E-48FF-8F27-9C2605A29F52",
             "E863F121-079E-48FF-8F27-9C2605A29F52":
            return "Eve writable configuration/control payload."
        case "E863F126-079E-48FF-8F27-9C2605A29F52":
            return "Eve energy counter candidate; verify against Eve app."
        case "E863F131-079E-48FF-8F27-9C2605A29F52":
            return "Eve device/history metadata payload."
        default:
            return nil
        }
    }

    private func normalizedUUID(_ value: String) -> String {
        value.uppercased()
    }

    private func diagnosticValueText(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let data = value as? Data {
            return "Data(\(data.count) bytes)"
        }
        if let data = value as? NSData {
            return "Data(\(data.length) bytes)"
        }
        return String(describing: value)
    }

    private func dataDiagnosticSummary(_ value: Any?) -> String? {
        if let data = value as? Data {
            return dataDiagnosticSummary(data)
        }
        if let data = value as? NSData {
            return dataDiagnosticSummary(Data(referencing: data))
        }
        return nil
    }

    private func dataDiagnosticSummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "data: 0 bytes · hex=—" }
        let preview = data.prefix(64)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let suffix = data.count > 64 ? " …" : ""
        return "data: \(data.count) bytes · hex=\(preview)\(suffix)"
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

    private func refreshReadableValues() async {
        isRefreshingValues = true
        defer { isRefreshingValues = false }

        let readable = accessory.services
            .flatMap(\.characteristics)
            .filter { $0.properties.contains(HMCharacteristicPropertyReadable) }

        var successCount = 0
        var failureCount = 0

        for characteristic in readable {
            let succeeded = await readValue(characteristic)
            if succeeded, let value = characteristic.value {
                homeKit.characteristicValues[characteristic.uniqueIdentifier] = value
                successCount += 1
            } else {
                failureCount += 1
            }
        }

        refreshSummary = String(
            format: String(localized: "homekit.debug.refreshSummary",
                           defaultValue: "Refreshed %d characteristic(s), %d failed."),
            successCount,
            failureCount
        )
    }

    private func readValue(_ characteristic: HMCharacteristic) async -> Bool {
        await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                continuation.resume(returning: error == nil)
            }
        }
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
            if let knownDescription = knownHomeKitDescription(forServiceType: service.serviceType) {
                out.append("  known: \(knownDescription)")
            }
            for ch in service.characteristics {
                let value = homeKit.value(for: ch) ?? ch.value
                out.append("  • \(ch.localizedDescription)")
                out.append("      type: \(ch.characteristicType)")
                if let knownDescription = knownHomeKitDescription(forCharacteristicType: ch.characteristicType) {
                    out.append("      known: \(knownDescription)")
                }
                out.append("      value: \(diagnosticValueText(value))")
                if let dataSummary = dataDiagnosticSummary(value) {
                    out.append("      \(dataSummary)")
                }
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
