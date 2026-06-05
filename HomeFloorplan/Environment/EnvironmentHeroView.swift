import SwiftUI

// MARK: - EnvironmentHeroView
//
// Hero section ispirata ad Apple Health / Apple Weather.
// Risponde alla domanda primaria: "La mia casa sta bene adesso?"
//
// Layout (iPad landscape):
//   ┌──────────────────────────────────────────────────────────────┐
//   │  [icon]  SALUTE CASA               ↗ +3  pts   Aggiornato x  │
//   │                                                              │
//   │   87           Ottima                                        │
//   │   ════         ──────────          2 stanze da controllare   │
//   │   Score        Stato               Badge attenzione          │
//   │                                                              │
//   │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░   barra progresso          │
//   └──────────────────────────────────────────────────────────────┘

struct EnvironmentHeroView: View {

    /// Score 0.0–1.0
    let score: Double
    let label: String
    let color: Color
    let lastRefresh: Date?
    /// Numero di stanze con almeno un sensore in warning o danger
    let attentionRoomCount: Int
    /// Trend rispetto alla rilevazione precedente (nil = nessun confronto disponibile)
    let trend: Double?

    @State private var animatedScore: Double = 0

    // Icona principale che varia con lo stato di salute
    private var heroIcon: String {
        switch score {
        case 0.85...1.0:  return "leaf.fill"
        case 0.60..<0.85: return "checkmark.circle.fill"
        case 0.35..<0.60: return "exclamationmark.triangle.fill"
        default:           return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Riga superiore: etichetta sezione + trend + timestamp ──
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: heroIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)

                Text("Salute Casa")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                // Trend indicatore (solo se disponibile)
                if let t = trend, abs(t) > 0.5 {
                    HStack(spacing: 3) {
                        Image(systemName: t > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(String(format: "%+.0f", t * 100))
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(t > 0 ? Color.green : Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (t > 0 ? Color.green : Color.orange).opacity(0.1),
                        in: Capsule()
                    )
                }

                // Timestamp
                if let refresh = lastRefresh {
                    Text(refresh, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Nessun dato")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // ── Riga centrale: score + label + badge attenzione ────────
            HStack(alignment: .bottom, spacing: 0) {

                // Score animato — numero grande, colore semantico
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(Int(animatedScore * 100))")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.opacity(0.65))
                        .padding(.bottom, 6)
                }

                Spacer()

                // Colonna destra: stato + badge stanze da controllare
                VStack(alignment: .trailing, spacing: 6) {
                    Text(label)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    if attentionRoomCount > 0 {
                        // Badge "N stanze da controllare"
                        HStack(spacing: 5) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text(attentionRoomCount == 1
                                 ? "1 stanza da controllare"
                                 : "\(attentionRoomCount) stanze da controllare")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(attentionRoomCount > 0 ? Color.orange : Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Color.orange.opacity(0.10),
                            in: Capsule()
                        )
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text("Tutto nella norma")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.10), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // ── Barra progresso full-width ─────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.12))
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.7), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * animatedScore), height: 5)
                        .animation(.spring(response: 1.0, dampingFraction: 0.75), value: animatedScore)
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
                    // Bordo colorato inferiore — firma visiva dello stato
                    Rectangle()
                        .fill(color.opacity(0.6))
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .shadow(color: color.opacity(0.12), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) {
                animatedScore = score
            }
        }
        .onChange(of: score) { _, v in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                animatedScore = v
            }
        }
    }
}

// MARK: - Preview

#Preview("Hero — vari stati") {
    ScrollView {
        VStack(spacing: 16) {
            EnvironmentHeroView(
                score: 0.87,
                label: "Ottima",
                color: .green,
                lastRefresh: Date().addingTimeInterval(-120),
                attentionRoomCount: 0,
                trend: 0.03
            )

            EnvironmentHeroView(
                score: 0.71,
                label: "Discreta",
                color: .yellow,
                lastRefresh: Date().addingTimeInterval(-300),
                attentionRoomCount: 1,
                trend: -0.02
            )

            EnvironmentHeroView(
                score: 0.48,
                label: "Attenzione",
                color: .orange,
                lastRefresh: Date().addingTimeInterval(-600),
                attentionRoomCount: 2,
                trend: nil
            )

            EnvironmentHeroView(
                score: 0.21,
                label: "Critica",
                color: .red,
                lastRefresh: nil,
                attentionRoomCount: 3,
                trend: -0.15
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
