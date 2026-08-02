import SwiftUI

struct FloorplanStatusMetric: Identifiable {
    let id = UUID()
    let value: String
    let label: String
}

struct FloorplanStatusSummaryCard: View {
    let title: String
    let message: String
    let icon: String
    let color: Color
    let metrics: [FloorplanStatusMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !metrics.isEmpty {
                HStack(spacing: 8) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.value)
                                .font(.headline.weight(.bold))
                                .monospacedDigit()
                            Text(metric.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(0.6))
                .frame(height: 3)
        }
        // È la card di riepilogo che TUTTI E TRE gli overlay mostrano in cima —
        // "Ambiente casa", "Sicurezza casa", "Priorità della casa". Vive in un
        // file suo, fuori dai tre overlay, ed è per questo che era sfuggita: chi
        // cercava le superfici dentro EnvironmentOverlayView, SecurityOverlayView
        // e IntelligenceOverlayView non poteva trovarla.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassChromeSurface(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            tint: color.opacity(0.12),
            legacyShadow: GlassChromeShadow(color: color.opacity(0.12), radius: 12, y: 4)
        )
    }
}

struct FloorplanEmptyStateCard: View {
    let title: String
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Stessa conversione della card qui sopra: bordo colorato disegnato a
        // mano sostituito dalla tinta, che sul vetro è il mezzo previsto.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassChromeSurface(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            tint: color.opacity(0.12),
            legacyBorder: color.opacity(0.16),
            legacyShadow: GlassChromeShadow(color: color.opacity(0.08), radius: 10, y: 3)
        )
    }
}
