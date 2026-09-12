import SwiftUI
import HomeKit

/// Router dei contenuti del pannello per modalità: unico per l'overlay
/// compact e per il pannello docked su regular, così i due contenitori non
/// possono divergere nei contenuti.
struct FloorplanContextDashboardRouter: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let floorplan: Floorplan
    let environmentViewModel: EnvironmentViewModel
    /// Per risolvere l'adapter del dettaglio clima (novità D).
    var adapterMap: [UUID: any AccessoryAdapter] = [:]
    /// Il momento scelto sul nastro, quando il pannello lo sta mostrando.
    var selectedMoment: DayMoment? = nil

    var body: some View {
        VStack(spacing: 14) {
            // Il dettaglio dispositivo vince su qualunque dashboard: è stato
            // aperto da un tap esplicito su un marker. Clima ha la sua vista
            // dedicata; le altre categorie usano la sezione controlli che
            // ogni adapter già espone, con le letture come ripiego.
            if case .moment = overlayVM.panelContent, let selectedMoment {
                FloorplanMomentPanelContent(moment: selectedMoment, overlayVM: overlayVM)
            } else if case .device(let accessoryID) = overlayVM.panelContent,
               let adapter = adapterMap[accessoryID] {
                if let thermostat = adapter as? (any ThermostatControlling) {
                    FloorplanClimatePanelContent(
                        overlayVM: overlayVM,
                        thermostat: thermostat,
                        name: adapter.name,
                        roomName: adapter.accessory.room?.name
                    )
                } else {
                    FloorplanDevicePanelContent(
                        overlayVM: overlayVM,
                        adapter: adapter
                    )
                }
            } else {
                dashboard
            }
        }
        .padding(.top, overlayVM.activeMode == .intelligence ? 36 : 0)
    }

    @ViewBuilder
    private var dashboard: some View {
        switch overlayVM.activeMode {
            case .controls:
                EmptyView()
            case .environment:
                EnvironmentContextDashboard(
                    envVM: environmentViewModel,
                    overlayVM: overlayVM,
                    highlightedRoomID: overlayVM.highlightedRoomID,
                    linkedRooms: floorplan.linkedRooms
                )
            case .security:
                SecurityContextDashboard(
                    highlightedRoomID: overlayVM.highlightedRoomID,
                    linkedRooms: floorplan.linkedRooms
                )
            case .intelligence:
                IntelligenceContextDashboard(
                    highlightedRoomID: overlayVM.highlightedRoomID,
                    linkedRooms: floorplan.linkedRooms
                )
            }
    }
}

// MARK: - FloorplanClimatePanelContent

