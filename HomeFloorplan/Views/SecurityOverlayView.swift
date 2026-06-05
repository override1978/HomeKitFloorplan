import SwiftUI
import HomeKit

// MARK: - SecurityOverlayView

/// Overlay that highlights rooms containing security accessories
/// (locks, alarms, garage doors) with a status-driven tint.
/// Tapping a room opens the context panel with device details.
struct SecurityOverlayView: View {

    let floorplan: Floorplan
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerSize: CGSize
    let effectiveScale: CGFloat
    let effectiveOffset: CGSize

    @Environment(HomeKitService.self) private var homeKit

    // MARK: Derived

    /// Cached helper — rebuilt only when containerSize or floorplan.imageFilename changes.
    @State private var cachedHelper: FloorplanCoordinateHelper?
    @State private var cachedImageFilename: String = ""
    @State private var cachedContainerSize: CGSize = .zero

    /// Telecamera selezionata dall'utente → apre AccessoryDetailView.
    @State private var selectedCamera: HMAccessory?

    private func updatedHelper() -> FloorplanCoordinateHelper? {
        if floorplan.imageFilename == cachedImageFilename,
           containerSize == cachedContainerSize,
           let h = cachedHelper {
            return h
        }
        guard let image = ImageStorageService.load(filename: floorplan.imageFilename) else { return nil }
        return FloorplanCoordinateHelper.make(imageSize: image.size, container: containerSize)
    }

