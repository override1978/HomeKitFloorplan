import Foundation
import HomeKit
import SwiftUI

/// Adapter per multiprese: accessori con N servizi Outlet (es. Eve Energy Strip,
/// Meross Smart Power Strip).
/// - 1 marker per multipresa sul floorplan
/// - Marker acceso se almeno una presa è on
/// - Dettaglio mostra N row con toggle individuale per ogni presa
@MainActor
final class MultiOutletAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    init(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
    }
    
    static let outletServiceType = "00000047-0000-1000-8000-0026BB765291"
    static let onCharType = "00000025-0000-1000-8000-0026BB765291"
    static let nameCharType = "00000023-0000-1000-8000-0026BB765291"
    static let outletInUseCharType = "00000026-0000-1000-8000-0026BB765291"
    
    var markerStyle: MarkerStyle { .controllable }
    var supportsQuickToggle: Bool { false }  // No: ci sono N prese, scelta singola ambigua
    var supportsFloorplanPlacement: Bool { true }
    
    var iconName: String {
        isOn ? "powerplug.fill" : "powerplug"
    }
    
    /// Tutti i servizi Outlet dell'accessorio, ordinati come HomeKit li espone.
    var outletServices: [HMService] {
        accessory.services.filter { $0.serviceType == Self.outletServiceType }
    }
    
    /// True se ALMENO UNA presa è accesa.
    var isOn: Bool {
        outletServices.contains { isOutletOn($0) }
    }
    
    /// Conta delle prese accese.
    var onCount: Int {
        outletServices.filter { isOutletOn($0) }.count
    }
    
    var visualUrgency: MarkerUrgency {
        isOn ? .active : .normal
    }

    var markerTint: Color? {
        isOn ? .blue : nil
    }
    
    var primaryStatusText: String? {
        let total = outletServices.count
        if total == 0 { return nil }
        if onCount == 0 { return String(localized: "multioutlet.status.allOff", defaultValue: "Tutte spente") }
        if onCount == total { return String(localized: "multioutlet.status.allOn", defaultValue: "Tutte accese") }
        return "\(onCount) \(String(localized: "multioutlet.status.someOn.of", defaultValue: "di")) \(total) \(String(localized: "multioutlet.status.someOn.suffix", defaultValue: "accese"))"
    }
    
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Per-outlet helpers
    
    func isOutletOn(_ service: HMService) -> Bool {
        guard let ch = service.characteristics.first(where: { $0.characteristicType == Self.onCharType }) else {
            return false
        }
        if let v = homeKit.value(for: ch) as? Bool { return v }
        if let v = homeKit.value(for: ch) as? Int { return v == 1 }
        if let v = homeKit.value(for: ch) as? NSNumber { return v.boolValue }
        return false
    }
    
    func outletName(_ service: HMService, index: Int) -> String {
        // Prima cerca il Name characteristic, fallback su "Presa N"
        if let nameCh = service.characteristics.first(where: { $0.characteristicType == Self.nameCharType }),
           let value = homeKit.value(for: nameCh) as? String, !value.isEmpty {
            return value
        }
        return "\(String(localized: "outlet.name.fallback", defaultValue: "Presa")) \(index + 1)"
    }
    
    /// Se l'OutletInUse characteristic esiste, ritorna se c'è qualcosa collegato.
    /// Per molti device questo non è disponibile.
    func isInUse(_ service: HMService) -> Bool? {
        guard let ch = service.characteristics.first(where: { $0.characteristicType == Self.outletInUseCharType }) else {
            return nil
        }
        if let v = homeKit.value(for: ch) as? Bool { return v }
        return nil
    }
    
    func onCharacteristic(_ service: HMService) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == Self.onCharType }
    }
    
    // MARK: - Quick toggle (no-op)
    
    func performQuickToggle(via homeKit: HomeKitService) async throws { }
    
    // MARK: - Control section
    
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(MultiOutletControl(adapter: self))
    }
}

// MARK: - Control view

private struct MultiOutletControl: View {
    let adapter: MultiOutletAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    var body: some View {
        VStack(spacing: 16) {
            summarySection
            outletsSection
        }
        .task {
            homeKit.startObserving(accessoryUUIDs: [adapter.accessory.uniqueIdentifier])
        }
        .onDisappear {
            homeKit.stopObserving(accessoryUUIDs: [adapter.accessory.uniqueIdentifier])
        }
    }
    
    // MARK: - Summary
    
    private var summarySection: some View {
        let tint = adapter.markerTint ?? .blue

        return HStack(spacing: 12) {
            Image(systemName: adapter.isOn ? "powerplug.fill" : "powerplug")
                .font(.title2)
                .foregroundStyle(adapter.isOn
                                 ? AnyShapeStyle(tint)
                                 : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(adapter.isOn
                                  ? AnyShapeStyle(tint.opacity(0.15))
                                  : AnyShapeStyle(.thinMaterial))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(adapter.outletServices.count) \(String(localized: "outlet.count.suffix", defaultValue: "prese"))")
                    .font(.subheadline.weight(.semibold))
                Text(adapter.primaryStatusText ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Bottoni "Tutte spente" / "Tutte accese"
            HStack(spacing: 8) {
                Button {
                    setAllOutlets(on: false)
                } label: {
                    Text(String(localized: "outlet.action.turnOffAll", defaultValue: "Spegni tutte"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.thinMaterial))
                }
                .buttonStyle(.plain)
                .disabled(adapter.onCount == 0)
                
                Button {
                    setAllOutlets(on: true)
                } label: {
                    Text(String(localized: "outlet.action.turnOnAll", defaultValue: "Accendi tutte"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(tint))
                }
                .buttonStyle(.plain)
                .disabled(adapter.onCount == adapter.outletServices.count)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
    }
    
    // MARK: - Outlets list
    
    private var outletsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "outlet.section.title", defaultValue: "Prese"))
                .font(.headline)
                .padding(.leading, 4)
            
            VStack(spacing: 6) {
                ForEach(Array(adapter.outletServices.enumerated()), id: \.element.uniqueIdentifier) { index, service in
                    outletRow(for: service, index: index)
                }
            }
        }
    }
    
    private func outletRow(for service: HMService, index: Int) -> some View {
        let isOn = adapter.isOutletOn(service)
        let name = adapter.outletName(service, index: index)
        let inUse = adapter.isInUse(service)
        let tint = adapter.markerTint ?? .blue
        
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.thinMaterial))
                    .frame(width: 36, height: 36)
                Image(systemName: "powerplug.fill")
                    .font(.subheadline)
                    .foregroundStyle(isOn ? .white : .primary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text(isOn ? String(localized: "outlet.state.on", defaultValue: "Accesa") : String(localized: "outlet.state.off", defaultValue: "Spenta"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Indicatore "in uso" se disponibile
            if let inUse, isOn {
                Image(systemName: inUse ? "bolt.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(inUse ? .yellow : .secondary)
            }
            
            // Toggle per accendere/spegnere la singola presa
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    setOutlet(service, on: newValue)
                }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
    }
    
    // MARK: - Actions
    
    private func setOutlet(_ service: HMService, on: Bool) {
        guard let ch = adapter.onCharacteristic(service) else { return }
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        
        Task {
            do {
                try await homeKit.write(on as Any, to: ch)
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
    
    private func setAllOutlets(on: Bool) {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        
        Task {
            for service in adapter.outletServices {
                guard let ch = adapter.onCharacteristic(service) else { continue }
                do {
                    try await homeKit.write(on as Any, to: ch)
                } catch {
                    // Continua con le altre prese anche se una fallisce
                }
            }
        }
    }
}
