import SwiftUI

// MARK: - AccessoriesHeroView
//
// Hero section del modulo Accessori.
// Architettura identica a EnvironmentHeroView.
//
// Risponde alla domanda: "I miei dispositivi stanno bene?"
//
// Layout:
//   ┌─────────────────────────────────────────────────────┐
//   │  [icon]  ACCESSORI                    N acc • M stanze │
//   │                                                     │
//   │   94          Ottima                                │
//   │   ══          ──────        Tutti ok / N problemi   │
//   │                                                     │
//   │  ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  barra progresso            │
//   └─────────────────────────────────────────────────────┘

struct AccessoriesHeroView: View {

    let score: Int                  // 0–100
    let level: AccessoryHealthLevel
    let totalAccessories: Int
    let totalRooms: Int
    let offlineCount: Int
    let lowBatteryCount: Int

    @State private var animatedProgress: CGFloat = 0

    // MARK: - Hero icon

    private var heroIcon: String {
        switch level {
        case .excellent: return "house.fill"
        case .good:      return "checkmark.circle.fill"
        case .warning:   return "exclamationmark.triangle.fill"
        case .critical:  return "exclamationmark.octagon.fill"
        }
    }

    // MARK: - Summary subtitle (N accessories • M rooms)

    private var summaryText: String {
        let accUnit = totalAccessories == 1
            ? String(localized: "accessories.room.accessory.singular", defaultValue: "1 accessorio")
            : "\(totalAccessories) \(String(localized: "accessories.room.accessories.unit", defaultValue: "accessori"))"
        let roomUnit = totalRooms == 1
            ? "1 \(String(localized: "accessories.hero.room.singular", defaultValue: "stanza"))"
            : "\(totalRooms) \(String(localized: "accessories.hero.room.plural", defaultValue: "stanze"))"
        return "\(accUnit) • \(roomUnit)"
    }

    // MARK: - Alert badge text

    private var alertText: String? {
        if offlineCount > 0 && lowBatteryCount > 0 {
            return "\(offlineCount) offline • \(lowBatteryCount) \(String(localized: "accessories.hero.lowBattery.short", defaultValue: "batteria"))"
        }
        if offlineCount > 0 {
            return String(format: String(localized: "accessories.hero.offline", defaultValue: "%lld offline"), offlineCount)
        }
        if lowBatteryCount > 0 {
            return String(format: String(localized: "accessories.hero.lowBattery", defaultValue: "%lld batteria scarica"), lowBatteryCount)
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Riga superiore: label sezione + sommario ──────────────
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: heroIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(level.color)

                Text(String(localized: "accessories.hero.title", defaultValue: "ACCESSORI"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // ── Riga centrale: score numerico + label + badge ─────────
            HStack(alignment: .bottom, spacing: 0) {

                // Score grande animato
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(score)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(level.color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    // Nessuna unità: il numero è già su scala 0–100
                }

                Spacer()

                // Colonna destra: label livello + badge alert
                VStack(alignment: .trailing, spacing: 6) {
                    Text(level.label)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    if let alert = alertText {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text(alert)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.10), in: Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text(String(localized: "accessories.hero.allHealthy",
                                        defaultValue: "Tutti i dispositivi funzionano correttamente"))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.10), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // ── Barra progresso full-width ────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(level.color.opacity(0.12))
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [level.color.opacity(0.7), level.color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * animatedProgress), height: 5)
                        .animation(.spring(response: 1.0, dampingFraction: 0.75), value: animatedProgress)
                }
            }
            .frame(height: 5)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(level.color.opacity(0.6))
                        .frame(height: 3)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: level.color.opacity(0.12), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) {
                animatedProgress = CGFloat(score) / 100
            }
        }
        .onChange(of: score) { _, v in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                animatedProgress = CGFloat(v) / 100
            }
        }
    }
}

// MARK: - Preview

#Preview("Hero — vari stati") {
    ScrollView {
        VStack(spacing: 16) {
            AccessoriesHeroView(
                score: 98, level: .excellent,
                totalAccessories: 48, totalRooms: 6,
                offlineCount: 0, lowBatteryCount: 0
            )
            AccessoriesHeroView(
                score: 78, level: .good,
                totalAccessories: 32, totalRooms: 4,
                offlineCount: 0, lowBatteryCount: 2
            )
            AccessoriesHeroView(
                score: 55, level: .warning,
                totalAccessories: 20, totalRooms: 3,
                offlineCount: 1, lowBatteryCount: 1
            )
            AccessoriesHeroView(
                score: 25, level: .critical,
                totalAccessories: 15, totalRooms: 2,
                offlineCount: 3, lowBatteryCount: 2
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
