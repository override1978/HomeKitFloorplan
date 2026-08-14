import SwiftUI

// MARK: - Componenti grafici della dashboard energia
//
// Un solo vocabolario visivo per monitor e analisi: barre con assi veri,
// profilo orario ad area, donut di ripartizione, tile di statistica e righe
// insight. Tutto Canvas/SwiftUI puro, tinte della famiglia energia (giallo).

// MARK: EnergyAxisBarChart

/// Barre con asse Y quotato e griglia: la differenza fra un poster e un
/// grafico che si legge. Tap opzionale sul periodo.
struct EnergyAxisBarChart: View {
    let values: [EnergyDayTotal]
    let height: CGFloat
    let unitLabel: String
    let xLabel: (Date) -> String
    var barColor: (EnergyDayTotal) -> Color = { _ in .yellow.opacity(0.8) }
    /// Serie di confronto affiancata (stesso ordine): la barra spenta accanto
    /// a quella accesa — «mese corrente vs precedente» del mockup.
    var secondaryValues: [Double]? = nil
    var onTap: ((Date) -> Void)?

    private var niceMaximum: Double {
        let raw = max(values.map(\.kilowattHours).max() ?? 0,
                      secondaryValues?.max() ?? 0)
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        for multiplier in [1.0, 2.0, 2.5, 5.0, 10.0] {
            let candidate = magnitude * multiplier
            if candidate >= raw { return candidate }
        }
        return raw
    }

    var body: some View {
        let maximum = niceMaximum
        HStack(alignment: .top, spacing: 6) {
            // Asse Y: massimo, metà, zero.
            VStack(alignment: .trailing) {
                Text(axisLabel(maximum))
                Spacer()
                Text(axisLabel(maximum / 2))
                Spacer()
                Text(axisLabel(0))
                Text(verbatim: "").frame(height: 10)
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(height: height)

            VStack(spacing: 2) {
                ZStack {
                    // Griglia orizzontale dietro le barre.
                    VStack {
                        gridline
                        Spacer()
                        gridline
                        Spacer()
                        gridline
                    }
                    HStack(alignment: .bottom, spacing: values.count > 24 ? 2 : 4) {
                        ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
                            HStack(alignment: .bottom, spacing: 1) {
                                if let secondary = secondaryValues?[safe: index], secondary > 0 {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color.primary.opacity(0.18))
                                        .frame(height: max(2, (height - 12) * CGFloat(secondary / maximum)))
                                        .frame(maxWidth: .infinity)
                                }
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(barColor(value))
                                    .frame(height: max(2, (height - 12) * CGFloat(value.kilowattHours / maximum)))
                                    .frame(maxWidth: .infinity)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onTap?(value.day) }
                        }
                    }
                    .frame(height: height - 12, alignment: .bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: height - 12)

                HStack(spacing: values.count > 24 ? 2 : 4) {
                    ForEach(values) { value in
                        Text(xLabel(value.day))
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                }
                .frame(height: 10)
            }
        }
    }

    private var gridline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    private func axisLabel(_ value: Double) -> String {
        let number = value >= 100
            ? value.formatted(.number.precision(.fractionLength(0)))
            : value.formatted(.number.precision(.fractionLength(0...1)))
        return "\(number) \(unitLabel)"
    }
}

// MARK: EnergyProfileChart

/// Il profilo delle 24 ore come area: la forma della giornata — notte piatta,
/// mattina che sale, la sera che concentra tutto.
struct EnergyProfileChart: View {
    /// 24 valori, kW medi per ora.
    let hourlyKilowatts: [Double]
    let height: CGFloat

    private var maximum: Double { max(hourlyKilowatts.max() ?? 0, 0.1) }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(axisLabel(maximum))
                    Spacer()
                    Text(axisLabel(maximum / 2))
                    Spacer()
                    Text(axisLabel(0))
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)

                Canvas { context, size in
                    guard hourlyKilowatts.count > 1 else { return }
                    let stepX = size.width / CGFloat(hourlyKilowatts.count - 1)
                    func point(_ index: Int) -> CGPoint {
                        CGPoint(x: CGFloat(index) * stepX,
                                y: size.height * (1 - CGFloat(hourlyKilowatts[index] / maximum)))
                    }

                    var line = Path()
                    line.move(to: point(0))
                    for index in 1..<hourlyKilowatts.count { line.addLine(to: point(index)) }

                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: 0, y: size.height))
                    area.closeSubpath()

                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [.yellow.opacity(0.45), .yellow.opacity(0.05)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                    context.stroke(line, with: .color(.yellow.opacity(0.9)), lineWidth: 1.6)
                }
            }
            .frame(height: height)

            HStack {
                Text(verbatim: "00:00")
                Spacer()
                Text(verbatim: "06:00")
                Spacer()
                Text(verbatim: "12:00")
                Spacer()
                Text(verbatim: "18:00")
                Spacer()
                Text(verbatim: "24:00")
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.leading, 34)
        }
    }

    private func axisLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) kW"
    }
}

// MARK: EnergyDonutChart

struct EnergyDonutSegment: Identifiable {
    let id = UUID()
    let label: String
    let kilowattHours: Double
    let color: Color
}

/// La ripartizione dei consumi ad anello, con la legenda a fianco.
struct EnergyDonutChart: View {
    let segments: [EnergyDonutSegment]
    var costText: (Double) -> String? = { _ in nil }

    private var total: Double { segments.map(\.kilowattHours).reduce(0, +) }

    var body: some View {
        HStack(spacing: 16) {
            Canvas { context, size in
                guard total > 0 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 8
                var start = Angle.degrees(-90)
                for segment in segments where segment.kilowattHours > 0 {
                    let sweep = Angle.degrees(segment.kilowattHours / total * 360)
                    var path = Path()
                    path.addArc(center: center, radius: radius,
                                startAngle: start, endAngle: start + sweep, clockwise: false)
                    context.stroke(path, with: .color(segment.color),
                                   style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    start += sweep
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(segment.label)
                                .font(.caption.weight(.semibold))
                            Text(EnergyFormat.kilowattHours(segment.kilowattHours))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if total > 0 {
                            Text((segment.kilowattHours / total)
                                .formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.weight(.bold).monospacedDigit())
                        }
                    }
                }
            }
        }
    }
}

// MARK: EnergyStatTile

/// Il riquadro-statistica: icona tinta, valore, contesto.
struct EnergyStatTile: View {
    let iconName: String
    let tint: Color
    let title: String
    let value: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

// MARK: EnergyInsightRow

struct EnergyInsightRow: View {
    let iconName: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
