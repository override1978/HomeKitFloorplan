import Foundation
import HomeKit
import SwiftUI

/// Adapter per Stateless Programmable Switch.
/// Un accessorio può contenere MULTIPLE ProgrammableSwitch services (es. Aqara Cube
/// con 6 pulsanti virtuali). Mostriamo una riga per ogni servizio nel dettaglio.
@MainActor
final class ProgrammableSwitchAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    init(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
    }
    
    static let serviceType = "00000089-0000-1000-8000-0026BB765291"
    static let eventCharType = "00000073-0000-1000-8000-0026BB765291"
    static let labelIndexCharType = "000000CB-0000-1000-8000-0026BB765291"
    static let nameCharType = "00000023-0000-1000-8000-0026BB765291"
    
    var markerStyle: MarkerStyle { .sensorBoolean }
    var visualUrgency: MarkerUrgency { .normal }
    var isOn: Bool { false }
    var supportsQuickToggle: Bool { false }
    var supportsFloorplanPlacement: Bool { false }
    var iconName: String { "button.programmable" }
    
    /// Tutti i servizi ProgrammableSwitch dell'accessorio (es. 6 per Aqara Cube).
    var switchServices: [HMService] {
        accessory.services
            .filter { $0.serviceType == Self.serviceType }
            .sorted { (a, b) in
                let aIdx = labelIndex(of: a) ?? Int.max
                let bIdx = labelIndex(of: b) ?? Int.max
                return aIdx < bIdx
            }
    }
    
    /// Nome del bottone (es. "Button1") o fallback con label index.
    func buttonName(_ service: HMService) -> String {
        if let nameCh = service.characteristics.first(where: { $0.characteristicType == Self.nameCharType }),
           let value = homeKit.value(for: nameCh) as? String, !value.isEmpty {
            return value
        }
        if let idx = labelIndex(of: service) {
            return String(format: String(localized: "programmableSwitch.button.index",
                                         defaultValue: "Button %d"),
                          idx)
        }
        return service.name
    }
    
    func labelIndex(of service: HMService) -> Int? {
        if let ch = service.characteristics.first(where: { $0.characteristicType == Self.labelIndexCharType }) {
            if let v = homeKit.value(for: ch) as? Int { return v }
            if let v = homeKit.value(for: ch) as? NSNumber { return v.intValue }
        }
        return nil
    }
    
    /// Eventi supportati da questo servizio specifico, letti dai metadata.
    func supportedEvents(in service: HMService) -> [Int] {
        if let ch = service.characteristics.first(where: { $0.characteristicType == Self.eventCharType }) {
            // Prima preferenza: validValues esplicito
            if let validValues = ch.metadata?.validValues as? [NSNumber], !validValues.isEmpty {
                return validValues.map { $0.intValue }.sorted()
            }
            // Fallback: ricava da min/max
            if let min = ch.metadata?.minimumValue as? NSNumber,
               let max = ch.metadata?.maximumValue as? NSNumber {
                return Array(min.intValue...max.intValue)
            }
        }
        return [0]  // fallback prudente: almeno single press
    }
    
    /// Ultimo evento ricevuto su questo servizio specifico.
    func lastEvent(in service: HMService) -> Int? {
        if let ch = service.characteristics.first(where: { $0.characteristicType == Self.eventCharType }) {
            if let v = homeKit.value(for: ch) as? Int { return v }
            if let v = homeKit.value(for: ch) as? NSNumber { return v.intValue }
        }
        return nil
    }
    
    var primaryStatusText: String? {
        let count = switchServices.count
        if count == 0 { return String(localized: "programmableSwitch.button", defaultValue: "Button") }
        if count == 1 { return String(localized: "programmableSwitch.button", defaultValue: "Button") }
        return String(format: String(localized: "programmableSwitch.buttons.count",
                                     defaultValue: "%d buttons"),
                      count)
    }
    
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws { }
    
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(ProgrammableSwitchControl(adapter: self))
    }
}

// MARK: - Control view

private struct ProgrammableSwitchControl: View {
    let adapter: ProgrammableSwitchAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    var body: some View {
        VStack(spacing: 24) {
            buttonsSection
            configurationSection
        }
        .task {
            homeKit.startObserving(accessoryUUIDs: [adapter.accessory.uniqueIdentifier])
        }
        .onDisappear {
            homeKit.stopObserving(accessoryUUIDs: [adapter.accessory.uniqueIdentifier])
        }
    }
    
    // MARK: - Buttons section
    
    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(adapter.switchServices.count == 1
                 ? String(localized: "programmableSwitch.trigger", defaultValue: "Trigger")
                 : String(localized: "programmableSwitch.buttons", defaultValue: "Buttons"))
                .font(.headline)
            
            VStack(spacing: 10) {
                ForEach(adapter.switchServices, id: \.uniqueIdentifier) { service in
                    buttonRow(for: service)
                }
            }
        }
    }
    
    private func buttonRow(for service: HMService) -> some View {
        let supported = adapter.supportedEvents(in: service)
        let last = adapter.lastEvent(in: service)
        let buttonName = adapter.buttonName(service)
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(buttonName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let last, let label = eventLabel(last) {
                    HStack(spacing: 4) {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                        Text(String(format: String(localized: "programmableSwitch.lastEvent",
                                                   defaultValue: "Last: %@"),
                                    label))
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            
            HStack(spacing: 8) {
                if supported.contains(0) {
                    eventPill(label: String(localized: "programmableSwitch.event.single", defaultValue: "Single"),
                              symbol: "hand.tap.fill",
                              isActive: last == 0)
                }
                if supported.contains(1) {
                    eventPill(label: String(localized: "programmableSwitch.event.double", defaultValue: "Double"),
                              symbol: "hand.tap.fill",
                              isActive: last == 1,
                              doubleTap: true)
                }
                if supported.contains(2) {
                    eventPill(label: String(localized: "programmableSwitch.event.long", defaultValue: "Long"),
                              symbol: "hand.point.up.left.fill",
                              isActive: last == 2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
    }
    
    private func eventPill(label: String, symbol: String, isActive: Bool, doubleTap: Bool = false) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                if doubleTap {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .offset(x: 4, y: 3)
                        .opacity(0.55)
                }
            }
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isActive ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isActive
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(.thinMaterial))
        )
        .animation(.spring(response: 0.3), value: isActive)
    }
    
    private func eventLabel(_ event: Int) -> String? {
        switch event {
        case 0: return String(localized: "programmableSwitch.event.single", defaultValue: "Single")
        case 1: return String(localized: "programmableSwitch.event.double", defaultValue: "Double")
        case 2: return String(localized: "programmableSwitch.event.long", defaultValue: "Long")
        default: return nil
        }
    }
    
    // MARK: - Configuration
    
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "programmableSwitch.configuration.title", defaultValue: "Configuration"))
                .font(.headline)
            
            Text(String(localized: "programmableSwitch.configuration.message",
                        defaultValue: "To associate buttons with scenes or automations, use the Apple Home app. Automation settings cannot be edited here."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button {
                openAppleHome()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                    Text(String(localized: "programmableSwitch.configuration.openHome", defaultValue: "Configure in Home"))
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().fill(.tint))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func openAppleHome() {
        if let url = URL(string: "x-apple-homekit://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
