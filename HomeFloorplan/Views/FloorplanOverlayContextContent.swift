import SwiftUI
import HomeKit

struct FloorplanOverlayContextContent: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerWidth: CGFloat
    let floorplan: Floorplan
    let homeKit: HomeKitService
    let environmentViewModel: EnvironmentViewModel
    let pendingSuggestionCount: Int

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
            VStack(spacing: 14) {
                if mode == .intelligence, pendingSuggestionCount > 0 {
                    floorplanOverviewCard(for: mode)
                }

                switch mode {
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
            .padding(.top, mode == .intelligence ? 36 : 0)
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
        let suggestions = pendingSuggestionCount
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
        } else if mode == .intelligence, suggestions > 0 {
            color = .orange
            icon = "sparkles"
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
                if suggestions > 0 {
                    return suggestions == 1
                        ? String(localized: "floorplan.status.intelligence.oneSuggestion", defaultValue: "One suggestion ready")
                        : String(localized: "floorplan.status.intelligence.manySuggestions", defaultValue: "\(suggestions) suggestions ready")
                }
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
                if suggestions > 0 {
                    return String(localized: "floorplan.status.intelligence.message.suggestions", defaultValue: "Review the recommendations below. You can approve or ignore them directly from this panel.")
                }
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
                FloorplanStatusMetric(value: "\(suggestions)", label: String(localized: "floorplan.metric.suggestions", defaultValue: "Suggestions")),
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
