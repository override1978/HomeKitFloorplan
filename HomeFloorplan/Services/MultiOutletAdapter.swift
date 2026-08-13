import Foundation
import HomeKit
import SwiftUI

/// Adapter multi-canale: accessori con N servizi di potenza (Outlet o Switch),
/// ognuno con la PROPRIA PowerState. Nato per le multiprese (Eve Energy Strip,
/// Meross); allargato ai moduli relè dall'Aqara T2 raggruppato (2 servizi
/// Switch), che con OnOffAdapter aveva il secondo canale INVISIBILE.
/// - 1 marker per accessorio sul floorplan
/// - Marker acceso se almeno un canale è on
/// - Dettaglio mostra N row con toggle individuale per ogni canale
@MainActor
final class MultiOutletAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    init(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
    }
    
    static let outletServiceType = "00000047-0000-1000-8000-0026BB765291"
    static let switchServiceType = "00000049-0000-1000-8000-0026BB765291"
    static let onCharType = "00000025-0000-1000-8000-0026BB765291"
    static let nameCharType = "00000023-0000-1000-8000-0026BB765291"
    static let outletInUseCharType = "00000026-0000-1000-8000-0026BB765291"

    /// I servizi «di potenza» dell'accessorio: Outlet o Switch, ognuno con la
    /// propria PowerState. È il criterio del multi-canale, condiviso con
    /// factory, scene e wizard: se l'elenco è ≥2, l'ipotesi «un accessorio =
    /// una potenza» è falsa e tutto deve ragionare per servizio.
    static func powerServices(in accessory: HMAccessory) -> [HMService] {
        accessory.services.filter { service in
            (service.serviceType == outletServiceType || service.serviceType == switchServiceType)
                && service.characteristics.contains { $0.characteristicType == onCharType }
        }
    }

    /// Il nome del canale come lo conosce l'utente: PRIMA il nome del
    /// SERVIZIO («Ventola Max» — è lì che Apple Home scrive le rinomine), poi
    /// la Name characteristic (spesso di fabbrica: «Switch2»), poi il numero.
    static func channelName(for service: HMService, index: Int) -> String {
        let serviceName = service.name.trimmingCharacters(in: .whitespaces)
        if !serviceName.isEmpty { return serviceName }
        if let nameCh = service.characteristics.first(where: { $0.characteristicType == nameCharType }),
           let value = nameCh.value as? String, !value.isEmpty {
            return value
        }
        let noun = service.serviceType == switchServiceType
            ? String(localized: "channel.name.fallback", defaultValue: "Canale")
            : String(localized: "outlet.name.fallback", defaultValue: "Presa")
        return "\(noun) \(index + 1)"
    }

    /// «Accessorio · Canale» per le liste di azioni (scene e automazioni),
    /// solo quando l'accessorio ha davvero più canali — altrimenti nil e chi
    /// chiama usa il nome dell'accessorio come sempre.
    static func actionLabel(for characteristic: HMCharacteristic) -> String? {
        guard let service = characteristic.service,
              let accessory = service.accessory else { return nil }
        let channels = powerServices(in: accessory)
        guard channels.count >= 2,
              let index = channels.firstIndex(of: service) else { return nil }
        return "\(accessory.name) · \(channelName(for: service, index: index))"
    }
    
    var markerStyle: MarkerStyle { .controllable }
    var supportsQuickToggle: Bool { false }  // No: ci sono N prese, scelta singola ambigua
    var supportsFloorplanPlacement: Bool { true }
    
    var iconName: String {
        if usesSwitchWording {
            return isOn ? "lightswitch.on.fill" : "lightswitch.off"
        }
        return isOn ? "powerplug.fill" : "powerplug"
    }

    /// Tutti i canali (Outlet o Switch), ordinati come HomeKit li espone.
    var channelServices: [HMService] {
        Self.powerServices(in: accessory)
    }

    /// Almeno un canale è uno Switch: cambia icona e vocabolario
    /// («canali», non «prese»).
    var usesSwitchWording: Bool {
        channelServices.contains { $0.serviceType == Self.switchServiceType }
    }

    /// True se ALMENO UN canale è acceso.
    var isOn: Bool {
        channelServices.contains { isOutletOn($0) }
    }
    
    /// Conta dei canali accesi.
    var onCount: Int {
        channelServices.filter { isOutletOn($0) }.count
    }
    
    var visualUrgency: MarkerUrgency {
        isOn ? .active : .normal
    }

    var markerTint: Color? {
        isOn ? .blue : nil
    }
    
    var primaryStatusText: String? {
        let total = channelServices.count
        if total == 0 { return nil }
        if onCount == 0 {
            return usesSwitchWording
                ? String(localized: "multichannel.status.allOff", defaultValue: "Tutti spenti")
                : String(localized: "multioutlet.status.allOff", defaultValue: "Tutte spente")
        }
        if onCount == total {
            return usesSwitchWording
                ? String(localized: "multichannel.status.allOn", defaultValue: "Tutti accesi")
                : String(localized: "multioutlet.status.allOn", defaultValue: "Tutte accese")
        }
        let suffix = usesSwitchWording
            ? String(localized: "multichannel.status.someOn.suffix", defaultValue: "accesi")
            : String(localized: "multioutlet.status.someOn.suffix", defaultValue: "accese")
        return "\(onCount) \(String(localized: "multioutlet.status.someOn.of", defaultValue: "di")) \(total) \(suffix)"
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
        Self.channelName(for: service, index: index)
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
                Text("\(adapter.channelServices.count) \(adapter.usesSwitchWording ? String(localized: "channel.count.suffix", defaultValue: "canali") : String(localized: "outlet.count.suffix", defaultValue: "prese"))")
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
                .disabled(adapter.onCount == adapter.channelServices.count)
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
            Text(adapter.usesSwitchWording
                 ? String(localized: "channel.section.title", defaultValue: "Canali")
                 : String(localized: "outlet.section.title", defaultValue: "Prese"))
                .font(.headline)
                .padding(.leading, 4)
            
            VStack(spacing: 6) {
                ForEach(Array(adapter.channelServices.enumerated()), id: \.element.uniqueIdentifier) { index, service in
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
                Image(systemName: service.serviceType == MultiOutletAdapter.switchServiceType
                      ? "lightswitch.on.fill" : "powerplug.fill")
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
            for service in adapter.channelServices {
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
