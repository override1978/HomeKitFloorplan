import SwiftUI
import SwiftData

// MARK: - IntelligenceOverlayView

/// Overlay that highlights rooms that have pending AI habit suggestions.
/// Tapping a room opens the context panel showing the suggestions for that room.
struct IntelligenceOverlayView: View {

    let floorplan: Floorplan
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerSize: CGSize
    /// Pre-computed from the parent — avoids reloading the image just to get its size.
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let effectiveOffset: CGSize

    @Query(
        filter: #Predicate<PersistedHomeInsight> { $0.statusRaw == "active" },
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var activeHomeInsights: [PersistedHomeInsight]

    @State private var activeCalloutRoomID: UUID?
    @State private var dismissedCalloutKeys: Set<String> = []
    @State private var isCalloutTourInterrupted = false

    private enum RoomIntelligenceState {
        case situation(FloorplanRoomSituationSummary)
        case learning
        case needsSetup
    }

    // MARK: Derived

    private var helper: FloorplanCoordinateHelper {
        FloorplanCoordinateHelper(imageRect: imageRect)
    }

    private var activeSituations: [HomeSituation] {
        HomeSituationResolver.resolve(floorplanRelevantInsights, granularity: .device)
    }

    private var floorplanRelevantInsights: [HomeInsight] {
        activeHomeInsights
            .map { $0.toHomeInsight() }
            .filter(Self.isFloorplanRelevant)
    }

    private var roomSituationSummaries: [FloorplanRoomSituationSummary] {
        floorplan.linkedRooms.compactMap { situationSummary(for: $0) }
    }

    private var calloutTourSummaries: [FloorplanRoomSituationSummary] {
        roomSituationSummaries
            .filter { !dismissedCalloutKeys.contains($0.calloutKey) }
            .sorted { lhs, rhs in
                let lhsSeverity = Self.severityRank(lhs.severity)
                let rhsSeverity = Self.severityRank(rhs.severity)
                if lhsSeverity != rhsSeverity {
                    return lhsSeverity > rhsSeverity
                }
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.roomName.localizedCaseInsensitiveCompare(rhs.roomName) == .orderedAscending
            }
    }

    private var activeCalloutSummary: FloorplanRoomSituationSummary? {
        guard let activeCalloutRoomID else { return nil }
        return roomSituationSummaries.first { $0.roomID == activeCalloutRoomID }
    }

    private var calloutTourTaskKey: String {
        calloutTourSummaries.map(\.calloutKey).joined(separator: "|")
    }

    var body: some View {
        let h = helper
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for room in floorplan.linkedRooms {
                    let path = h.overlayPath(for: room)
                    let state = intelligenceState(for: room)
                    ctx.fill(path, with: .color(fillColor(for: state)))
                    ctx.stroke(path, with: .color(borderColor(for: state).opacity(0.6)),
                               lineWidth: 1.5 / effectiveScale)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                let state = intelligenceState(for: room)
                let center = h.centroid(for: room)
                let inverseScale = 1.0 / effectiveScale

                Button {
                    overlayVM.selectRoom(room.hmRoomUUID)
                } label: {
                    intelligenceBadge(room: room, state: state)
                        .scaleEffect(inverseScale)
                }
                .buttonStyle(.plain)
                .position(center)
            }

            if let summary = activeCalloutSummary,
               let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == summary.roomID }) {
                let center = h.centroid(for: room)
                let inverseScale = 1.0 / effectiveScale

                intelligenceCallout(summary)
                    .scaleEffect(inverseScale)
                    .position(center)
                    .offset(y: -48 * inverseScale)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .task(id: calloutTourTaskKey) {
            await presentCalloutTour()
        }
        .onChange(of: overlayVM.isPanelVisible) { _, isVisible in
            guard isVisible else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isCalloutTourInterrupted = true
                activeCalloutRoomID = nil
            }
        }
    }

    // MARK: Badge

    private func intelligenceBadge(room: LinkedRoom, state: RoomIntelligenceState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badgeIcon(for: state))
                .font(.caption.weight(.bold))
            Text(badgeText(room: room, state: state))
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(badgeBackground(for: state))
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor(for: state).opacity(0.7), lineWidth: 1)
                )
        )
        .foregroundStyle(isReady(state) ? .white : Color.secondary)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func intelligenceCallout(_ summary: FloorplanRoomSituationSummary) -> some View {
        let insight = summary.primary.primary
        return Button {
            isCalloutTourInterrupted = true
            dismissedCalloutKeys.insert(summary.calloutKey)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                activeCalloutRoomID = nil
            }
            overlayVM.selectRoom(summary.roomID)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: summary.iconName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(summary.color))

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.roomName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(insight.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(summary.count == 1
                         ? String(localized: "intelligence.floorplan.callout.single", defaultValue: "1 active signal")
                         : String(format: String(localized: "intelligence.floorplan.callout.count", defaultValue: "%d active signals"), summary.count))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(summary.color)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: 270, alignment: .leading)
            // Il callout fluttua sopra la planimetria, quindi va nel vetro. Il
            // bordo colorato disegnato a mano diventa tinta: sul vetro un bordo
            // a mano è ciò che fa sembrare una superficie quasi-vetro.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassChromeSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                tint: summary.color.opacity(0.16),
                legacyBorder: summary.color.opacity(0.24),
                legacyShadow: GlassChromeShadow(color: summary.color.opacity(0.16), radius: 12, y: 4)
            )
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(format: String(localized: "intelligence.floorplan.callout.accessibility",
                                  defaultValue: "Open intelligence details for %@"),
                   summary.roomName)
        )
    }

    private func presentCalloutTour() async {
        await MainActor.run {
            activeCalloutRoomID = nil
            isCalloutTourInterrupted = false
        }

        let summaries = calloutTourSummaries
        guard !summaries.isEmpty else { return }

        try? await Task.sleep(nanoseconds: 650_000_000)
        guard !Task.isCancelled, !overlayVM.isPanelVisible else { return }

        for summary in summaries {
            guard !Task.isCancelled,
                  !overlayVM.isPanelVisible,
                  !isCalloutTourInterrupted else { return }

            await MainActor.run {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    activeCalloutRoomID = summary.roomID
                }
            }

            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if activeCalloutRoomID == summary.roomID {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        activeCalloutRoomID = nil
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 260_000_000)
        }
    }

    // MARK: Helpers

    private func intelligenceState(for room: LinkedRoom) -> RoomIntelligenceState {
        if let summary = situationSummary(for: room) {
            return .situation(summary)
        }

        return hasPlacedMarker(in: room) ? .learning : .needsSetup
    }

    private func situationSummary(for room: LinkedRoom) -> FloorplanRoomSituationSummary? {
        let roomSituations = activeSituations.filter { situation in
            matchesRoom(situation.primary, room: room)
        }
        guard !roomSituations.isEmpty else { return nil }
        return FloorplanRoomSituationSummary(room: room, situations: roomSituations)
    }

    nonisolated fileprivate static func isFloorplanRelevant(_ insight: HomeInsight) -> Bool {
        switch insight.kind {
        case .incoherence:
            return true
        case .anomaly:
            return severityRank(insight.severity) >= severityRank(.medium) || isOperationalEvidence(insight)
        case .security:
            return severityRank(insight.severity) >= severityRank(.high)
        case .habit, .opportunity, .prediction, .recommendation:
            return true
        case .environment, .maintenance, .deviceHealth:
            return severityRank(insight.severity) >= severityRank(.medium)
        }
    }

    nonisolated fileprivate static func isOperationalEvidence(_ insight: HomeInsight) -> Bool {
        insight.sourceRecordType == String(describing: HomeStateInterval.self)
    }

    nonisolated private static func severityRank(_ severity: HomeInsightSeverity) -> Int {
        switch severity {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    private func matchesRoom(_ insight: HomeInsight, room: LinkedRoom) -> Bool {
        if FloorplanRoomMatcher.matches(roomName: insight.roomName, linkedRoom: room) {
            return true
        }
        if FloorplanRoomMatcher.matches(roomName: insight.sourceEntityName, linkedRoom: room) {
            return true
        }
        return FloorplanRoomMatcher.matches(roomName: insight.relatedEntityName, linkedRoom: room)
    }

    private func hasPlacedMarker(in room: LinkedRoom) -> Bool {
        floorplan.accessories.contains { accessory in
            if accessory.linkedRoomUUID == room.hmRoomUUID {
                return true
            }
            return FloorplanRoomMatcher.contains(accessory.position, in: room)
        }
    }

    private func fillColor(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .situation(let summary):
            return summary.color.opacity(summary.severity >= .high ? 0.30 : 0.22)
        case .learning: return Color(.systemIndigo).opacity(0.08)
        case .needsSetup: return Color.gray.opacity(0.05)
        }
    }

    private func borderColor(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .situation(let summary): return summary.color
        case .learning: return Color(.systemIndigo).opacity(0.26)
        case .needsSetup: return Color.gray.opacity(0.22)
        }
    }

    private func badgeBackground(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .situation(let summary): return summary.color.opacity(0.94)
        case .learning: return Color(.systemBackground).opacity(0.82)
        case .needsSetup: return Color(.systemBackground).opacity(0.72)
        }
    }

    private func badgeIcon(for state: RoomIntelligenceState) -> String {
        switch state {
        case .situation(let summary): return summary.iconName
        case .learning: return "brain.head.profile"
        case .needsSetup: return "plus.viewfinder"
        }
    }

    private func badgeText(room: LinkedRoom, state: RoomIntelligenceState) -> String {
        switch state {
        case .situation(let summary): return "\(summary.count)"
        case .learning: return room.name
        case .needsSetup: return "Completa"
        }
    }

    private func isReady(_ state: RoomIntelligenceState) -> Bool {
        if case .situation = state { return true }
        return false
    }
}