/// Vista parametri clima nel pannello (novità D): nome e stanza, controllo
/// termostato completo (riusa `ThermostatControl`, con le sue scritture
/// ottimistiche già collaudate) e link per tornare al contenuto standard.
struct FloorplanClimatePanelContent: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let thermostat: any ThermostatControlling
    let name: String
    let roomName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                overlayVM.closeDetailContent()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "common.back", defaultValue: "Back"))
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(FloorplanTokens.Semantic.warning)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                if let roomName {
                    Text(roomName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ThermostatControl(adapter: thermostat, isCompact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - FloorplanDevicePanelContent

/// Dettaglio nel pannello per i dispositivi non-toggleabili che non sono
/// clima (matrice gesti 28/08): tende, serrature, sensori, camere. Riusa la
/// sezione controlli che l'adapter già espone per la scheda completa; se non
/// ne ha (sensori puri), mostra stato e batteria.
struct FloorplanDevicePanelContent: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let adapter: any AccessoryAdapter

    @Environment(HomeKitService.self) private var homeKit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                overlayVM.closeDetailContent()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "common.back", defaultValue: "Back"))
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(overlayVM.activeMode.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(adapter.name)
                    .font(.headline)
                if let roomName = adapter.accessory.room?.name {
                    Text(roomName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let controls = adapter.makeControlSection(homeKit: homeKit) {
                controls
            }

            // Stato e batteria: per i sensori puri sono il contenuto vero.
            VStack(alignment: .leading, spacing: 8) {
                if let status = adapter.primaryStatusText {
                    HStack(spacing: 8) {
                        Image(systemName: adapter.iconName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(status)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                    }
                }
                if let battery = adapter.batteryInfo, let level = battery.level {
                    HStack(spacing: 8) {
                        Image(systemName: battery.isLow ? "battery.25percent" : "battery.75percent")
                            .font(.subheadline)
                            .foregroundStyle(battery.isLow
                                             ? FloorplanTokens.Semantic.warning
                                             : Color.secondary)
                        Text("\(level)%")
                            .font(.subheadline)
                            .foregroundStyle(battery.isLow
                                             ? FloorplanTokens.Semantic.warning
                                             : Color.primary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

struct FloorplanOverlayContextContent: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerWidth: CGFloat
    let floorplan: Floorplan
    let homeKit: HomeKitService
    let environmentViewModel: EnvironmentViewModel
    var adapterMap: [UUID: any AccessoryAdapter] = [:]

    private var mode: FloorplanOverlayMode {
        overlayVM.activeMode
    }

    var body: some View {
        FloorplanContextPanelContainer(
            overlayVM: overlayVM,
            containerWidth: containerWidth,
            title: panelTitle(for: mode),
            accentColor: mode.accentColor
        ) {
            FloorplanContextDashboardRouter(
                overlayVM: overlayVM,
                floorplan: floorplan,
                environmentViewModel: environmentViewModel,
                adapterMap: adapterMap
            )
        }
    }

    private func floorplanOverviewCard(for mode: FloorplanOverlayMode) -> some View {
        let health = FloorplanHealthAnalyzer.analyze(floorplan: floorplan, homeKit: homeKit)
        let attentionRoomList = environmentViewModel.rooms
            .filter { $0.worstUrgency != .normal }
            .sorted {
                if $0.worstUrgency != $1.worstUrgency { return $0.worstUrgency > $1.worstUrgency }
                return $0.roomName < $1.roomName
            }
        let attentionRooms = attentionRoomList.count
        let topEnvironmentRoom = attentionRoomList.first
        let issueCount = health.criticalCount + health.warningCount
        let securityDeviceCount = homeKit.allAccessories.filter { accessory in
            accessory.services.contains { service in
                service.serviceType == HMServiceTypeLockMechanism ||
                    service.serviceType == HMServiceTypeSecuritySystem ||
                    service.serviceType == HMServiceTypeGarageDoorOpener ||
                    service.serviceType == HMServiceTypeDoorbell
            }
        }.count

        let color: Color
        let icon: String
        if mode == .environment, topEnvironmentRoom?.worstUrgency == .danger {
            color = .red
            icon = "exclamationmark.triangle.fill"
        } else if mode == .security, securityDeviceCount == 0 {
            color = .orange
            icon = "lock.shield"
        } else if issueCount > 0 {
            color = .orange
            icon = "checklist"
        } else if attentionRooms > 0 || health.criticalCount > 0 {
            color = .red
            icon = "house.and.flag.fill"
        } else {
            color = .green
            icon = "checkmark.seal.fill"
        }

        let title: String = {
            switch mode {
            case .environment:
                if let room = topEnvironmentRoom {
                    return String(localized: "floorplan.status.environment.roomCheck", defaultValue: "\(room.roomName) needs attention")
                }
                return String(localized: "floorplan.status.environment.stable", defaultValue: "Environment stable")
            case .security:
                if securityDeviceCount == 0 {
                    return String(localized: "floorplan.status.security.configure", defaultValue: "Configure security")
                }
                return String(localized: "floorplan.status.security.available", defaultValue: "Security available")
            case .intelligence:
                return String(localized: "floorplan.status.intelligence.learning", defaultValue: "Intelligence is learning")
            case .controls:
                if issueCount > 0 {
                    return String(localized: "floorplan.status.controls.complete", defaultValue: "Complete the floorplan")
                }
                return String(localized: "floorplan.status.controls.ready", defaultValue: "Floorplan ready")
            }
        }()

        let message: String = {
            switch mode {
            case .environment:
                if let room = topEnvironmentRoom {
                    let level = room.worstUrgency == .danger
                        ? String(localized: "floorplan.priority.critical", defaultValue: "critical")
                        : String(localized: "floorplan.priority.monitor", defaultValue: "to monitor")
                    return String(localized: "floorplan.status.environment.message.room", defaultValue: "Priority \(level): check the cards below for values, AI explanation, and available actions.")
                }
                return String(localized: "floorplan.status.environment.message.stable", defaultValue: "No room is outside thresholds. Use this panel to review the environmental summary.")
            case .security:
                if securityDeviceCount == 0 {
                    return String(localized: "floorplan.status.security.message.configure", defaultValue: "Add locks, sensors, or a HomeKit alarm to see security status and priorities here.")
                }
                return String(localized: "floorplan.status.security.message.available", defaultValue: "Use the cards below to review system status, monitored sensors, and highlighted rooms.")
            case .intelligence:
                return String(localized: "floorplan.status.intelligence.message.learning", defaultValue: "No actions are ready. The home is still collecting patterns and will show reliable opportunities here.")
            case .controls:
                if issueCount > 0 {
                    return String(localized: "floorplan.status.controls.message.issues", defaultValue: "Open diagnostics with the checklist icon to see what is missing or misaligned.")
                }
                return String(localized: "floorplan.status.controls.message.ready", defaultValue: "Markers and rooms are ready. Use the center pill to switch between operational overlays.")
            }
        }()

        return FloorplanStatusSummaryCard(
            title: title,
            message: message,
            icon: icon,
            color: color,
            metrics: [
                FloorplanStatusMetric(value: "\(attentionRooms)", label: String(localized: "floorplan.metric.toCheck", defaultValue: "To check")),
                FloorplanStatusMetric(value: "\(health.linkableUnplacedCount)", label: String(localized: "floorplan.metric.toPlace", defaultValue: "To place"))
            ]
        )
    }

    private func panelTitle(for mode: FloorplanOverlayMode) -> String {
        switch mode {
        case .controls: return ""
        case .environment: return String(localized: "overlay.environment", defaultValue: "Environment")
        case .security: return String(localized: "overlay.security", defaultValue: "Security")
        case .intelligence: return String(localized: "overlay.intelligence", defaultValue: "Intelligence")
        }
    }
}
