import SwiftUI
import SwiftData

// MARK: - EnvironmentOverlayView

/// Canvas-based overlay that fills each linked room with a colour
/// representing its worst environment urgency. Tapping a room opens
/// the context panel with per-sensor details.
struct EnvironmentOverlayView: View {

    let floorplan: Floorplan
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerSize: CGSize
    /// Pre-computed from the parent — avoids reloading the image just to get its size.
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let effectiveOffset: CGSize

    /// Shared instance managed by the parent (FloorplanEditorView).
    var envVM: EnvironmentViewModel

    // MARK: Derived

    private var helper: FloorplanCoordinateHelper {
        FloorplanCoordinateHelper(imageRect: imageRect)
    }

    var body: some View {
        let h            = helper
        let isLoading    = envVM.isLoading && envVM.rooms.isEmpty
        let inverseScale = 1.0 / effectiveScale

        // Per-room urgency — all .normal during initial load (rooms is empty)
        let urgencyByRoom: [String: SensorUrgency] = {
            guard !isLoading else { return [:] }
            var dict: [String: SensorUrgency] = [:]
            let filter = overlayVM.selectedSensorFilter
            for room in floorplan.linkedRooms {
                guard let roomData = envVM.rooms.first(where: { $0.roomName == room.name }) else {
                    dict[room.name] = .normal; continue
                }
                dict[room.name] = filter.flatMap { f in
                    roomData.sensors.first(where: { $0.serviceType == f })?.urgency
                } ?? roomData.worstUrgency
            }
            return dict
        }()

        // Scostamento dalle soglie personalizzate (0 = sotto warning,
        // 0..1 = rampa warning→danger, >1 = oltre danger): il riempimento
        // diventa proporzionale a "quanto" la stanza sfora, non solo al livello.
        let deviationByRoom: [String: Double] = {
            guard !isLoading else { return [:] }
            var dict: [String: Double] = [:]
            let filter = overlayVM.selectedSensorFilter
            for room in floorplan.linkedRooms {
                guard let roomData = envVM.rooms.first(where: { $0.roomName == room.name }) else { continue }
                let sensors = filter.map { f in roomData.sensors.filter { $0.serviceType == f } } ?? roomData.sensors
                dict[room.name] = sensors.map(thresholdDeviation).max() ?? 0
            }
            return dict
        }()

        return ZStack(alignment: .topLeading) {
            // Canvas: fill colour transitions smoothly via parent animation
            Canvas { ctx, _ in
                for room in floorplan.linkedRooms {
                    let path = h.overlayPath(for: room)
                    let u = urgencyByRoom[room.name] ?? .normal
                    let fill = isLoading
                        ? Color(.systemGreen).opacity(0.08)
                        : gradedFillColor(urgency: u, deviation: deviationByRoom[room.name] ?? 0)
                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(path, with: .color(fill.opacity(0.6)), lineWidth: 1.5 / effectiveScale)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            // Badges: stesso ForEach, contenuto condizionale in base allo stato
            ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                let center  = h.centroid(for: room)
                let urgency = urgencyByRoom[room.name] ?? .normal

                Group {
                    if isLoading {
                        HStack(spacing: 5) {
                            ProgressView().scaleEffect(0.65)
                            Text(room.name)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.secondary)
                    } else {
                        Button {
                            overlayVM.selectRoom(room.hmRoomUUID)
                        } label: {
                            environmentBadge(room: room, urgency: urgency)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scaleEffect(inverseScale)
                .position(center)
            }
        }
        // Un singolo modificatore anima sia il canvas sia i badge
        .animation(.easeInOut(duration: 0.4), value: isLoading)
    }

    // MARK: Badge

    private func environmentBadge(room: LinkedRoom, urgency: SensorUrgency) -> some View {
        let roomData   = envVM.rooms.first { $0.roomName == room.name }
        let filter     = overlayVM.selectedSensorFilter
        let filtSensor = filter.flatMap { f in roomData?.sensors.first { $0.serviceType == f } }
        let borderColor = urgencyBorderColor(urgency)

        return VStack(spacing: 3) {
            // Room name — always shown
            Text(room.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)

            if let sensor = filtSensor {
                // Filtered mode: show the specific sensor's value (+ trend)
                HStack(spacing: 2) {
                    Text(sensor.formattedValue)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                    if let trendSymbol = sensor.trend.symbolName {
                        Image(systemName: trendSymbol)
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(urgencyBorderColor(sensor.urgency))
            } else if let data = roomData {
                // All-types mode: score % + label
                HStack(spacing: 3) {
                    Text("\(Int(data.qualityScore * 100))%")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                    Text(data.qualityLabel)
                        .font(.system(size: 9, weight: .medium))
                }
            } else if filter != nil {
                // Filter active but no data for this room/type
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Bottom accent bar outside the fill so clipShape constrains it to rounded corners
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(borderColor.opacity(0.7))
                .frame(height: 3)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor.opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(.primary)
        .shadow(color: borderColor.opacity(0.12), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    // MARK: Urgency helpers

    private func urgencyFillColor(_ urgency: SensorUrgency) -> Color {
        switch urgency {
        case .normal:  return Color(.systemGreen).opacity(0.15)
        case .warning: return Color.orange.opacity(0.28)
        case .danger:  return Color.red.opacity(0.38)
        }
    }

    /// 0 = sotto warning; 0..1 = posizione nella banda warning→danger; >1 oltre danger.
    private func thresholdDeviation(_ sensor: SensorData) -> Double {
        guard sensor.serviceType != .lightSensor else { return 0 }
        guard sensor.currentValue >= sensor.warningThreshold else { return 0 }
        let band = max(sensor.dangerThreshold - sensor.warningThreshold, 0.001)
        return (sensor.currentValue - sensor.warningThreshold) / band
    }

    /// Tinta per urgency, intensità proporzionale allo scostamento dalla soglia.
    private func gradedFillColor(urgency: SensorUrgency, deviation: Double) -> Color {
        switch urgency {
        case .normal:
            return Color(.systemGreen).opacity(0.15)
        case .warning:
            // 0.18 → 0.38 man mano che ci si avvicina alla soglia danger
            return Color.orange.opacity(0.18 + 0.20 * min(max(deviation, 0), 1))
        case .danger:
            // 0.28 → 0.55 con lo sforamento oltre danger (cap a 2 bande)
            return Color.red.opacity(min(0.28 + 0.12 * min(max(deviation - 1, 0), 2), 0.55))
        }
    }

    private func urgencyBorderColor(_ urgency: SensorUrgency) -> Color {
        switch urgency {
        case .normal:  return Color(.systemGreen)
        case .warning: return Color.orange
        case .danger:  return Color.red
        }
    }
}

// MARK: - EnvironmentContextDashboard

/// Visual command centre for the Environment overlay mode.
///
/// Cards answer **"What is happening?"** while the floorplan answers **"Where?"**:
/// - Score card: current environment health trend.
/// - Digest card: narrative explanation of what matters now.
/// - Action card: primary next step, shown only when there is something actionable.
/// - Summary / drill-down cards: supporting detail without repeating the digest.
///
/// `highlightedRoomID` is accepted but only used to provide per-room context
/// inside each card — the card set itself never changes.
struct EnvironmentContextDashboard: View {

    var envVM: EnvironmentViewModel
    @Bindable var overlayVM: FloorplanOverlayViewModel
    /// UUID of the room the user last tapped on the floorplan.
    let highlightedRoomID: UUID?
    /// Linked rooms — used to resolve the highlighted room name.
    let linkedRooms: [LinkedRoom]

    // MARK: AI service (mirroring EnvironmentDashboardView pattern)

    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @Environment(ActionExecutionService.self) private var executionService
    @Environment(WeatherKitService.self) private var weatherKit
    @State private var aiService: AmbientalAIService?
    @AppStorage("ai.isEnabled") private var isAIEnabled: Bool = false

    // MARK: Private helpers

    private var accent: Color { Color(.systemGreen) }
    private var globalScoreInt: Int { Int(envVM.globalScore * 100) }

    private var highlightedRoomName: String? {
        guard let id = highlightedRoomID else { return nil }
        return linkedRooms.first { $0.hmRoomUUID == id }?.name
    }

    private func effectiveSeverity(_ insight: AmbientalAIInsight) -> InsightSeverity {
        guard let room = envVM.rooms.first(where: { $0.roomName == insight.roomName }) else {
            return insight.severity
        }

        let roomSeverity: InsightSeverity
        switch room.worstUrgency {
        case .danger:  roomSeverity = .anomaly
        case .warning: roomSeverity = .warning
        case .normal:  roomSeverity = .info
        }
        return max(insight.severity, roomSeverity)
    }

    private func effectiveSeverityColor(_ insight: AmbientalAIInsight) -> Color {
        switch effectiveSeverity(insight) {
        case .anomaly: return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }

    // MARK: Body

    var body: some View {
        // ── Compute expensive derived data ONCE per render ──────────────
        let allSensors    = envVM.rooms.flatMap(\.sensors)
        let filtered: [SensorData] = {
            let base = overlayVM.selectedSensorFilter.map { f in allSensors.filter { $0.serviceType == f } } ?? allSensors
            return base.sorted {
                if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
                return $0.roomName < $1.roomName
            }
        }()
        let dangerCount  = filtered.filter { $0.urgency == .danger  }.count
        let warningCount = filtered.filter { $0.urgency == .warning }.count
        let normalCount  = filtered.filter { $0.urgency == .normal  }.count
        let rows: [InsightRow] = {
            var r: [InsightRow] = []
            for sensor in filtered.filter({ $0.urgency != .normal }).prefix(3) { r.append(.sensor(sensor)) }
            if r.count < 3 {
                for room in envVM.rooms.filter({ $0.worstUrgency == .normal }).sorted(by: { $0.roomName < $1.roomName }).prefix(3 - r.count) {
                    r.append(.stable(room))
                }
            }
            return r
        }()
        let topAlert: SensorData? = filtered.first { $0.urgency == .danger } ?? filtered.first { $0.urgency == .warning }
        let aiInsights: [AmbientalAIInsight] = {
            guard let svc = aiService else { return [] }
            let rank: (InsightSeverity) -> Int = {
                switch $0 {
                case .anomaly: return 2
                case .warning: return 1
                case .info:    return 0
                }
            }
            let ranked = svc.insights
                .filter { $0.isVisible && !$0.nextActions.isEmpty }
                .sorted { rank(effectiveSeverity($0)) > rank(effectiveSeverity($1)) }
            // Stanza selezionata sulla planimetria: i suoi insight vanno in testa,
            // così il tap su una stanza mostra subito la CTA che la riguarda.
            guard let selected = highlightedRoomName else { return ranked }
            return ranked.filter { $0.roomName == selected }
                + ranked.filter { $0.roomName != selected }
        }()
        // ───────────────────────────────────────────────────────────────

        return VStack(spacing: 14) {
            // ── Card 1: Health Score / graph ───────────────────────────────
            healthScoreCard

            // ── Confronto dentro/fuori (meteo già campionato dal loop) ─────
            if let weather = weatherKit.currentWeather {
                IndoorOutdoorCompareRow(
                    outdoorTemp: weather.outdoorTemperature,
                    outdoorSymbol: weather.symbolName,
                    indoorAvgTemp: {
                        let temps = allSensors
                            .filter { $0.serviceType == .temperature }
                            .map(\.currentValue)
                        return temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
                    }()
                )
            }

            // ── Card 2: Assistant narrative ────────────────────────────────
            HomeDigestSummaryCard(
                summary: HomeAssistantDigestService.environmentDigest(
                    rooms: envVM.rooms,
                    highlightedRoomName: highlightedRoomName
                )
            )

            if envVM.isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(String(localized: "environment.panel.loading", defaultValue: "Loading data…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(accentColor: accent)
            } else if envVM.rooms.isEmpty {
                Label(String(localized: "environment.panel.noData", defaultValue: "No environmental data available"), systemImage: "thermometer")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard(accentColor: .secondary)
            } else {
                // ── Card 3: AI Azioni Consigliate ──────────────────────────
                // Prefer real AI next-actions; fall back to basic sensor alert if none.
                if isAIEnabled && !aiInsights.isEmpty {
                    aiActionsCard(insights: aiInsights)
                } else if let sensor = topAlert {
                    actionCard(sensor: sensor)
                } else if isAIEnabled {
                    FloorplanEmptyStateCard(
                        title: String(localized: "environment.panel.stable.title", defaultValue: "Environment stable"),
                        message: String(localized: "environment.panel.stable.message", defaultValue: "There are no environmental anomalies or AI actions to suggest right now."),
                        icon: "checkmark.seal.fill",
                        color: .green
                    )
                } else {
                    FloorplanEmptyStateCard(
                        title: String(localized: "environment.panel.aiOff.title", defaultValue: "AI insights disabled"),
                        message: String(localized: "environment.panel.aiOff.message", defaultValue: "Environmental data remains visible. Enable AI in Settings to receive explanations and suggested actions."),
                        icon: "sparkles",
                        color: .secondary
                    )
                }

                // ── Card 4: Summary ────────────────────────────────────────
                summaryCard(dangerCount: dangerCount, warningCount: warningCount, normalCount: normalCount)

                // ── Card 5: Context drill-down ─────────────────────────────
                if highlightedRoomName != nil || overlayVM.selectedSensorFilter != nil {
                    insightsCard(rows: rows)
                }
            }
        }
        .onAppear {
            // Lazy-init AI service (same pattern as EnvironmentDashboardView)
            if aiService == nil {
                aiService = AmbientalAIService(
                    aiSettings: AISettings(),
                    modelContainer: modelContext.container,
                    homeKit: homeKit
                )
            }
            guard !envVM.rooms.isEmpty else { return }
            Task { await aiService?.analyzeRooms(envVM.rooms) }
        }
        .onChange(of: envVM.lastRefresh) { _, _ in
            guard !envVM.rooms.isEmpty else { return }
            Task { await aiService?.analyzeRooms(envVM.rooms) }
        }
    }

    // MARK: Card 1 — Health Score

    private var healthScoreCard: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: heroIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(envVM.globalColor)
                Text(String(localized: "environment.panel.healthTitle", defaultValue: "Home Health"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if let refresh = envVM.lastRefresh {
                    Text(refresh, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Score + label row
            HStack(alignment: .bottom) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(globalScoreInt)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(envVM.globalColor)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(envVM.globalColor.opacity(0.65))
                        .padding(.bottom, 5)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(envVM.globalLabel)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    let alertCount = envVM.rooms.filter { $0.worstUrgency != .normal }.count
                    if alertCount > 0 {
                        Label(alertCount == 1
                              ? String(localized: "environment.panel.roomsToCheck.one",  defaultValue: "1 room to check")
                              : String(format: String(localized: "environment.panel.roomsToCheck.many", defaultValue: "%lld rooms to check"), alertCount),
                              systemImage: "bell.badge.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.10), in: Capsule())
                    } else {
                        Label(String(localized: "environment.panel.allNormal", defaultValue: "All Normal"), systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.10), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(envVM.globalColor.opacity(0.12)).frame(height: 5)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [envVM.globalColor.opacity(0.7), envVM.globalColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(8, geo.size.width * CGFloat(globalScoreInt) / 100), height: 5)
                        .animation(.spring(response: 0.9, dampingFraction: 0.75), value: globalScoreInt)
                }
            }
            .frame(height: 5)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(envVM.globalColor.opacity(0.6))
                .frame(height: 3)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: envVM.globalColor.opacity(0.12), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    /// SF Symbol matching the global health score — mirrors EnvironmentHeroView.
    private var heroIcon: String {
        switch envVM.globalScore {
        case 0.85...1.0:  return "leaf.fill"
        case 0.60..<0.85: return "checkmark.circle.fill"
        case 0.35..<0.60: return "exclamationmark.triangle.fill"
        default:           return "exclamationmark.octagon.fill"
        }
    }

    // MARK: Card 2 — Top Insights

    private func insightsCard(rows: [InsightRow]) -> some View {
        let cardAccent: Color = {
            if rows.contains(where: { if case .sensor(let s) = $0 { return s.urgency == .danger } else { return false } }) { return .red }
            if rows.contains(where: { if case .sensor(let s) = $0 { return s.urgency == .warning } else { return false } }) { return .orange }
            return accent
        }()

        return VStack(alignment: .leading, spacing: 10) {
            cardSectionLabel(
                rows.isEmpty
                    ? String(localized: "environment.panel.noWarnings", defaultValue: "NO ALERTS")
                    : String(localized: "environment.panel.warnings",   defaultValue: "ALERTS"),
                icon: rows.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
            )

            if rows.isEmpty {
                Label(String(localized: "environment.panel.allSensorsNormal", defaultValue: "All sensors normal"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(accent)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        insightRowView(row)
                    }
                }
            }
        }
        .panelCard(accentColor: cardAccent)
    }

    @ViewBuilder
    private func insightRowView(_ row: InsightRow) -> some View {
        switch row {
        case .sensor(let sensor):
            // SensorCardView-style row: coloured background + border when not normal
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(sensor.urgency.color.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: sensor.serviceType.sfSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(sensor.urgency.color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(sensor.formattedValue)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if let trendSymbol = sensor.trend.symbolName {
                            Image(systemName: trendSymbol)
                                .font(.system(size: 11, weight: .bold))
                                .opacity(0.85)
                        }
                    }
                    .foregroundStyle(sensor.urgency.color)
                    Text("\(sensor.serviceType.displayName) · \(sensor.roomName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Freschezza auto-aggiornante (Text .relative si ridisegna da solo)
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8))
                        Text(sensor.lastUpdated, style: .relative)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: sensor.urgency.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(sensor.urgency.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sensor.urgency.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(sensor.urgency.color.opacity(0.4), lineWidth: 1)
                    )
            )

        case .stable(let room):
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 36, height: 36)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(room.roomName)
                        .font(.caption.weight(.semibold))
                    Text(String(localized: "environment.sensor.normal", defaultValue: "Normal"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accent.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: Card 3 — Recommended Action

    private func actionCard(sensor: SensorData) -> some View {
        let isHighlightedRoom = sensor.roomName == highlightedRoomName
        let cardAccent: Color = sensor.urgency == .danger ? .red : .orange
        let actionVerb = sensor.urgency == .danger
            ? String(localized: "environment.action.checkNow", defaultValue: "Check Now")
            : String(localized: "environment.action.verify",   defaultValue: "Verify")

        return VStack(alignment: .leading, spacing: 12) {
            cardSectionLabel(String(localized: "environment.panel.suggestedAction", defaultValue: "SUGGESTED ACTION"), icon: "arrow.right.circle.fill")

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(cardAccent.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: sensor.urgency == .danger
                          ? "exclamationmark.octagon.fill"
                          : "bell.badge.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(cardAccent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(actionVerb) \(sensor.serviceType.displayName)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(String(format: String(localized: "environment.panel.sensorLocation", defaultValue: "%1$@ in %2$@%3$@"),
                                sensor.formattedValue,
                                sensor.roomName,
                                isHighlightedRoom ? " · " + String(localized: "environment.panel.selectedRoom", defaultValue: "selected room") : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .panelCard(accentColor: cardAccent)
    }

    // MARK: Card 3b — AI Recommended Actions

    /// Card shown when AI has produced insights with executable next-actions.
    /// Shows up to 3 insights (one per row) with their action chips.
    private func aiActionsCard(insights: [AmbientalAIInsight]) -> some View {
        let topInsight = insights[0]
        let severityColor = effectiveSeverityColor(topInsight)

        return VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(String(localized: "environment.panel.aiActions", defaultValue: "AI SUGGESTED ACTIONS"))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if aiService?.isAnalyzing == true {
                    ProgressView().scaleEffect(0.6)
                }
            }

            // One block per insight (max 2)
            ForEach(insights.prefix(2)) { insight in
                let iColor = effectiveSeverityColor(insight)
                let effective = effectiveSeverity(insight)

                VStack(alignment: .leading, spacing: 8) {
                    // Insight message
                    HStack(spacing: 6) {
                        Image(systemName: effective.sfSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(iColor)
                        Text(insight.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if insight.roomName == highlightedRoomName {
                            // Marcatore "stanza selezionata sulla planimetria"
                            Text(insight.roomName)
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(iColor.opacity(0.14)))
                                .foregroundStyle(iColor)
                        }
                    }

                    // Action chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(insight.dedupedNextActions) { action in
                                AIActionChip(
                                    action: action,
                                    color: iColor,
                                    executionService: executionService,
                                    homeKit: homeKit,
                                    insight: insight
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if insight.id != insights.prefix(2).last?.id {
                    Divider()
                }
            }
        }
        .panelCard(accentColor: severityColor)
    }

    // MARK: Card 4 — Summary

    private func summaryCard(dangerCount: Int, warningCount: Int, normalCount: Int) -> some View {
        let total = dangerCount + warningCount + normalCount
        let summaryAccent: Color = dangerCount > 0 ? .red : warningCount > 0 ? .orange : accent
        let summaryText: String = {
            if dangerCount > 0 {
                return dangerCount == 1
                    ? String(localized: "environment.summary.oneCritical",  defaultValue: "1 critical sensor — immediate attention")
                    : String(format: String(localized: "environment.summary.manyCritical", defaultValue: "%lld critical sensors — immediate attention"), dangerCount)
            } else if warningCount > 0 {
                return warningCount == 1
                    ? String(localized: "environment.summary.oneWarning",   defaultValue: "1 sensor needs attention")
                    : String(format: String(localized: "environment.summary.manyWarning",  defaultValue: "%lld sensors need attention"), warningCount)
            } else if total > 0 {
                return String(format: String(localized: "environment.summary.allNormal",  defaultValue: "All %lld sensors normal"), total)
            } else {
                return String(localized: "environment.summary.noSensors",   defaultValue: "No sensors detected")
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            cardSectionLabel(String(localized: "environment.panel.sensorSummary", defaultValue: "SENSOR SUMMARY"), icon: "sensor.fill")

            HStack(spacing: 0) {
                summaryCount(dangerCount,  color: .red,    label: String(localized: "environment.summary.label.critical",  defaultValue: "critical"))
                Divider().frame(height: 36)
                summaryCount(warningCount, color: .orange, label: String(localized: "environment.summary.label.warning",   defaultValue: "warning"))
                Divider().frame(height: 36)
                summaryCount(normalCount,  color: accent,  label: String(localized: "environment.summary.label.normal",    defaultValue: "normal"))
            }

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(summaryAccent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelCard(accentColor: summaryAccent)
    }

    // MARK: Reusable sub-views

    private func cardSectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func urgencyBadge(_ urgency: SensorUrgency) -> some View {
        Text(urgency.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(urgency == .normal ? .secondary : urgency.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill((urgency == .normal ? Color.secondary : urgency.color).opacity(0.12))
            )
    }

    private func summaryCount(_ count: Int, color: Color, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(count == 0 ? Color.secondary : color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - InsightRow helper

private enum InsightRow {
    case sensor(SensorData)
    case stable(RoomEnvironmentData)
}

// MARK: - PanelCard ViewModifier
// Mirrors EnvironmentHeroView card style exactly:
// .regularMaterial fill, 3pt accent bar at bottom clipped to card radius,
// coloured + neutral dual shadow.

private struct PanelCardModifier: ViewModifier {
    let accentColor: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Bottom accent bar lives outside the fill so the clipShape below
            // actually constrains it to the card's rounded corners.
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

private extension View {
    func panelCard(accentColor: Color) -> some View {
        modifier(PanelCardModifier(accentColor: accentColor))
    }
}

// MARK: - AIActionChip

/// Chip interattivo per una AINextAction.
/// Tip → chip statico. Suggest → tap esegue l'azione HomeKit via ActionExecutionService.
private struct AIActionChip: View {

    let action: AINextAction
    let color: Color
    let executionService: ActionExecutionService
    let homeKit: HomeKitService
    let insight: AmbientalAIInsight

    enum ChipState { case idle, executing, done, error }
    @State private var state: ChipState = .idle

    private var actionIcon: String {
        switch action.accessoryActionType {
        case "on":       return "power"
        case "off":      return "power"
        case "setMode":  return "slider.horizontal.3"
        case "setSpeed": return "fan.fill"
        case "setTemp":  return "thermometer.medium"
        case "open":     return "arrow.up.square"
        case "close":    return "arrow.down.square"
        case "dim":      return "light.max"
        default:         return "arrow.right.circle.fill"
        }
    }

    private func chipBackground(opacity: Double, borderOpacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color.opacity(borderOpacity), lineWidth: 1)
            )
    }

    var body: some View {
        if action.isTip {
            // Tip: plain non-interactive chip — no disabled-button visual artefact
            HStack(spacing: 5) {
                Image(systemName: action.iconName ?? "lightbulb.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color.opacity(0.7))
                Text(action.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(color.opacity(0.75))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(chipBackground(opacity: 0.06, borderOpacity: 0.18))
        } else {
            // Suggest: interactive button with executing/done/error states
            Button {
                guard state == .idle else { return }
                execute()
            } label: {
                HStack(spacing: 5) {
                    switch state {
                    case .executing:
                        ProgressView().scaleEffect(0.65).frame(width: 12, height: 12)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    case .error:
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                    case .idle:
                        Image(systemName: actionIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(color)
                    }
                    Text(state == .done ? "Done" : state == .error ? "Error" : action.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(state == .done ? .green : state == .error ? .red : color)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            state == .done ? Color.green.opacity(0.10)
                            : state == .error ? Color.red.opacity(0.10)
                            : color.opacity(0.09)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    state == .done ? Color.green.opacity(0.35)
                                    : state == .error ? Color.red.opacity(0.35)
                                    : color.opacity(0.30),
                                    lineWidth: 1
                                )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(state == .executing || state == .done)
            .animation(.spring(response: 0.25), value: state)
        }
    }

    private func execute() {
        guard let home = homeKit.currentHome else { state = .error; return }
        state = .executing
        Task {
            let success = await executionService.execute(action, insight: insight, in: home)
            state = success ? .done : .error
            if state == .error {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                state = .idle
            }
        }
    }
}

// MARK: - IndoorOutdoorCompareRow

/// Riga compatta "Dentro X° · Fuori Y°" con hint quando la differenza è
/// significativa. Usa il meteo già campionato dal loop foreground.
private struct IndoorOutdoorCompareRow: View {
    let outdoorTemp: Double
    let outdoorSymbol: String
    let indoorAvgTemp: Double?

    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    private var unit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outdoorSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 18))

            if let indoor = indoorAvgTemp {
                Text("\(String(localized: "env.compare.indoor", defaultValue: "Indoor")) \(unit.format(indoor)) · \(String(localized: "env.compare.outdoor", defaultValue: "Outdoor")) \(unit.format(outdoorTemp))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("\(String(localized: "env.compare.outdoor", defaultValue: "Outdoor")) \(unit.format(outdoorTemp))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    /// Hint solo con differenza ≥ 2°: sotto è rumore.
    private var hint: String? {
        guard let indoor = indoorAvgTemp else { return nil }
        let delta = outdoorTemp - indoor
        if delta <= -2 {
            return String(localized: "env.compare.coolerOutside",
                          defaultValue: "Cooler outside — good time to air out")
        }
        if delta >= 2 {
            return String(localized: "env.compare.warmerOutside",
                          defaultValue: "Warmer outside — keep windows closed")
        }
        return nil
    }
}
