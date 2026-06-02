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

    private var securityScore: Int {
        SecurityScoreService.computeScore(monitoredSensors: monitoredSensors, securitySystem: securitySystem)
    }

    private var securityInsights: [SecurityInsight] {
        SecurityScoreService.buildInsights(sensors: monitoredSensors, system: securitySystem)
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

    // MARK: - Body

    var body: some View {
        navigationContent
            .task { startObserving() }
            .onDisappear { stopObserving() }
    }

    private var navigationContent: some View {
        NavigationStack {
            securityContent
                .navigationTitle(String(localized: "security.title", defaultValue: "Sicurezza"))
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

                // 5. Banner piantina — disabilitato, attivare in futuro
                // SecurityFloorplanBanner()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Empty states

    private var emptyStateNoDevices: some View {
        ContentUnavailableView {
            Label(
                String(localized: "security.empty.noDevices.title", defaultValue: "Nessun dispositivo di sicurezza"),
                systemImage: "shield.slash"
            )
        } description: {
            Text(String(localized: "security.empty.noDevices.description",
                        defaultValue: "Aggiungi sensori di contatto, fumo, CO, perdita acqua, serrature o un sistema di allarme in HomeKit."))
        }
    }

    private var emptyStateNoMonitored: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "security.empty.noMonitored.title", defaultValue: "Nessun sensore monitorato"))
                .font(.headline)
            Text(String(localized: "security.empty.noMonitored.description",
                        defaultValue: "Configura i sensori da monitorare per vedere lo stato di sicurezza della tua casa."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button { showConfigSheet = true } label: {
                Label(String(localized: "security.configureSensors", defaultValue: "Configura sensori"),
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
        case .ok:        return String(localized: "security.hero.status.protected", defaultValue: "Buona protezione")
        case .warning:   return String(localized: "security.hero.status.warning",   defaultValue: "Attenzione richiesta")
        case .alarm:     return String(localized: "security.hero.status.alarm",     defaultValue: "ALLARME ATTIVO")
        case .noSensors: return String(localized: "security.hero.status.noSensors", defaultValue: "Nessun sensore")
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
                    Text(String(localized: "security.hero.title", defaultValue: "Sicurezza Casa"))
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
                                              defaultValue: "avvisi"),
                                color: warningCount > 0 ? stateColor : .secondary,
                                symbol: "exclamationmark.triangle.fill"
                            )
                        }
                        SecurityMetaStat(
                            value: monitoredCount,
                            label: String(localized: "security.hero.sensors",
                                          defaultValue: "sensori"),
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
                        String(localized: "security.insights.title", defaultValue: "Analisi sicurezza"),
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
            Text(String(localized: "security.actions.title", defaultValue: "Azioni rapide"))
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
            String(localized: "security.actions.confirm.disarm", defaultValue: "Confermi di voler disinserire l'allarme?"),
            isPresented: $showDisarmConfirm
        ) {
            Button(String(localized: "security.actions.disarm", defaultValue: "Disinserisci"), role: .destructive) {
                Task { await activateModeConfirmed(.disarm) }
            }
            Button(String(localized: "button.cancel", defaultValue: "Annulla"), role: .cancel) {}
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
            Text(String(localized: "security.sensors.title", defaultValue: "Sensori monitorati"))
                .font(.headline)

            VStack(spacing: 12) {
                // Alarm group
                if !alarmSensors.isEmpty {
                    SecuritySensorGroup(
                        title: String(localized: "security.sensors.group.critical", defaultValue: "In allarme"),
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
                        title: String(localized: "security.sensors.group.warning", defaultValue: "Richiede attenzione"),
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
                        title: String(localized: "security.sensors.group.ok", defaultValue: "Operativi"),
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
        case .alarm:   return String(localized: "security.state.alarm",   defaultValue: "Allarme")
        case .warning: return String(localized: "security.state.warning", defaultValue: "Attenzione")
        default:       return String(localized: "security.state.ok",      defaultValue: "Operativo")
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
                Text(String(localized: "security.floorplan.banner.title", defaultValue: "Mappa di sicurezza"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "security.floorplan.banner.subtitle",
                            defaultValue: "Visualizza sensori e allarmi sulla piantina"))
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
            String(localized: "security.floorplan.banner.title", defaultValue: "Mappa di sicurezza")
        )
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
            by: { $0.accessory.room?.name ?? String(localized: "room.noRoom", defaultValue: "Senza stanza") }
        )
        return grouped.map { (roomName: $0.key, items: $0.value) }.sorted { $0.roomName < $1.roomName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "security.config.description",
                                defaultValue: "Scegli quali sensori e serrature vuoi monitorare. Appariranno nella vista Sicurezza e contribuiranno allo stato aggregato."))
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
            .navigationTitle(String(localized: "security.config.title", defaultValue: "Sensori da monitorare"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "button.done", defaultValue: "Fine")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "button.all", defaultValue: "Tutti")) {
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
            return String(localized: "security.type.lock", defaultValue: "Serratura")
        }
        if let sensor = adapter as? SensorAdapter {
            if sensor.smokeDetected != nil        { return String(localized: "security.type.smoke",     defaultValue: "Rilevatore fumo") }
            if sensor.carbonMonoxideDetected != nil { return String(localized: "security.type.co",      defaultValue: "Rilevatore CO") }
            if sensor.leakDetected != nil          { return String(localized: "security.type.leak",     defaultValue: "Sensore perdita acqua") }
            if sensor.contactDetected != nil       { return String(localized: "security.type.contact",  defaultValue: "Sensore contatto") }
            if sensor.motionDetected != nil        { return String(localized: "security.type.motion",   defaultValue: "Sensore movimento") }
            if sensor.occupancyDetected != nil     { return String(localized: "security.type.occupancy", defaultValue: "Sensore occupazione") }
        }
        return String(localized: "security.type.sensor", defaultValue: "Sensore")
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
        case .ok:        return String(localized: "security.aggregate.ok",        defaultValue: "Tutto OK")
        case .warning:   return String(localized: "security.aggregate.warning",   defaultValue: "Attenzione")
        case .alarm:     return String(localized: "security.aggregate.alarm",     defaultValue: "ALLARME")
        case .noSensors: return String(localized: "security.aggregate.noSensors", defaultValue: "Nessun sensore configurato")
        }
    }

    var isAlarm: Bool { self == .alarm }
}

// MARK: - Helpers

private struct IdentifiableAccessory: Identifiable {
    let accessory: HMAccessory
    var id: UUID { accessory.uniqueIdentifier }
    init(_ accessory: HMAccessory) { self.accessory = accessory }
}
