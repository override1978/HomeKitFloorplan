import SwiftUI
import HomeKit

// MARK: - SecurityView

/// Vista principale Sicurezza — architettura Insight → Azione → Dettaglio.
/// Sezioni:
///   1. Security Health Hero (score + stato + ultimo evento)
///   2. AI Insights (generati localmente da SecurityScoreService)
///   3. Azioni rapide (arm/disarm/lock)
///   4. Sensori monitorati (raggruppati per urgenza)
///   5. Banner piantina (hook future integration)
struct SecurityView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var showConfigSheet = false
    @State private var selectedAccessory: HMAccessory?
    @State private var observedUUIDs: Set<UUID> = []
    @State private var okGroupExpanded = false

    @AppStorage("securityMonitoredUUIDs") private var monitoredUUIDsRaw: String = ""

    // MARK: - Computed (score + insights — calcolati on-demand, aggiornati con @Observable tracking)

    private var currentContext: ContextSnapshot {
        ContextResolver.resolve()
    }

    private var securityScore: Int {
        SecurityScoreService.computeScore(
            monitoredSensors: monitoredSensors,
            securitySystem: securitySystem,
            context: currentContext
        )
    }

    private var securityInsights: [SecurityInsight] {
        SecurityScoreService.buildInsights(
            sensors: monitoredSensors,
            system: securitySystem,
            context: currentContext
        )
        .sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.timestamp > $1.timestamp
        }
    }

    private var sensorAdapters: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        guard let home = homeKit.currentHome else { return [] }
        var result: [(HMAccessory, any AccessoryAdapter)] = []
        for acc in home.accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            if let sensor = adapter as? SensorAdapter, isSecuritySensor(sensor) {
                result.append((acc, sensor))
            } else if let lock = adapter as? DoorLockAdapter {
                result.append((acc, lock))
            } else if let garage = adapter as? GarageDoorAdapter {
                result.append((acc, garage))
            } else if let camera = adapter as? CameraAdapter,
                      camera.hasMotionSensor || camera.hasOccupancySensor {
                result.append((acc, camera))
            }
        }
        return result.sorted {
            let r0 = $0.0.room?.name ?? "~"
            let r1 = $1.0.room?.name ?? "~"
            if r0 != r1 { return r0 < r1 }
            return $0.0.name < $1.0.name
        }
    }

    private var securitySystem: (accessory: HMAccessory, adapter: SecuritySystemAdapter)? {
        guard let home = homeKit.currentHome else { return nil }
        for acc in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? SecuritySystemAdapter {
                return (acc, adapter)
            }
        }
        return nil
    }

    private var monitoredUUIDs: Set<String> {
        Set(monitoredUUIDsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var monitoredSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        guard !monitoredUUIDs.isEmpty else { return [] }
        return sensorAdapters.filter { monitoredUUIDs.contains($0.accessory.uniqueIdentifier.uuidString) }
    }

    private var aggregatedState: AggregatedSecurityState {
        if let sys = securitySystem, sys.adapter.isTriggered { return .alarm }
        guard !monitoredSensors.isEmpty else { return .noSensors }
        let urgencies = monitoredSensors.map { $0.adapter.visualUrgency }
        if urgencies.contains(.alarm) { return .alarm }
        if urgencies.contains(.warning) { return .warning }
        return .ok
    }

    /// Sensori raggruppati per urgenza: alarm > warning > ok
    private var alarmSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        monitoredSensors.filter { $0.adapter.visualUrgency == .alarm }
    }
    private var warningSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        monitoredSensors.filter { $0.adapter.visualUrgency == .warning }
    }
    private var okSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] {
        monitoredSensors.filter { $0.adapter.visualUrgency != .alarm && $0.adapter.visualUrgency != .warning }
    }

    /// Tutte le telecamere HomeKit — mostrate sempre nella sezione streaming, senza configurazione.
    private var cameraAdapters: [(accessory: HMAccessory, adapter: CameraAdapter)] {
        guard let home = homeKit.currentHome else { return [] }
        return home.accessories.compactMap { acc in
            guard let cam = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? CameraAdapter else { return nil }
            return (acc, cam)
        }.sorted { ($0.accessory.room?.name ?? "~") < ($1.accessory.room?.name ?? "~") }
    }

    // MARK: - Body

    var body: some View {
        navigationContent
            // Non fermiamo l'osservazione su onDisappear: vogliamo che le notifiche
            // HomeKit sui sensori monitorati rimangano attive anche quando l'utente
            // è su un'altra tab. Il sistema di allarme è osservato globalmente
            // da HomeKitService.startObservingSecuritySystems() e il trigger
            // dell'overlay è gestito a livello root in ContentView.
            .task { startObserving() }
    }

    private var navigationContent: some View {
        NavigationStack {
            securityContent
                .navigationTitle(String(localized: "security.title", defaultValue: "Security"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showConfigSheet = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .disabled(sensorAdapters.isEmpty)
                    }
                }
                .sheet(isPresented: $showConfigSheet) {
                    SecurityConfigSheet(adapters: sensorAdapters, monitoredUUIDsRaw: $monitoredUUIDsRaw)
                }
                .sheet(item: Binding(
                    get: { selectedAccessory.map { IdentifiableAccessory($0) } },
                    set: { selectedAccessory = $0?.accessory }
                )) { item in
                    AccessoryDetailView(accessory: item.accessory)
                }
        }
    }

    @ViewBuilder
    private var securityContent: some View {
        if securitySystem == nil && sensorAdapters.isEmpty {
            emptyStateNoDevices
        } else {
            mainContent
        }
    }

    private func startObserving() {
        var uuids: Set<UUID> = []
        if let sys = securitySystem { uuids.insert(sys.accessory.uniqueIdentifier) }
        for s in sensorAdapters { uuids.insert(s.accessory.uniqueIdentifier) }
        observedUUIDs = uuids
        if !uuids.isEmpty { homeKit.startObserving(accessoryUUIDs: uuids) }
    }

    private func stopObserving() {
        guard !observedUUIDs.isEmpty else { return }
        homeKit.stopObserving(accessoryUUIDs: observedUUIDs)
        observedUUIDs = []
    }

    // MARK: - Main content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 20) {

                // 1. Security Health Hero
                SecurityHealthHeroView(
                    score: securityScore,
                    state: aggregatedState,
                    monitoredCount: monitoredSensors.count,
                    warningCount: securityInsights.filter { $0.priority == .critical || $0.priority == .warning }.count,
                    securitySystem: securitySystem
                )
                .onTapGesture {
                    if let sys = securitySystem { selectedAccessory = sys.accessory }
                }

                // 1b. Away/vacation context banner
                let presence = currentContext.presenceState
                if presence == .away || presence == .vacation {
                    awayContextBanner(presence: presence)
                }

                // 2. AI Insights
                if !securityInsights.isEmpty {
                    SecurityInsightsSection(
                        insights: securityInsights,
                        onAccessoryTap: { uuid in
                            selectedAccessory = homeKit.currentHome?.accessories
                                .first { $0.uniqueIdentifier == uuid }
                        }
                    )
                }

                // 3. Quick Actions
                if let sys = securitySystem {
                    SecurityQuickActionsRow(adapter: sys.adapter)
                }

                // 4. Sensori monitorati (raggruppati per urgenza)
                if monitoredSensors.isEmpty {
                    emptyStateNoMonitored
                } else {
                    SecuritySensorsSection(
                        alarmSensors: alarmSensors,
                        warningSensors: warningSensors,
                        okSensors: okSensors,
                        okGroupExpanded: $okGroupExpanded,
                        onSensorTap: { selectedAccessory = $0 }
                    )
                }

                // 5. Streaming telecamere (sempre visibili, senza configurazione)
                if !cameraAdapters.isEmpty {
                    SecurityCameraSection(cameras: cameraAdapters)
                }

                // 6. Banner piantina — disabilitato, attivare in futuro
                // SecurityFloorplanBanner()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Context banner

    @ViewBuilder
    private func awayContextBanner(presence: PresenceState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.slash.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(presence == .vacation
                     ? String(localized: "security.context.vacation", defaultValue: "Vacation mode active")
                     : String(localized: "security.context.away",     defaultValue: "Away mode active"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "security.context.elevatedAlerts",
                            defaultValue: "Warnings are treated as critical — alerts are escalated."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Empty states

    private var emptyStateNoDevices: some View {
        ContentUnavailableView {
            Label(
                String(localized: "security.empty.noDevices.title", defaultValue: "No security devices"),
                systemImage: "shield.slash"
            )
        } description: {
            Text(String(localized: "security.empty.noDevices.description",
                        defaultValue: "Add contact sensors, smoke, CO, water leak, locks or an alarm system in HomeKit."))
        }
    }

    private var emptyStateNoMonitored: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "security.empty.noMonitored.title", defaultValue: "No monitored sensors"))
                .font(.headline)
            Text(String(localized: "security.empty.noMonitored.description",
                        defaultValue: "Configure the sensors to monitor to view your home's security status."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button { showConfigSheet = true } label: {
                Label(String(localized: "security.configureSensors", defaultValue: "Configure sensors"),
                      systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func isSecuritySensor(_ sensor: SensorAdapter) -> Bool {
        sensor.smokeDetected != nil
            || sensor.carbonMonoxideDetected != nil
            || sensor.leakDetected != nil
            || sensor.contactDetected != nil
            || sensor.motionDetected != nil
            || sensor.occupancyDetected != nil
    }
}

// MARK: - SecurityHealthHeroView

/// Hero card con score ring, stato aggregato e modalità sistema.
private struct SecurityHealthHeroView: View {

    let score: Int
    let state: AggregatedSecurityState
    let monitoredCount: Int
    let warningCount: Int
    let securitySystem: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?

    @State private var animatedScore: Int = 0
    @State private var pulse = false

    private var stateColor: Color {
        switch state {
        case .ok:        return .purple
        case .warning:   return .orange
        case .alarm:     return .red
        case .noSensors: return .secondary
        }
    }

    private var statusLabel: String {
        switch state {
        case .ok:        return String(localized: "security.hero.status.protected", defaultValue: "Good protection")
        case .warning:   return String(localized: "security.hero.status.warning",   defaultValue: "Attention required")
        case .alarm:     return String(localized: "security.hero.status.alarm",     defaultValue: "ALARM ACTIVE")
        case .noSensors: return String(localized: "security.hero.status.noSensors", defaultValue: "No sensors")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Score ring + stato
            HStack(alignment: .center, spacing: 20) {
                // Ring
                SecurityScoreRingView(score: animatedScore, state: state)
                    .frame(width: 96, height: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Indice di sicurezza \(score) su 100")

                // Testo stato
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "security.hero.title", defaultValue: "Home Security"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(statusLabel)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(stateColor)
                        .animation(state == .alarm
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default, value: pulse)

                    // Meta: avvisi + sensori
                    HStack(spacing: 12) {
                        if warningCount > 0 {
                            SecurityMetaStat(
                                value: warningCount,
                                label: String(localized: "security.hero.warnings",
                                              defaultValue: "warnings"),
                                color: warningCount > 0 ? stateColor : .secondary,
                                symbol: "exclamationmark.triangle.fill"
                            )
                        }
                        SecurityMetaStat(
                            value: monitoredCount,
                            label: String(localized: "security.hero.sensors",
                                          defaultValue: "sensors"),
                            color: .secondary,
                            symbol: "sensor.tag.radiowaves.forward.fill"
                        )
                    }
                    .padding(.top, 2)
                }

                Spacer()
            }

            // Divisore + modalità sistema (se presente)
            if let sys = securitySystem {
                Divider()
                    .opacity(0.5)

                SecuritySystemModePills(adapter: sys.adapter)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(BrandColor.subtleGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(stateColor.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(stateColor.opacity(0.2), lineWidth: 1)
                )
        )
        .onAppear {
            pulse = true
            // Anima il ring all'apparizione
            withAnimation(.spring(duration: 0.9, bounce: 0.15)) {
                animatedScore = score
            }
        }
        .onChange(of: score) { _, new in
            withAnimation(.spring(duration: 0.6)) { animatedScore = new }
        }
    }
}

// MARK: - SecurityScoreRingView

/// Anello animato che mostra il Security Score (0–100).
/// Usa Canvas per disegnare l'arco senza Layer / CAShapeLayer.
private struct SecurityScoreRingView: View {

    let score: Int
    let state: AggregatedSecurityState

    private var ringColor: Color {
        switch state {
        case .ok:        return .purple
        case .warning:   return .orange
        case .alarm:     return .red
        case .noSensors: return .secondary
        }
    }

    private var centerSymbol: String {
        switch state {
        case .ok:        return "lock.shield.fill"
        case .warning:   return "exclamationmark.shield.fill"
        case .alarm:     return "exclamationmark.shield.fill"
        case .noSensors: return "shield.slash"
        }
    }

    var body: some View {
        ZStack {
            // Anello di sfondo (grigio)
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 8)

            // Anello colorato (progresso)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Icona centrale
            VStack(spacing: 1) {
                Image(systemName: centerSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ringColor)
                Text("\(score)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(ringColor)
            }
        }
    }
}

// MARK: - SecurityMetaStat

private struct SecurityMetaStat: View {
    let value: Int
    let label: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(color)
            Text("\(value) \(label)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - SecuritySystemModePills

/// Pills in lettura della modalità corrente del sistema di allarme.
/// Il tap sulla card padre apre AccessoryDetailView per il controllo.
private struct SecuritySystemModePills: View {
    let adapter: SecuritySystemAdapter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(adapter.supportedModes) { mode in
                    let isActive = adapter.currentMode == mode
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbolName)
                            .font(.caption)
                        Text(mode.displayName)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(isActive ? .white : mode.tintColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(isActive
                                  ? AnyShapeStyle(mode.tintColor)
                                  : AnyShapeStyle(mode.tintColor.opacity(0.12)))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(isActive ? Color.clear : mode.tintColor.opacity(0.25), lineWidth: 1)
                    )
                }
            }
        }
    }
}

// MARK: - SecurityInsightsSection

private struct SecurityInsightsSection: View {
    let insights: [SecurityInsight]
    let onAccessoryTap: (UUID) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header sezione
            Button {
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Label(
                        String(localized: "security.insights.title", defaultValue: "Security analysis"),
                        systemImage: "sparkles"
                    )
                    .font(.headline)
                    .foregroundStyle(.primary)

                    Spacer()

                    // Badge count
                    Text("\(insights.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(insights.first?.priority.color ?? .purple))

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(insights) { insight in
                        SecurityInsightCard(insight: insight, onAccessoryTap: onAccessoryTap)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - SecurityInsightCard

private struct SecurityInsightCard: View {
    let insight: SecurityInsight
    let onAccessoryTap: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Bordo colorato a sinistra (3pt)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(insight.priority.color)
                .frame(width: 3)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 6) {
                // Header: priorità + stanza
                HStack(spacing: 6) {
                    Image(systemName: insight.priority.sfSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(insight.priority.color)

                    Text(insight.priority.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(insight.priority.color)

                    if let room = insight.room {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(room)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Timestamp
                    Text(insight.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Messaggio
                Text(insight.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Azione suggerita
                if let action = insight.suggestedAction, let accessoryID = insight.accessoryID {
                    Button {
                        onAccessoryTap(accessoryID)
                    } label: {
                        HStack(spacing: 4) {
                            Text(action)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .foregroundStyle(insight.priority.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(insight.priority.color.opacity(0.15), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - SecurityQuickActionsRow

/// Riga di azioni rapide per il sistema di allarme.
/// Visibile solo se è presente un SecuritySystemAdapter.
private struct SecurityQuickActionsRow: View {
    let adapter: SecuritySystemAdapter

    @State private var isPending = false
    @State private var showDisarmConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "security.actions.title", defaultValue: "Quick Actions"))
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(adapter.supportedModes) { mode in
                        SecurityModeActionButton(
                            mode: mode,
                            isActive: adapter.currentMode == mode,
                            isPending: isPending
                        ) {
                            await activateMode(mode)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .alert(
            String(localized: "security.actions.confirm.disarm", defaultValue: "Are you sure you want to disarm the alarm?"),
            isPresented: $showDisarmConfirm
        ) {
            Button(String(localized: "security.actions.disarm", defaultValue: "Disarm"), role: .destructive) {
                Task { await activateModeConfirmed(.disarm) }
            }
            Button(String(localized: "button.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
        .alert(
            errorMessage ?? "",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "button.ok", defaultValue: "OK"), role: .cancel) {}
        }
    }

    private func activateMode(_ mode: SecurityMode) async {
        if mode == .disarm && adapter.currentMode != .disarm {
            showDisarmConfirm = true
            return
        }
        await activateModeConfirmed(mode)
    }

    private func activateModeConfirmed(_ mode: SecurityMode) async {
        guard !isPending else { return }
        isPending = true
        defer { isPending = false }
        do {
            try await adapter.setMode(mode)
            UIImpactFeedbackGenerator(style: mode == .disarm ? .heavy : .medium).impactOccurred()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - SecurityModeActionButton

private struct SecurityModeActionButton: View {
    let mode: SecurityMode
    let isActive: Bool
    let isPending: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isActive ? mode.tintColor : mode.tintColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    if isPending && isActive {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(isActive ? .white : mode.tintColor)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isActive ? .white : mode.tintColor)
                    }
                }

                Text(mode.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isActive ? mode.tintColor : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 72)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive
                          ? mode.tintColor.opacity(0.1)
                          : Color(.systemBackground).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isActive ? mode.tintColor.opacity(0.4) : Color.secondary.opacity(0.15),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - SecuritySensorsSection

private struct SecuritySensorsSection: View {
    let alarmSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)]
    let warningSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)]
    let okSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)]
    @Binding var okGroupExpanded: Bool
    let onSensorTap: (HMAccessory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "security.sensors.title", defaultValue: "Monitored sensors"))
                .font(.headline)

            VStack(spacing: 12) {
                // Alarm group
                if !alarmSensors.isEmpty {
                    SecuritySensorGroup(
                        title: String(localized: "security.sensors.group.critical", defaultValue: "In alarm"),
                        color: .red,
                        sensors: alarmSensors,
                        isExpanded: .constant(true),
                        showToggle: false,
                        onSensorTap: onSensorTap
                    )
                }

                // Warning group
                if !warningSensors.isEmpty {
                    SecuritySensorGroup(
                        title: String(localized: "security.sensors.group.warning", defaultValue: "Requires attention"),
                        color: .orange,
                        sensors: warningSensors,
                        isExpanded: .constant(true),
                        showToggle: false,
                        onSensorTap: onSensorTap
                    )
                }

                // OK group (collassabile di default)
                if !okSensors.isEmpty {
                    SecuritySensorGroup(
                        title: String(localized: "security.sensors.group.ok", defaultValue: "Operational"),
                        color: .green,
                        sensors: okSensors,
                        isExpanded: $okGroupExpanded,
                        showToggle: true,
                        onSensorTap: onSensorTap
                    )
                }
            }
        }
    }
}

// MARK: - SecuritySensorGroup

private struct SecuritySensorGroup: View {
    let title: String
    let color: Color
    let sensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)]
    @Binding var isExpanded: Bool
    let showToggle: Bool
    let onSensorTap: (HMAccessory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Group header
            Button {
                if showToggle {
                    withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)

                    Text("(\(sensors.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if showToggle {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!showToggle)

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(sensors, id: \.accessory.uniqueIdentifier) { item in
                        SecuritySensorCard(accessory: item.accessory, adapter: item.adapter)
                            .onTapGesture { onSensorTap(item.accessory) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - SecuritySensorCard

/// Card sensore migliorata: icona urgenza, nome, stanza, stato, timestamp.
private struct SecuritySensorCard: View {
    let accessory: HMAccessory
    let adapter: any AccessoryAdapter

    private var urgencyColor: Color {
        switch adapter.visualUrgency {
        case .alarm:   return .red
        case .warning: return .orange
        case .ok:      return .green
        default:       return .secondary
        }
    }

    private var stateText: String {
        if let text = adapter.primaryStatusText, !text.isEmpty { return text }
        switch adapter.visualUrgency {
        case .alarm:   return String(localized: "security.state.alarm",   defaultValue: "Alarm")
        case .warning: return String(localized: "security.state.warning", defaultValue: "Warning")
        default:       return String(localized: "security.state.ok",      defaultValue: "Operational")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icona + badge urgenza
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(urgencyColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: adapter.iconName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                }

                Spacer()

                // Badge stato urgente
                if adapter.visualUrgency == .alarm || adapter.visualUrgency == .warning {
                    Circle()
                        .fill(urgencyColor)
                        .frame(width: 10, height: 10)
                }
            }

            // Informazioni
            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let roomName = accessory.room?.name {
                    Text(roomName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(urgencyColor)
                    .padding(.top, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            adapter.visualUrgency == .normal
                                ? Color.secondary.opacity(0.1)
                                : urgencyColor.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessory.name), \(accessory.room?.name ?? ""), \(stateText)")
    }
}

// MARK: - SecurityFloorplanBanner

/// CTA verso la modalità sicurezza sulla piantina.
/// Segnaposto per la futura integrazione overlay.
private struct SecurityFloorplanBanner: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "map.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.purple)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.purple.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "security.floorplan.banner.title", defaultValue: "Security map"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "security.floorplan.banner.subtitle",
                            defaultValue: "View sensors and alarms on the floorplan"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.purple.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
        // TODO: navigazione futura verso FloorplanEditorView in modalità sicurezza
        .accessibilityLabel(
            String(localized: "security.floorplan.banner.title", defaultValue: "Security map")
        )
    }
}

// MARK: - SecurityCameraSection

private struct SecurityCameraSection: View {
    let cameras: [(accessory: HMAccessory, adapter: CameraAdapter)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "security.cameras.title", defaultValue: "Cameras"))
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(cameras, id: \.accessory.uniqueIdentifier) { item in
                    CameraFeedCard(accessory: item.accessory, adapter: item.adapter)
                }
            }
        }
    }
}

// MARK: - CameraFeedCard

private struct CameraFeedCard: View {
    let accessory: HMAccessory
    let adapter: CameraAdapter

    @State private var streamState: HMCameraStreamState = .notStreaming

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let streamControl = adapter.cameraProfile?.streamControl, adapter.supportsStream {
                    CameraStreamView(streamControl: streamControl, streamState: $streamState)
                } else {
                    streamPlaceholder
                }
            }
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if adapter.motionDetected || adapter.occupancyDetected {
                    Label(
                        adapter.motionDetected
                            ? String(localized: "camera.status.motion", defaultValue: "Motion")
                            : String(localized: "camera.status.occupancy", defaultValue: "Presence"),
                        systemImage: "figure.walk.motion"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .padding(6)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: adapter.iconName)
                    .font(.caption2)
                    .foregroundStyle(adapter.motionDetected || adapter.occupancyDetected ? .orange : .secondary)
                Text(accessory.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let room = accessory.room?.name {
                    Text("· \(room)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var streamPlaceholder: some View {
        Rectangle()
            .fill(Color.black.opacity(0.85))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: adapter.visualUrgency == .alarm ? "video.slash.fill" : "video")
                        .font(.title3)
                        .foregroundStyle(adapter.visualUrgency == .alarm ? .red.opacity(0.8) : .white.opacity(0.4))
                    if let status = adapter.primaryStatusText {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
    }
}

// MARK: - SecurityConfigSheet

private struct SecurityConfigSheet: View {
    let adapters: [(accessory: HMAccessory, adapter: any AccessoryAdapter)]
    @Binding var monitoredUUIDsRaw: String
    @Environment(\.dismiss) private var dismiss

    private var monitoredUUIDs: Set<String> {
        Set(monitoredUUIDsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var byRoom: [(roomName: String, items: [(accessory: HMAccessory, adapter: any AccessoryAdapter)])] {
        let grouped = Dictionary(
            grouping: adapters,
            by: { $0.accessory.room?.name ?? String(localized: "room.noRoom", defaultValue: "No room") }
        )
        return grouped.map { (roomName: $0.key, items: $0.value) }.sorted { $0.roomName < $1.roomName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "security.config.description",
                                defaultValue: "Choose which sensors and locks to monitor. They'll appear in the Security view and contribute to the aggregated status."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                ForEach(byRoom, id: \.roomName) { group in
                    Section(group.roomName) {
                        ForEach(group.items, id: \.accessory.uniqueIdentifier) { item in
                            let uuid = item.accessory.uniqueIdentifier.uuidString
                            let isOn = monitoredUUIDs.contains(uuid)
                            Toggle(isOn: Binding(
                                get: { isOn },
                                set: { newVal in toggle(uuid: uuid, on: newVal) }
                            )) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.adapter.iconName)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.accessory.name)
                                        Text(adapterTypeLabel(item.adapter))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .tint(.purple)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "security.config.title", defaultValue: "Sensors to monitor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "button.done", defaultValue: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "button.all", defaultValue: "All")) {
                        monitoredUUIDsRaw = adapters
                            .map { $0.accessory.uniqueIdentifier.uuidString }
                            .joined(separator: ",")
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func adapterTypeLabel(_ adapter: any AccessoryAdapter) -> String {
        if adapter is DoorLockAdapter {
            return String(localized: "security.type.lock", defaultValue: "Door lock")
        }
        if let sensor = adapter as? SensorAdapter {
            if sensor.smokeDetected != nil        { return String(localized: "security.type.smoke",     defaultValue: "Smoke detector") }
            if sensor.carbonMonoxideDetected != nil { return String(localized: "security.type.co",      defaultValue: "CO detector") }
            if sensor.leakDetected != nil          { return String(localized: "security.type.leak",     defaultValue: "Water leak sensor") }
            if sensor.contactDetected != nil       { return String(localized: "security.type.contact",  defaultValue: "Contact sensor") }
            if sensor.motionDetected != nil        { return String(localized: "security.type.motion",   defaultValue: "Motion sensor") }
            if sensor.occupancyDetected != nil     { return String(localized: "security.type.occupancy", defaultValue: "Occupancy sensor") }
        }
        return String(localized: "security.type.sensor", defaultValue: "Sensor")
    }

    private func toggle(uuid: String, on: Bool) {
        var set = monitoredUUIDs
        if on { set.insert(uuid) } else { set.remove(uuid) }
        monitoredUUIDsRaw = set.joined(separator: ",")
    }
}

// MARK: - AggregatedSecurityState

enum AggregatedSecurityState {
    case ok
    case warning
    case alarm
    case noSensors

    var color: Color {
        switch self {
        case .ok:        return .green
        case .warning:   return .orange
        case .alarm:     return .red
        case .noSensors: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .ok:        return "checkmark.shield.fill"
        case .warning:   return "exclamationmark.shield.fill"
        case .alarm:     return "exclamationmark.shield.fill"
        case .noSensors: return "shield.slash"
        }
    }

    var label: String {
        switch self {
        case .ok:        return String(localized: "security.aggregate.ok",        defaultValue: "All OK")
        case .warning:   return String(localized: "security.aggregate.warning",   defaultValue: "Warning")
        case .alarm:     return String(localized: "security.aggregate.alarm",     defaultValue: "ALARM")
        case .noSensors: return String(localized: "security.aggregate.noSensors", defaultValue: "No sensors configured")
        }
    }

    var isAlarm: Bool { self == .alarm }
}

// MARK: - AlarmTriggeredView

/// Overlay a schermo intero mostrato automaticamente quando il sistema di allarme si triggera.
/// Mostra: header pulsante rosso, feed live delle telecamere, elenco dei trigger, bottone disarma.
/// Auto-contenuta: legge HomeKitService dall'environment, nessun parametro richiesto.
struct AlarmTriggeredView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.dismiss) private var dismiss
    @State private var isPending = false
    @State private var errorMessage: String?
    @State private var pulse = false

    // MARK: - Computed

    private var securitySystem: (accessory: HMAccessory, adapter: SecuritySystemAdapter)? {
        guard let home = homeKit.currentHome else { return nil }
        for acc in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? SecuritySystemAdapter {
                return (acc, adapter)
            }
        }
        return nil
    }

    private var cameras: [(accessory: HMAccessory, adapter: CameraAdapter)] {
        guard let home = homeKit.currentHome else { return [] }
        return home.accessories.compactMap { acc -> (HMAccessory, CameraAdapter)? in
            guard let cam = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? CameraAdapter else { return nil }
            return (acc, cam)
        }.sorted { ($0.0.room?.name ?? "") < ($1.0.room?.name ?? "") }
    }

    private var insights: [SecurityInsight] {
        guard let home = homeKit.currentHome else { return [] }
        var allSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)] = []
        for acc in home.accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            if adapter is SensorAdapter || adapter is DoorLockAdapter || adapter is GarageDoorAdapter {
                allSensors.append((acc, adapter))
            }
        }
        return SecurityScoreService.buildInsights(sensors: allSensors, system: securitySystem)
            .filter { $0.priority == .critical }
    }

    var body: some View {
        ZStack {
            Color.red.opacity(pulse ? 0.08 : 0.03)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 0) {
                alarmHeader

                ScrollView {
                    VStack(spacing: 20) {
                        if !cameras.isEmpty {
                            cameraFeedsSection
                        }
                        if !insights.isEmpty {
                            triggersSection
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }

                disarmFooter
            }
        }
        .onAppear { pulse = true }
        .alert(errorMessage ?? "", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "button.ok", defaultValue: "OK"), role: .cancel) {}
        }
    }

    // MARK: - Subviews

    private var alarmHeader: some View {
        ZStack(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .trailing], 20)

            VStack(spacing: 10) {
                Spacer().frame(height: 16)
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(String(localized: "alarm.triggered.title", defaultValue: "ALARM ACTIVE"))
                    .font(.title.weight(.black))
                    .foregroundStyle(.red)
                Text(String(localized: "alarm.triggered.subtitle",
                            defaultValue: "Check cameras and sensors below, then disarm if safe."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer().frame(height: 4)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 8)
    }

    private var cameraFeedsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "alarm.cameras", defaultValue: "Live cameras"),
                  systemImage: "video.fill")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(cameras, id: \.accessory.uniqueIdentifier) { item in
                    CameraFeedCard(accessory: item.accessory, adapter: item.adapter)
                }
            }
        }
    }

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "alarm.triggers", defaultValue: "Alarm triggers"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(insights) { insight in
                HStack(spacing: 12) {
                    Image(systemName: insight.sfSymbol)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 36, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.message)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let room = insight.room {
                            Text(room)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.red.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.red.opacity(0.2), lineWidth: 1)
                        )
                )
            }
        }
    }

    private var disarmFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task { await disarm() }
            } label: {
                HStack(spacing: 10) {
                    if isPending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "lock.open.fill")
                            .font(.title3)
                    }
                    Text(String(localized: "alarm.disarm.action", defaultValue: "Disarm Alarm"))
                        .font(.title3.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .foregroundStyle(.white)
                .background(
                    Color.red.opacity(isPending ? 0.6 : 1.0),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(isPending || securitySystem == nil)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func disarm() async {
        guard let sys = securitySystem, !isPending else { return }
        isPending = true
        defer { isPending = false }
        do {
            try await sys.adapter.setMode(.disarm)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Helpers

private struct IdentifiableAccessory: Identifiable {
    let accessory: HMAccessory
    var id: UUID { accessory.uniqueIdentifier }
    init(_ accessory: HMAccessory) { self.accessory = accessory }
}