private struct FloorplanRoomSituationSummary {
    let roomID: UUID
    let roomName: String
    let situations: [HomeSituation]

    var primary: HomeSituation { situations[0] }
    var count: Int { situations.reduce(0) { $0 + $1.sourceCount } }
    var calloutKey: String { "\(roomID.uuidString)|\(primary.id)" }

    var severity: HomeInsightSeverity {
        situations.map(\.primary.severity).max() ?? .info
    }

    var domain: HomeSituationDomain {
        primary.domain
    }

    var color: Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low:
            return domain == .routine ? Color(.systemIndigo) : .yellow
        case .info: return Color(.systemIndigo)
        }
    }

    var iconName: String {
        switch domain {
        case .air: return "wind"
        case .climate: return "thermometer.sun"
        case .lights: return "lightbulb.fill"
        case .loads: return "powerplug.fill"
        case .security: return "shield.lefthalf.filled"
        case .routine: return "sparkles"
        }
    }

    init(room: LinkedRoom, situations: [HomeSituation]) {
        self.roomID = room.hmRoomUUID
        self.roomName = room.name
        self.situations = situations
    }
}

// MARK: - IntelligenceContextDashboard

/// Context Dashboard for the Intelligence overlay mode.
///
/// Always shows the home-level intelligence summary:
/// Analysis status → all pending recommendations sorted by confidence →
/// approve/dismiss actions per pattern → suggested top action.
///
/// When `highlightedRoomID` is set (user tapped a room on the floorplan),
/// that room's recommendation rows are visually highlighted — content never changes.
struct IntelligenceContextDashboard: View {

