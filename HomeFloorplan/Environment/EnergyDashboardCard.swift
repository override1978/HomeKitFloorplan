import SwiftUI
import SwiftData
import HomeKit

// MARK: - EnergyDashboardCard

/// Compact widget showing estimated energy usage per room derived from AccessoryEvent history.
/// Integrates into EnvironmentDashboardView between the AI Digest and the room grid.
struct EnergyDashboardCard: View {

    let modelContainer: ModelContainer

    @Environment(HomeKitService.self) private var homeKit

    @State private var records: [EnergyUsageRecord] = []
    @State private var signals: [EnergySignal] = []
    @State private var isLoading = true

    // MARK: - Derived

    private static let energyEventTypes: Set<String> = [
        "light", "switch", "thermostat", "fan", "airPurifier", "outlet"
    ]

    /// Per-room aggregates sorted by total hours today descending.
    private var roomGroups: [(room: String, totalHours: Double, topName: String, hasAnomaly: Bool)] {
        var byRoom: [String: (hours: Double, topName: String, topHours: Double)] = [:]
        for r in records where r.totalHoursToday > 0 && Self.energyEventTypes.contains(r.eventType) {
            let room = r.roomName.isEmpty
                ? String(localized: "energy.room.unknown", defaultValue: "Unknown Room")
                : r.roomName
            var entry = byRoom[room] ?? (hours: 0, topName: r.accessoryName, topHours: 0)
            entry.hours += r.totalHoursToday
            if r.totalHoursToday > entry.topHours {
                entry.topName  = r.accessoryName
                entry.topHours = r.totalHoursToday
            }
            byRoom[room] = entry
        }
        let anomalyRooms = Set(signals.map(\.roomName))
        return byRoom.map { room, data in
            (room: room, totalHours: data.hours, topName: data.topName, hasAnomaly: anomalyRooms.contains(room))
        }
        .sorted { $0.totalHours > $1.totalHours }
    }

    private var totalHoursToday: Double { records.reduce(0) { $0 + $1.totalHoursToday } }
    private var anomalyCount: Int { signals.count }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading {
                loadingRow
            } else if roomGroups.isEmpty {
                emptyRow
            } else {
                roomList
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task {
            let ignored = EnergyIgnoreStore.ignoredIDs

            // Legge lo stato corrente ON/OFF di ogni accessorio da HomeKit.
            // Passato al tracker per riconciliare la storia degli eventi con la realtà:
            // evita sessioni fantoma (evento OFF perso) e rileva accessori ON non registrati.
            let currentStates = buildCurrentStates()

            let r            = await EnergyUsageTracker.analyze(
                                    modelContainer: modelContainer,
                                    currentStates:  currentStates)
            records          = r.filter { !ignored.contains($0.accessoryID) }
            let allSignals   = EnergyInsightBuilder.build(records: records, ignoredIDs: ignored)
            let dismissedKeys = fetchDismissedEnergyKeys()
            signals          = allSignals.filter { !dismissedKeys.contains($0.semanticKey) }
            isLoading        = false
        }
    }

    // MARK: - Helpers

    /// Costruisce una mappa `accessoryID → isCurrentlyOn` leggendo i valori correnti da HomeKit.
    /// Controlla sia PowerState (0x25 — luci/switch) che Active (0xB0 — termostati/fan/prese).
    private func buildCurrentStates() -> [UUID: Bool] {
        let powerStateUUID = "00000025-0000-1000-8000-0026bb765291"
        let activeUUID     = "000000b0-0000-1000-8000-0026bb765291"
        var states: [UUID: Bool] = [:]
        for accessory in homeKit.allAccessories {
            let allChars = accessory.services.flatMap(\.characteristics)
            let char = allChars.first { $0.characteristicType.lowercased() == activeUUID }
                    ?? allChars.first { $0.characteristicType.lowercased() == powerStateUUID }
            guard let char, let val = homeKit.value(for: char) else { continue }
            let raw = (val as? Int) ?? (val as? NSNumber)?.intValue ?? 0
            states[accessory.uniqueIdentifier] = raw != 0
        }
        return states
    }

    /// Returns semantic keys of energy notifications dismissed or snoozed in the last 48 hours.
    /// Used to suppress anomaly indicators that the user has already actioned in the feed.
    private func fetchDismissedEnergyKeys() -> Set<String> {
        let ctx    = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let descriptor = FetchDescriptor<ProactiveNotification>(
            predicate: #Predicate {
                $0.categoryRaw == "energy" &&
                ($0.statusRaw == "dismissed" || $0.statusRaw == "snoozed") &&
                $0.lastUpdatedAt >= cutoff
            }
        )
        let dismissed = (try? ctx.fetch(descriptor)) ?? []
        return Set(dismissed.map(\.semanticKey))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.yellow)
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "energy.card.title", defaultValue: "Energy Consumption"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if !isLoading {
                if anomalyCount > 0 {
                    Label(
                        String(format: String(localized: "energy.card.anomalies", defaultValue: "%d anomalies"), anomalyCount),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                } else {
                    let hours = String(format: "%.1fh", totalHoursToday)
                    Text(String(format: String(localized: "energy.card.totalToday", defaultValue: "%@ today"), hours))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var loadingRow: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text(String(localized: "energy.card.loading", defaultValue: "Analysing usage…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var emptyRow: some View {
        Text(String(localized: "energy.card.empty", defaultValue: "No data yet. Usage will be calculated after a few days of use."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    private var roomList: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 14)
            ForEach(roomGroups.prefix(4), id: \.room) { group in
                roomRow(group)
                if group.room != roomGroups.prefix(4).last?.room {
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    private func roomRow(_ group: (room: String, totalHours: Double, topName: String, hasAnomaly: Bool)) -> some View {
        HStack(spacing: 10) {
            // Room name
            VStack(alignment: .leading, spacing: 2) {
                Text(group.room)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.topName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // Hours bar
            let barWidth = min(60, max(8, CGFloat(group.totalHours / max(1, roomGroups.first?.totalHours ?? 1)) * 60))
            RoundedRectangle(cornerRadius: 3)
                .fill(group.hasAnomaly ? Color.orange.opacity(0.7) : Color.yellow.opacity(0.6))
                .frame(width: barWidth, height: 6)
            // Hours label
            Text(String(format: "%.1fh", group.totalHours))
                .font(.caption.monospacedDigit())
                .foregroundStyle(group.hasAnomaly ? .orange : .secondary)
                .frame(minWidth: 36, alignment: .trailing)
            // Anomaly indicator
            if group.hasAnomaly {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
