import SwiftUI

// MARK: - AlarmStatusPill

/// Horizontal pill shown below the mode selector in Security overlay mode.
/// Displays the current alarm state (Casa / Fuori / Notte / Disinserito / ALLARME)
/// together with the day and time the mode was last activated.
struct AlarmStatusPill: View {

    let adapter: SecuritySystemAdapter
    /// When the mode was last set — nil if not yet tracked.
    let activationDate: Date?

    @State private var pulseOpacity: Double = 0.55
    @State private var pulseScale: CGFloat = 1.0

    private var isTriggered: Bool { adapter.isTriggered }
    private var mode: SecurityMode { adapter.currentMode }

    private var pillColor: Color {
        isTriggered ? .red : mode.tintColor
    }

    private var icon: String {
        isTriggered ? "exclamationmark.shield.fill" : mode.symbolName
    }

    private var modeLabel: String {
        isTriggered
            ? String(localized: "security.alarmActive", defaultValue: "ALLARME ATTIVO")
            : mode.displayName
    }

    private var activationLabel: String? {
        guard let date = activationDate else { return nil }
        let formatter = DateFormatter()
        // Show "Oggi HH:mm" or "E d MMM HH:mm" for earlier days
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return String(format: String(localized: "security.pill.today", defaultValue: "Oggi %@"), formatter.string(from: date))
        } else if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return String(format: String(localized: "security.pill.yesterday", defaultValue: "Ieri %@"), formatter.string(from: date))
        } else {
            formatter.dateFormat = "d MMM, HH:mm"
            return formatter.string(from: date)
        }
    }

    var body: some View {
        GlassTitlePill {
            HStack(spacing: 8) {
                // Pulsing icon (only when triggered)
                ZStack {
                    if isTriggered {
                        Circle()
                            .stroke(pillColor.opacity(pulseOpacity), lineWidth: 2)
                            .frame(width: 24, height: 24)
                            .scaleEffect(pulseScale)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(pillColor)
                }
                .frame(width: 20, height: 20)

                // Mode name
                Text(modeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pillColor)

                // Separator + timestamp
                if let label = activationLabel {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 12)

                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .id(isTriggered) // reset pulse animation when triggered state changes
        .onAppear { if isTriggered { startPulse() } }
    }

    private func startPulse() {
        pulseOpacity = 0.55
        pulseScale = 1.0
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.0
            pulseScale = 1.5
        }
    }
}