    var body: some View {
        // Build all derived data once per render — avoids multiple redundant calls.
        let h = updatedHelper()
        let statusByRoom: [UUID: RoomSecurityStatus] = {
            var dict: [UUID: RoomSecurityStatus] = [:]
            for room in floorplan.linkedRooms {
                dict[room.hmRoomUUID] = securityStatus(for: room)
            }
            return dict
        }()
        let inverseScale = 1.0 / effectiveScale

        return ZStack(alignment: .topLeading) {
            if let h {
                // Fill canvas
                Canvas { ctx, _ in
                    for room in floorplan.linkedRooms {
                        let path = h.overlayPath(for: room)
                        let status = statusByRoom[room.hmRoomUUID] ?? .none
                        ctx.fill(path, with: .color(fillColor(status)))
                        ctx.stroke(path, with: .color(borderColor(status).opacity(0.8)),
                                   lineWidth: 1.5 / effectiveScale)
                    }
                }
                .frame(width: containerSize.width, height: containerSize.height)
                .allowsHitTesting(false)

                // Tap targets + badges
                ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                    let status = statusByRoom[room.hmRoomUUID] ?? .none
                    let center = h.centroid(for: room)

                    Button {
                        overlayVM.selectRoom(room.hmRoomUUID)
                    } label: {
                        securityBadge(room: room, status: status)
                            .scaleEffect(inverseScale)
                    }
                    .buttonStyle(.plain)
                    .position(center)
                }

                // Camera markers — auto-positioned near the room centroid.
                // One marker per camera found in each linked room.
                ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                    let cameras = cameraAdapters(for: room)
                    let center  = h.centroid(for: room)
                    // Stack cameras horizontally, spaced to the right of the badge.
                    // The badge sits at `center`; cameras start 60 pt below it.
                    ForEach(Array(cameras.enumerated()), id: \.element.accessory.uniqueIdentifier) { idx, adapter in
                        let xOffset = CGFloat(idx) * (120 * inverseScale + 8 * inverseScale)
                        Button {
                            selectedCamera = adapter.accessory
                        } label: {
                            CameraMarkerView(
                                adapter: adapter,
                                size: MarkerSize.regular.cameraMarkerSize,
                                isEditing: false,
                                isSelected: false,
                                label: adapter.accessory.name,
                                hasCustomLabel: false
                            )
                            .scaleEffect(inverseScale)
                        }
                        .buttonStyle(.plain)
                        .position(CGPoint(
                            x: center.x + xOffset,
                            y: center.y + 60 * inverseScale
                        ))
                    }
                }
            }
        }
        .onAppear { updateHelperCache() }
        .onChange(of: containerSize) { _, _ in updateHelperCache() }
        .onChange(of: floorplan.imageFilename) { _, _ in updateHelperCache() }
        .sheet(item: $selectedCamera) { accessory in
            AccessoryDetailView(accessory: accessory)
        }
    }

    private func updateHelperCache() {
        guard let image = ImageStorageService.load(filename: floorplan.imageFilename) else { return }
        cachedHelper = FloorplanCoordinateHelper.make(imageSize: image.size, container: containerSize)
        cachedImageFilename = floorplan.imageFilename
        cachedContainerSize = containerSize
    }

    // MARK: Badge

    @ViewBuilder
    private func securityBadge(room: LinkedRoom, status: RoomSecurityStatus) -> some View {
        let accent = badgeAccentColor(status)
        let bg = badgeBackgroundColor(status)

        VStack(spacing: 3) {
            // Icon row
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(room.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(status == .none ? Color.secondary : .white)

            // State label
            if status != .none {
                Text(status.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(accent.opacity(0.9))
                .frame(height: 3)
        }
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.35), radius: 6, y: 2)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }

    /// Solid fill color behind the badge text — strong enough to ensure contrast.
    private func badgeBackgroundColor(_ status: RoomSecurityStatus) -> Color {
        switch status {
        case .none:     return Color(.systemBackground).opacity(0.80)
        case .locked:   return Color.purple.opacity(0.85)
        case .unlocked: return Color.orange.opacity(0.90)
        case .disarmed: return Color.gray.opacity(0.75)
        case .armed:    return Color.purple.opacity(0.92)
        case .alarmed:  return Color.red.opacity(0.95)
        }
    }

    /// Accent color for the bottom bar and border.
    private func badgeAccentColor(_ status: RoomSecurityStatus) -> Color {
        switch status {
        case .none:     return Color.secondary
        case .locked:   return Color.purple
        case .unlocked: return Color.orange
        case .disarmed: return Color.purple.opacity(0.5)
        case .armed:    return Color.purple
        case .alarmed:  return Color.red
        }
    }

    // MARK: Camera helpers

    /// Returns all CameraAdapter instances whose HomeKit room matches the given LinkedRoom.
    private func cameraAdapters(for room: LinkedRoom) -> [CameraAdapter] {
        homeKit.allAccessories
            .filter { $0.room?.uniqueIdentifier == room.hmRoomUUID }
            .compactMap { AccessoryAdapterFactory.adapter(for: $0, homeKit: homeKit) as? CameraAdapter }
    }

    // MARK: Security status

    private func securityStatus(for room: LinkedRoom) -> RoomSecurityStatus {
        let roomAccessories = homeKit.allAccessories.filter {
            $0.room?.uniqueIdentifier == room.hmRoomUUID
        }

        var hasLock = false
        var hasAlarm = false
        var isTriggered = false
        var isArmed = false
        var isLocked = false

        for accessory in roomAccessories {
            for service in accessory.services {
                switch service.serviceType {
                case HMServiceTypeSecuritySystem:
                    hasAlarm = true
                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeCurrentSecuritySystemState
                    }) {
                        let raw = (char.value as? Int) ?? 3
                        if raw == 4 { isTriggered = true }
                        else if raw != 3 { isArmed = true }
                    }
                case HMServiceTypeLockMechanism:
                    hasLock = true
                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState
                    }) {
                        let raw = (char.value as? Int) ?? 0
                        if raw == 1 { isLocked = true }
                    }
                case HMServiceTypeGarageDoorOpener, HMServiceTypeDoorbell:
                    hasLock = true
                default:
                    break
                }
            }
        }

        if isTriggered  { return .alarmed }
        if isArmed      { return .armed }
        if hasAlarm     { return .disarmed }
        if isLocked     { return .locked }
        if hasLock      { return .unlocked }
        return .none
    }

    private func fillColor(_ status: RoomSecurityStatus) -> Color {
        switch status {
        case .none:      return Color(.systemPurple).opacity(0.05)
        case .locked:    return Color(.systemPurple).opacity(0.14)
        case .unlocked:  return Color.orange.opacity(0.18)
        case .disarmed:  return Color(.systemPurple).opacity(0.09)
        case .armed:     return Color(.systemPurple).opacity(0.25)
        case .alarmed:   return Color.red.opacity(0.38)
        }
    }

    private func borderColor(_ status: RoomSecurityStatus) -> Color {
        switch status {
        case .none:      return Color(.systemPurple).opacity(0.20)
        case .locked:    return Color(.systemPurple)
        case .unlocked:  return Color.orange
        case .disarmed:  return Color(.systemPurple).opacity(0.35)
        case .armed:     return Color(.systemPurple)
        case .alarmed:   return Color.red
        }
    }
}

