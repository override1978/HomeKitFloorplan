import SwiftUI

// MARK: - SensorCardView

/// Card compatta di un singolo sensore. Layout orizzontale a riga fissa:
/// icona colorata | valore bold | label tipo  •  badge urgency opzionale.
struct SensorCardView: View {

    let sensor: SensorData

    private var accent: Color {
        sensor.urgency == .normal ? BrandColor.primary : sensor.urgency.color
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icona in cerchietto colorato
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: sensor.serviceType.sfSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            // Valore + label impilati
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.formattedValue)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(sensor.urgency == .normal ? .primary : accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())

                Text(sensor.serviceType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Badge urgency (solo warning/danger)
            if sensor.urgency != .normal {
                Image(systemName: sensor.urgency.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(sensor.urgency.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(sensor.urgency == .normal
                      ? Color(.tertiarySystemGroupedBackground)
                      : sensor.urgency.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accent.opacity(sensor.urgency == .normal ? 0.15 : 0.4),
                                      lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview {
    let now = Date()
    VStack(spacing: 8) {
        SensorCardView(sensor: SensorData(
            id: UUID(), accessoryUUIDs: ["x1"], serviceType: .temperature,
            roomName: "Cucina", currentValue: 24.5, lastUpdated: now,
            warningThreshold: 28, dangerThreshold: 32, sourceCount: 1
        ))
        SensorCardView(sensor: SensorData(
            id: UUID(), accessoryUUIDs: ["x2"], serviceType: .humidity,
            roomName: "Cucina", currentValue: 68.0, lastUpdated: now,
            warningThreshold: 65, dangerThreshold: 75, sourceCount: 1
        ))
        SensorCardView(sensor: SensorData(
            id: UUID(), accessoryUUIDs: ["x3"], serviceType: .carbonMonoxide,
            roomName: "Cucina", currentValue: 27.0, lastUpdated: now,
            warningThreshold: 10, dangerThreshold: 25, sourceCount: 1
        ))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