    @Query(
        filter: #Predicate<PersistedHomeInsight> { $0.statusRaw == "active" },
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var activeHomeInsights: [PersistedHomeInsight]
    /// UUID of the room the user last tapped on the floorplan (highlight only).
    let highlightedRoomID: UUID?
    /// Linked rooms list — used to resolve the highlighted room name.
    let linkedRooms: [LinkedRoom]

    private var accent: Color { Color(.systemIndigo) }

    private var highlightedRoomName: String? {
        guard let id = highlightedRoomID else { return nil }
        return linkedRooms.first { $0.hmRoomUUID == id }?.name
    }

    private var relevantInsights: [HomeInsight] {
        activeHomeInsights
            .map { $0.toHomeInsight() }
            .filter(IntelligenceOverlayView.isFloorplanRelevant)
    }

    private var situations: [HomeSituation] {
        HomeSituationResolver.resolve(relevantInsights, granularity: .device)
    }

    private var highlightedRoomSituations: [HomeSituation] {
        guard let highlightedRoomName else { return [] }
        return situations.filter {
            FloorplanRoomMatcher.matches(
                roomName: $0.primary.roomName,
                highlightedRoomName: highlightedRoomName
            ) || FloorplanRoomMatcher.matches(
                roomName: $0.primary.sourceEntityName,
                highlightedRoomName: highlightedRoomName
            ) || FloorplanRoomMatcher.matches(
                roomName: $0.primary.relatedEntityName,
                highlightedRoomName: highlightedRoomName
            )
        }
    }

    private var visibleSituations: [HomeSituation] {
        highlightedRoomSituations.isEmpty ? situations : highlightedRoomSituations
    }

    /// Le situazioni da ELENCARE, cioè senza quella già promossa dalla card in
    /// cima al pannello.
    ///
    /// La card "Priorità della casa" mostra `visibleSituations.first`, e
    /// l'elenco partiva dallo stesso elemento: la prima riga ripeteva parola per
    /// parola la card sopra, sempre — non per caso ma per costruzione.
    private var listedSituations: [HomeSituation] {
        Array(visibleSituations.dropFirst())
    }

    private struct SeverityGroup: Identifiable {
        let severity: HomeInsightSeverity
        let situations: [HomeSituation]
        var id: String { "\(severity)" }
    }

    /// Le situazioni mostrate, raggruppate per severità e in ordine decrescente.
    ///
    /// Il taglio a sei resta applicato PRIMA del raggruppamento, così i gruppi
    /// descrivono ciò che si vede davvero: un'intestazione "Alta 4" sopra due
    /// righe sarebbe una bugia.
    private var severityGroups: [SeverityGroup] {
        let shown = Array(listedSituations.prefix(6))
        return Dictionary(grouping: shown) { $0.primary.severity }
            .map { SeverityGroup(severity: $0.key, situations: $0.value) }
            .sorted { groupRank($0.severity) > groupRank($1.severity) }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nextUsefulCard

            if !listedSituations.isEmpty {
                intelligenceSectionCard {
                    situationsSection
                }
            }
        }
    }