// MARK: - RoomSecurityStatus

enum RoomSecurityStatus {
    case none       // no security devices
    case locked     // lock present and locked
    case unlocked   // lock present but open
    case disarmed   // alarm present and disarmed
    case armed      // alarm armed
    case alarmed    // alarm triggered

    var icon: String {
        switch self {
        case .none:      return "lock.shield"
        case .locked:    return "lock.fill"
        case .unlocked:  return "lock.open.fill"
        case .disarmed:  return "shield.slash"
        case .armed:     return "lock.shield.fill"
        case .alarmed:   return "exclamationmark.shield.fill"
        }
    }

    var label: String {
        switch self {
        case .none:      return ""
        case .locked:    return String(localized: "security.status.locked",   defaultValue: "Chiuso")
        case .unlocked:  return String(localized: "security.status.unlocked", defaultValue: "Aperto")
        case .disarmed:  return String(localized: "security.status.disarmed", defaultValue: "Disattivato")
        case .armed:     return String(localized: "security.status.armed",    defaultValue: "Armato")
        case .alarmed:   return String(localized: "security.status.alarmed",  defaultValue: "ALLARME")
        }
    }
}

// MARK: - SecurityContextDashboard

/// Context panel for the Security overlay — 4 card layout matching EnvironmentContextDashboard style.
/// Cards: 1) Security Score hero  2) Active alerts  3) Devices by room  4) Suggested action
struct SecurityContextDashboard: View {

    @Environment(HomeKitService.self) private var homeKit
    let highlightedRoomID: UUID?
    let linkedRooms: [LinkedRoom]

    /// Mirrors SecurityView — same AppStorage key so monitored set is in sync.
    @AppStorage("securityMonitoredUUIDs") private var monitoredUUIDsRaw: String = ""

    private var accent: Color { Color(.systemPurple) }

    // MARK: Derived data helpers (called once per render in body)

    private var highlightedRoomName: String? {
        guard let id = highlightedRoomID else { return nil }
        return linkedRooms.first { $0.hmRoomUUID == id }?.name
    }

