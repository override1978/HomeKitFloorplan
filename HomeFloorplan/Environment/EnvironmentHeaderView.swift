import SwiftUI

// MARK: - EnvironmentHeaderView
//
// Banner stile Apple Home: sfondo material, testo grande a sinistra, score a destra.
// Se ci sono sensori in anomalia, la mini barra viene sostituita da chip colorati
// (icona + valore) — impact visivo immediato senza dover scorrere le card.

struct EnvironmentHeaderView: View {

    let score: Double          // 0.0 – 1.0
    let label: String
    let color: Color
    let lastRefresh: Date?
    @State private var animatedScore: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {

            // MARK: Lato sinistro
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Text("Qualità Ambiente")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Text(label)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.interpolate)

                if let refresh = lastRefresh {
                    Text("Aggiornato \(refresh, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nessun dato ancora")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // MARK: Lato destro: numero + chip anomalie (o barra se tutto ok)
            VStack(alignment: .trailing, spacing: 8) {

                // Percentuale grande
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(Int(animatedScore * 100))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.opacity(0.7))
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.9)) { animatedScore = score }
                }
                .onChange(of: score) { _, v in
                    withAnimation(.easeOut(duration: 0.6)) { animatedScore = v }
                }

                // Mini barra progresso
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(color.opacity(0.12))
                            .frame(height: 5)
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * animatedScore, height: 5)
                            .animation(.easeOut(duration: 0.9), value: animatedScore)
                    }
                }
                .frame(width: 80, height: 5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 0)
                            .fill(color)
                            .frame(height: 3)
                            .clipShape(
                                .rect(
                                    bottomLeadingRadius: 20,
                                    bottomTrailingRadius: 20
                                )
                            )
                    }
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 14) {
        EnvironmentHeaderView(score: 0.93, label: "Ottima",     color: .green,  lastRefresh: Date())
        EnvironmentHeaderView(score: 0.71, label: "Discreta",   color: .yellow, lastRefresh: Date())
        EnvironmentHeaderView(score: 0.44, label: "Attenzione", color: .orange, lastRefresh: nil)
        EnvironmentHeaderView(score: 0.18, label: "Critica",    color: .red,    lastRefresh: Date())
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
