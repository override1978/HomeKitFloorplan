import SwiftUI
import SwiftData

// MARK: - EnergyDashboardCard

/// Compact widget showing estimated energy usage per room derived from AccessoryEvent history.
/// Integrates into EnvironmentDashboardView between the AI Digest and the room grid.
struct EnergyDashboardCard: View {

    let modelContainer: ModelContainer

    @State private var records: [EnergyUsageRecord] = []
    @State private var signals: [EnergySignal] = []
    @State private var isLoading = true

    // MARK: - Derived

    /// Per-room aggregates sorted by total hours today descending.
    private var roomGroups: [(room: String, totalHours: Double, topName: String, hasAnomaly: Bool)] {
        var byRoom: [String: (hours: Double, topName: String, topHours: Double)] = [:]
        for r in records where r.totalHoursToday > 0 {
            let room = r.roomName.isEmpty
                ? String(localized: "energy.room.unknown", defaultValue: "Stanza sconosciuta")
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
            let r = await EnergyUsageTracker.analyze(modelContainer: modelContainer)
            records = r
            signals = EnergyInsightBuilder.build(records: r)
            isLoading = false
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.yellow)
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "energy.card.title", defaultValue: "Consumo Energetico"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if !isLoading {
                if anomalyCount > 0 {
                    Label(
                        String(format: String(localized: "energy.card.anomalies", defaultValue: "%d anomali"), anomalyCount),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                } else {
                    let hours = String(format: "%.1fh", totalHoursToday)
                    Text(String(format: String(localized: "energy.card.totalToday", defaultValue: "%@ oggi"), hours))
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
            Text(String(localized: "energy.card.loading", defaultValue: "Analisi consumi…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var emptyRow: some View {
        Text(String(localized: "energy.card.empty", defaultValue: "Dati non ancora disponibili. Verranno calcolati dopo alcuni giorni di utilizzo."))
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