    /// All security sensor/lock accessories — mirrors SecurityView.sensorAdapters exactly
    /// so AppStorage UUIDs always refer to the same set of accessories.
    private func buildAllSecurityAdapters() -> [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        guard let home = homeKit.currentHome else { return [] }
        var result: [(HMAccessory, any AccessoryAdapter)] = []
        for acc in home.accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            if let sensor = adapter as? SensorAdapter, isSecuritySensor(sensor) {
                result.append((acc, sensor))
            } else if let lock = adapter as? DoorLockAdapter {
                result.append((acc, lock))
            }
        }
        return result.sorted {
            let r0 = $0.0.room?.name ?? "~"; let r1 = $1.0.room?.name ?? "~"
            return r0 != r1 ? r0 < r1 : $0.0.name < $1.0.name
        }
    }

    private func isSecuritySensor(_ sensor: SensorAdapter) -> Bool {
        sensor.smokeDetected != nil
            || sensor.carbonMonoxideDetected != nil
            || sensor.leakDetected != nil
            || sensor.contactDetected != nil
            || sensor.motionDetected != nil
            || sensor.occupancyDetected != nil
    }

    private func buildSecuritySystem() -> (accessory: HMAccessory, adapter: SecuritySystemAdapter)? {
        guard let home = homeKit.currentHome else { return nil }
        for acc in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? SecuritySystemAdapter {
                return (acc, adapter)
            }
        }
        return nil
    }

    // MARK: Body

    var body: some View {
        // ── Compute all expensive derived data ONCE per render ──────────
        let allAdapters      = buildAllSecurityAdapters()
        let monitoredIDs     = Set(monitoredUUIDsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let monitored        = monitoredIDs.isEmpty ? [] : allAdapters.filter { monitoredIDs.contains($0.accessory.uniqueIdentifier.uuidString) }
        let alarmSensors     = monitored.filter { $0.adapter.visualUrgency == .alarm }
        let warningSensors   = monitored.filter { $0.adapter.visualUrgency == .warning }
        let okSensors        = monitored.filter { $0.adapter.visualUrgency != .alarm && $0.adapter.visualUrgency != .warning }
        let system           = buildSecuritySystem()
        let score            = SecurityScoreService.computeScore(monitoredSensors: monitored, securitySystem: system)
        let scoreColor: Color = score >= 80 ? accent : score >= 50 ? .orange : .red
        let insights         = SecurityScoreService.buildInsights(sensors: monitored, system: system)
        let criticals        = insights.filter { $0.priority == .critical }
        let warnings         = insights.filter { $0.priority == .warning }
        let infos            = insights.filter { $0.priority == .info }
        let topAction        = criticals.first ?? warnings.first
        let aggregated: AggregatedSecurityState = {
            if let sys = system, sys.adapter.isTriggered { return .alarm }
            guard !monitored.isEmpty else { return .noSensors }
            if alarmSensors.isEmpty == false { return .alarm }
            if warningSensors.isEmpty == false { return .warning }
            return .ok
        }()
        let byRoom: [(roomName: String, accessories: [HMAccessory])] = {
            var dict: [String: [HMAccessory]] = [:]
            for item in allAdapters {
                let name = item.accessory.room?.name ?? String(localized: "room.other", defaultValue: "Altra stanza")
                dict[name, default: []].append(item.accessory)
            }
            return dict.map { (roomName: $0.key, accessories: $0.value) }.sorted { $0.roomName < $1.roomName }
        }()
        let highlightName = highlightedRoomName
        // ────────────────────────────────────────────────────────────────

        return VStack(spacing: 12) {
            // Card 1 — Security Score hero
            scoreCard(score: score, scoreColor: scoreColor, aggregated: aggregated,
                      criticals: criticals, warnings: warnings, allAdapters: allAdapters, system: system)

            // Card 2 — Active alerts
            if !insights.isEmpty {
                alertsCard(insights: insights, criticals: criticals, warnings: warnings,
                           infos: infos, highlightName: highlightName)
            }

            // Card 3 — Monitored sensors (alarm → warning → ok)
            if !monitored.isEmpty {
                monitoredSensorsCard(monitored: monitored, alarm: alarmSensors,
                                     warning: warningSensors, ok: okSensors,
                                     highlightName: highlightName)
            }

            // Card 4 — Devices by room
            if !byRoom.isEmpty {
                devicesCard(byRoom: byRoom, highlightName: highlightName)
            }

            // Card 5 — Suggested action
            if let action = topAction, let suggested = action.suggestedAction {
                actionCard(action: action, suggested: suggested)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Card 1 — Score hero

    private func scoreCard(
        score: Int,
        scoreColor: Color,
        aggregated: AggregatedSecurityState,
        criticals: [SecurityInsight],
        warnings: [SecurityInsight],
        allAdapters: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        system: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(scoreColor)
                Text(String(localized: "security.panel.header", defaultValue: "SICUREZZA CASA"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            HStack(spacing: 16) {
                // Score ring (60×60)
                ZStack {
                    Circle()
                        .stroke(scoreColor.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Image(systemName: aggregated.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(scoreColor)
                        Text("\(score)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreColor)
                            .monospacedDigit()
                    }
                }
                .frame(width: 60, height: 60)

                // Status text
                VStack(alignment: .leading, spacing: 4) {
                    Text(aggregated.label)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor)

                    // Stats
                    HStack(spacing: 10) {
                        if !criticals.isEmpty {
                            SecurityPanelStat(
                                value: criticals.count,
                                label: String(localized: "security.stat.critical", defaultValue: "critici"),
                                color: .red,
                                symbol: "exclamationmark.shield.fill"
                            )
                        }
                        if !warnings.isEmpty {
                            SecurityPanelStat(
                                value: warnings.count,
                                label: String(localized: "security.stat.warnings", defaultValue: "avvisi"),
                                color: .orange,
                                symbol: "exclamationmark.triangle.fill"
                            )
                        }
                        SecurityPanelStat(
                            value: allAdapters.count,
                            label: String(localized: "security.stat.devices", defaultValue: "dispositivi"),
                            color: .secondary,
                            symbol: "sensor.tag.radiowaves.forward.fill"
                        )
                    }
                }

                Spacer()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 5)
                    Capsule().fill(scoreColor).frame(width: geo.size.width * CGFloat(score) / 100, height: 5)
                }
            }
            .frame(height: 5)

            // Alarm mode pills (if system present)
            if let sys = system {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sys.adapter.supportedModes) { mode in
                            let isActive = sys.adapter.currentMode == mode
                            HStack(spacing: 4) {
                                Image(systemName: mode.symbolName)
                                    .font(.caption2)
                                Text(mode.displayName)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(isActive ? .white : mode.tintColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isActive ? AnyShapeStyle(mode.tintColor) : AnyShapeStyle(mode.tintColor.opacity(0.12)))
                            )
                        }
                    }
                }
            }
        }
        .modifier(PanelCardModifier(accentColor: scoreColor))
    }

    // MARK: Card 2 — Active alerts

    private func alertsCard(
        insights: [SecurityInsight],
        criticals: [SecurityInsight],
        warnings: [SecurityInsight],
        infos: [SecurityInsight],
        highlightName: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(criticals.isEmpty ? Color.orange : Color.red)
                Text(String(localized: "security.panel.activeAlerts", defaultValue: "AVVISI ATTIVI"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                // Count badge
                Text("\(insights.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(criticals.isEmpty ? Color.orange : Color.red)
                    )
            }

            // Insight rows — critical first, then warning, then info (max 4)
            let sorted = criticals + warnings + infos
            ForEach(sorted.prefix(4)) { insight in
                alertRow(insight: insight, highlightName: highlightName)
            }

            // "All OK" placeholder when all are info
            if criticals.isEmpty && warnings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(String(localized: "security.panel.noAlarms", defaultValue: "Nessun allarme attivo"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(PanelCardModifier(accentColor: criticals.isEmpty ? .orange : .red))
    }

    private func alertRow(insight: SecurityInsight, highlightName: String?) -> some View {
        let isHighlighted = insight.room == highlightName && highlightName != nil
        return HStack(alignment: .top, spacing: 8) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(insight.priority.color)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: insight.sfSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(insight.priority.color)
                    Text(insight.priority.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(insight.priority.color)
                    if let room = insight.room {
                        Text("· \(room)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(insight.message)
                    .font(.caption.weight(isHighlighted ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? insight.priority.color.opacity(0.10) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    // MARK: Card 3 — Monitored sensors

    private func monitoredSensorsCard(
        monitored: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        alarm: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        warning: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        ok: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        highlightName: String?
    ) -> some View {
        let cardAccent: Color = alarm.isEmpty ? (warning.isEmpty ? .green : .orange) : .red
        return VStack(alignment: .leading, spacing: 10) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(cardAccent)
                Text(String(localized: "security.panel.monitoredSensors", defaultValue: "SENSORI MONITORATI"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(monitored.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent))
            }

            // Alarm group
            if !alarm.isEmpty {
                sensorGroupSection(title: String(localized: "security.sensors.inAlarm",     defaultValue: "In allarme"),          color: .red,    sensors: alarm,   highlightName: highlightName)
            }

            // Warning group
            if !warning.isEmpty {
                if !alarm.isEmpty { Divider() }
                sensorGroupSection(title: String(localized: "security.sensors.needsAttention", defaultValue: "Richiede attenzione"), color: .orange, sensors: warning, highlightName: highlightName)
            }

            // OK group
            if !ok.isEmpty {
                if !alarm.isEmpty || !warning.isEmpty { Divider() }
                sensorGroupSection(title: String(localized: "security.sensors.operational",    defaultValue: "Operativi"),           color: .green,  sensors: ok,      highlightName: highlightName)
            }
        }
        .modifier(PanelCardModifier(accentColor: cardAccent))
    }

    private func sensorGroupSection(
        title: String,
        color: Color,
        sensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        highlightName: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group header
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text("(\(sensors.count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Sensor rows
            ForEach(sensors, id: \.accessory.uniqueIdentifier) { item in
                sensorRow(item.accessory, adapter: item.adapter, urgencyColor: color, highlightName: highlightName)
            }
        }
    }

    private func sensorRow(
        _ accessory: HMAccessory,
        adapter: any AccessoryAdapter,
        urgencyColor: Color,
        highlightName: String?
    ) -> some View {
        let isHighlighted = accessory.room?.name == highlightName && highlightName != nil
        return HStack(spacing: 8) {
            // Icon with urgency tint
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(urgencyColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: adapter.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(urgencyColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(accessory.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let room = accessory.room?.name {
                    Text(room)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // State text
            if let status = adapter.primaryStatusText, !status.isEmpty {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(urgencyColor)
            }
        }
        .padding(.horizontal, isHighlighted ? 6 : 0)
        .padding(.vertical, isHighlighted ? 3 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? urgencyColor.opacity(0.08) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    // MARK: Card 4 — Devices by room

    private func devicesCard(
        byRoom: [(roomName: String, accessories: [HMAccessory])],
        highlightName: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "lock.rectangle.stack.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                Text(String(localized: "security.panel.devicesByRoom", defaultValue: "DISPOSITIVI PER STANZA"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            ForEach(byRoom, id: \.roomName) { group in
                let isHighlighted = group.roomName == highlightName
                deviceGroupRow(group.roomName, accessories: group.accessories, highlighted: isHighlighted)
            }
        }
        .modifier(PanelCardModifier(accentColor: accent))
    }

    private func deviceGroupRow(_ roomName: String,
                                accessories: [HMAccessory],
                                highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roomName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(highlighted ? accent : .secondary)
                .padding(.leading, 2)
            ForEach(accessories, id: \.uniqueIdentifier) { acc in
                deviceRow(acc, highlighted: highlighted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? accent.opacity(0.10) : Color.clear)
        )
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.35), lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: highlighted)
    }

    private func deviceRow(_ accessory: HMAccessory, highlighted: Bool) -> some View {
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        return HStack(spacing: 8) {
            Image(systemName: adapter.iconName)
                .font(.caption)
                .foregroundStyle(highlighted ? accent : Color.secondary)
                .frame(width: 18)
            Text(accessory.name)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            if let status = adapter.primaryStatusText {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(adapter.visualUrgency == .alarm ? .red : adapter.visualUrgency == .warning ? .orange : .secondary)
            }
        }
    }

    // MARK: Card 4 — Suggested action

    private func actionCard(action: SecurityInsight, suggested: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section label
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(action.priority.color)
                Text(String(localized: "security.panel.suggestedAction", defaultValue: "AZIONE CONSIGLIATA"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            // Action title
            HStack(spacing: 8) {
                Image(systemName: action.sfSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(action.priority.color)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(action.priority.color.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggested)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(action.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .modifier(PanelCardModifier(accentColor: action.priority.color))
    }

}

// MARK: - SecurityPanelStat

private struct SecurityPanelStat: View {
    let value: Int
    let label: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(color)
            Text("\(value) \(label)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - PanelCardModifier (Security copy)

/// Card style shared by all Security overlay panel cards.
/// Matches the PanelCardModifier used in EnvironmentOverlayView.
private struct PanelCardModifier: ViewModifier {
    let accentColor: Color
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(accentColor.opacity(0.6))
                    .frame(height: 3)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: accentColor.opacity(0.12), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