    private func intelligenceSectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Queste card SONO il pannello, non contenuto dentro un contenitore:
            // ognuna galleggia per conto suo sulla planimetria. Avevo letto male
            // la struttura e le avevo lasciate a materiale.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassChromeSurface(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                tint: accent.opacity(0.12),
                legacyBorder: accent.opacity(0.14),
                legacyShadow: GlassChromeShadow(color: accent.opacity(0.08), radius: 10, y: 3)
            )
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    private var situationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(situationSectionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Raggruppate per severità invece che in fila piatta.
            //
            // Il chip "Alta"/"Media" si ripeteva su ogni riga e, stando a destra
            // nello stesso HStack del testo, ne sottraeva larghezza per tutta
            // l'altezza — lo stesso difetto già corretto sulla card digest.
            // Come intestazione di gruppo lo dici una volta, e in più si vede la
            // FORMA del problema: quante cose sono davvero urgenti e quante no,
            // che in un elenco piatto di ventinove voci non si legge.
            ForEach(severityGroups) { group in
                HStack(spacing: 6) {
                    Text(severityLabel(group.severity))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(groupColor(group.severity))
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text("\(group.situations.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(groupColor(group.severity))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(groupColor(group.severity).opacity(0.12)))
                    Spacer(minLength: 0)
                }
                .padding(.top, group.id == severityGroups.first?.id ? 0 : 6)

                ForEach(group.situations) { situation in
                    situationRow(situation)
                    if situation.id != group.situations.last?.id {
                        Divider().padding(.leading, 26)
                    }
                }
            }

            if listedSituations.count > 6 {
                Text(String(format: String(localized: "intelligence.floorplan.situations.more",
                                           defaultValue: "%d more in Intelligence dashboard"),
                            listedSituations.count - 6))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    private var situationSectionTitle: String {
        if let highlightedRoomName, !highlightedRoomSituations.isEmpty {
            return String(format: String(localized: "intelligence.floorplan.situations.room",
                                         defaultValue: "%@ · Active situations"),
                          highlightedRoomName)
        }
        return String(localized: "intelligence.floorplan.situations.all",
                      defaultValue: "Active situations")
    }

    // MARK: Next useful card

    @ViewBuilder
    private var nextUsefulCard: some View {
        if let situation = highlightedRoomSituations.first, let roomName = highlightedRoomName {
            situationSummaryCard(
                title: String(format: String(localized: "intelligence.floorplan.priority.room",
                                             defaultValue: "Priority in %@"),
                              roomName),
                situation: situation,
                count: highlightedRoomSituations.count
            )
        } else if let situation = situations.first {
            situationSummaryCard(
                title: String(localized: "intelligence.floorplan.priority.home",
                              defaultValue: "Home priority"),
                situation: situation,
                count: situations.count
            )
        } else if let roomName = highlightedRoomName {
            FloorplanEmptyStateCard(
                title: String(localized: "intelligence.learning.room", defaultValue: "Learning \(roomName)"),
                message: String(localized: "intelligence.learning.room.message", defaultValue: "No reliable actions are available for this room yet. Keep using it normally; useful routines will appear here."),
                icon: "brain.head.profile",
                color: accent
            )
        } else {
            FloorplanEmptyStateCard(
                title: String(localized: "intelligence.learning.title", defaultValue: "Learning routines"),
                message: String(localized: "intelligence.learning.message", defaultValue: "No recommendations are ready. Open a room on the map to see local learning status."),
                icon: "brain.head.profile",
                color: accent
            )
        }
    }

    private func situationSummaryCard(title: String, situation: HomeSituation, count: Int) -> some View {
        let insight = situation.primary
        return FloorplanStatusSummaryCard(
            title: title,
            message: insight.message,
            icon: iconName(for: situation.domain),
            color: color(for: insight.severity, domain: situation.domain),
            metrics: [
                FloorplanStatusMetric(value: severityLabel(insight.severity), label: String(localized: "intelligence.severity", defaultValue: "Severity")),
                FloorplanStatusMetric(value: "\(count)", label: String(localized: "intelligence.active", defaultValue: "Active")),
                FloorplanStatusMetric(value: "\(situation.sourceCount)", label: String(localized: "intelligence.sources", defaultValue: "Sources"))
            ]
        )
    }

    private func situationRow(_ situation: HomeSituation) -> some View {
        let insight = situation.primary
        let color = color(for: insight.severity, domain: situation.domain)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName(for: situation.domain))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(insight.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if situation.sourceCount > 1 {
                        Text("\(situation.sourceCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(color.opacity(0.12)))
                    }
                }
                Text(insight.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation = insight.recommendation {
                    Text(recommendation)
                        .font(.caption2)
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Niente chip di severità qui: lo dice l'intestazione del gruppo.
            // Toglierlo restituisce al testo la larghezza che gli sottraeva per
            // tutta l'altezza della riga, stando nello stesso HStack.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func color(for severity: HomeInsightSeverity, domain: HomeSituationDomain) -> Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low:
            return domain == .routine ? accent : .yellow
        case .info: return accent
        }
    }

    private func iconName(for domain: HomeSituationDomain) -> String {
        switch domain {
        case .air: return "wind"
        case .climate: return "thermometer.sun"
        case .lights: return "lightbulb.fill"
        case .loads: return "powerplug.fill"
        case .security: return "shield.lefthalf.filled"
        case .routine: return "sparkles"
        }
    }

    /// Colore dell'intestazione di gruppo. A differenza di `color(for:domain:)`
    /// non ha un dominio da cui partire — il gruppo raccoglie situazioni di
    /// domini diversi — quindi per le severità basse usa l'accento del pannello.
    private func groupColor(_ severity: HomeInsightSeverity) -> Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .info: return accent
        }
    }

    /// Ordinamento dei gruppi. Duplica volutamente il rank dell'overlay: sono
    /// due struct separate e passare da un metodo statico condiviso, per cinque
    /// casi, costerebbe più di quanto renda.
    private func groupRank(_ severity: HomeInsightSeverity) -> Int {
        switch severity {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .info: return 0
        }
    }

    private func severityLabel(_ severity: HomeInsightSeverity) -> String {
        switch severity {
        case .critical: return String(localized: "insight.severity.critical", defaultValue: "Critical")
        case .high: return String(localized: "insight.severity.high", defaultValue: "High")
        case .medium: return String(localized: "insight.severity.medium", defaultValue: "Medium")
        case .low: return String(localized: "insight.severity.low", defaultValue: "Low")
        case .info: return String(localized: "insight.severity.info", defaultValue: "Info")
        }
    }

    // MARK: Recommendation row

}
