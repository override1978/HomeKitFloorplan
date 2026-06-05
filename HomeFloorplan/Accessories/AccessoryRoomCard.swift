import SwiftUI
import HomeKit

// MARK: - AccessoryRoomCard

/// Card di stanza per il modulo Accessori.
///
/// Tap su qualsiasi punto della card → apre AccessoryRoomDetailView.
/// Non ha più comportamento di espansione inline: la navigazione diretta
/// è più coerente con il pattern usato in EnvironmentDashboardView.
struct AccessoryRoomCard: View {

    let room: RoomAccessoryData
    let onTap: () -> Void

    @Environment(HomeKitService.self) private var homeKit

    // MARK: - Accent color

    private var accentColor: Color {
        switch room.healthLevel {
        case .critical: return .red
        case .warning:  return .orange
        case .good, .excellent: return BrandColor.primary
        }
    }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                header
                collapsedIndicators
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            room.healthLevel == .excellent || room.healthLevel == .good
                                ? Color(.separator).opacity(0.20)
                                : accentColor.opacity(0.40),
                            lineWidth: room.healthLevel == .excellent || room.healthLevel == .good ? 0.5 : 1.5
                        )
                )
        )
        .shadow(
            color: room.healthLevel == .excellent || room.healthLevel == .good
                ? Color.black.opacity(0.05)
                : accentColor.opacity(0.08),
            radius: 8, x: 0, y: 3
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Icona stanza
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.10))
                    .frame(width: 42, height: 42)
                Image(systemName: roomIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            // Nome + sottotitolo
            VStack(alignment: .leading, spacing: 2) {
                Text(room.roomName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(room.subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Score ring + chevron navigazione
            HStack(spacing: 10) {
                AccessoryScoreRing(score: room.healthScore, color: room.healthLevel.color)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Collassata: micro-badge categoria + issue

    private var collapsedIndicators: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Riga badge categoria
            if !room.categoryBadges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(room.categoryBadges) { badge in
                            AccessoryCategoryMicroBadge(badge: badge)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Issue alert (solo se presente)
            if let issue = room.primaryIssue {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(issue)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    // MARK: - Room icon (euristica sul nome, identica a RoomSectionView)

    private var roomIcon: String {
        let n = room.roomName.lowercased()
        if n.contains("cucina") || n.contains("kitchen")                        { return "frying.pan" }
        if n.contains("bagno") || n.contains("bathroom") || n.contains("toilet"){ return "shower" }
        if n.contains("camera") || n.contains("letto") || n.contains("bedroom") { return "bed.double" }
        if n.contains("soggiorno") || n.contains("salotto") || n.contains("living") { return "sofa" }
        if n.contains("studio") || n.contains("ufficio") || n.contains("office") { return "desktopcomputer" }
        if n.contains("garage")                                                  { return "car" }
        if n.contains("giardino") || n.contains("terrazzo") || n.contains("balcon") { return "tree" }
        if n.contains("ingresso") || n.contains("entrance") || n.contains("hallway") { return "door.left.hand.open" }
        if n.contains("lavanderia") || n.contains("laundry")                    { return "washer" }
        return "house"
    }
}

// MARK: - AccessoryScoreRing

/// Cerchio di progresso per lo score 0–100 di una stanza.
/// Analogo a RoomScoreRing nel modulo Ambiente.
private struct AccessoryScoreRing: View {
    let score: Int
    let color: Color

    @State private var animated: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 4)
                .frame(width: 40, height: 40)

            Circle()
                .trim(from: 0, to: animated)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: animated)

            Text("\(score)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .onAppear { animated = CGFloat(score) / 100 }
        .onChange(of: score) { _, v in animated = CGFloat(v) / 100 }
    }
}

// MARK: - AccessoryCategoryMicroBadge

/// Micro-badge categoria: icona SF + count. Analogo a SensorMicroIndicator.
private struct AccessoryCategoryMicroBadge: View {
    let badge: AccessoryRoomCategoryBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.symbol)
                .font(.system(size: 11, weight: .medium))
            Text("\(badge.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }
}

// MARK: - Preview

#Preview("Room Card — vari stati") {
    let homeKit = HomeKitService()
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            // Excellent
            AccessoryRoomCard(
                room: RoomAccessoryData(
                    id: UUID(), roomName: "Soggiorno",
                    accessories: [],
                    totalCount: 24, offlineCount: 0, lowBatteryCount: 0,
                    healthScore: 98,
                    categoryBadges: [
                        AccessoryRoomCategoryBadge(id: .lights, count: 8, symbol: "lightbulb.fill"),
                        AccessoryRoomCategoryBadge(id: .sensors, count: 2, symbol: "sensor.fill"),
                        AccessoryRoomCategoryBadge(id: .security, count: 1, symbol: "shield.fill"),
                    ],
                    lastActivityDate: Date().addingTimeInterval(-300)
                ),
                onTap: {}
            )
            // Warning
            AccessoryRoomCard(
                room: RoomAccessoryData(
                    id: UUID(), roomName: "Bagno",
                    accessories: [],
                    totalCount: 8, offlineCount: 0, lowBatteryCount: 1,
                    healthScore: 72,
                    categoryBadges: [
                        AccessoryRoomCategoryBadge(id: .lights, count: 4, symbol: "lightbulb.fill"),
                        AccessoryRoomCategoryBadge(id: .sensors, count: 1, symbol: "sensor.fill"),
                    ],
                    lastActivityDate: nil
                ),
                onTap: {}
            )
            // Critical
            AccessoryRoomCard(
                room: RoomAccessoryData(
                    id: UUID(), roomName: "Garage",
                    accessories: [],
                    totalCount: 6, offlineCount: 2, lowBatteryCount: 0,
                    healthScore: 40,
                    categoryBadges: [
                        AccessoryRoomCategoryBadge(id: .security, count: 2, symbol: "shield.fill"),
                        AccessoryRoomCategoryBadge(id: .lights, count: 2, symbol: "lightbulb.fill"),
                    ],
                    lastActivityDate: nil
                ),
                onTap: {}
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .environment(homeKit)
}
