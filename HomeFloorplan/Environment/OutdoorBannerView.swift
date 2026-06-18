import SwiftUI

// MARK: - OutdoorBannerView
//
// Hero card che mostra le condizioni meteo esterne usando WeatherKitService.
// Visibile solo quando currentWeather è disponibile (richiede posizione casa configurata).
// Mostra: condizione, temperatura, percepita, umidità, vento, UV, previsione domani.

struct OutdoorBannerView: View {

    @Environment(WeatherKitService.self) private var weatherKit

    var body: some View {
        if let weather = weatherKit.currentWeather {
            cardContent(weather)
        }
    }

    // MARK: - Card principale

    private func cardContent(_ w: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Riga 1: icona + temp + percepita ──────────────────────
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: w.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 40))
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f°", w.outdoorTemperature))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: String(localized: "outdoor.feelsLike",
                                               defaultValue: "Percepita %.0f°"),
                                w.apparentTemperature))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(localized: "outdoor.title", defaultValue: "Esterno"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let updated = weatherKit.lastUpdated {
                        Text(updated, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Riga 2: pillole humidity / vento / UV ─────────────────
            HStack(spacing: 10) {
                weatherPill(
                    String(format: "%.0f%%", w.outdoorHumidity * 100),
                    icon: "humidity.fill",
                    color: humidityColor(w.outdoorHumidity * 100)
                )
                weatherPill(
                    String(format: "%.0f km/h", w.windSpeedKmh),
                    icon: "wind",
                    color: .cyan
                )
                weatherPill(
                    "UV \(w.uvIndex)",
                    icon: "sun.max.fill",
                    color: uvColor(w.uvIndex)
                )
                Spacer()
            }

            // ── Riga 3: previsione domani ─────────────────────────────
            if let tmr = weatherKit.tomorrowForecast {
                Divider()
                HStack(spacing: 12) {
                    Label(String(localized: "outdoor.tomorrow", defaultValue: "Domani"),
                          systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(String(format: "%.0f° – %.0f°",
                                tmr.minTemperature, tmr.maxTemperature))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()

                    if tmr.precipitationProbability > 0.1 {
                        Label(String(format: "%.0f%%", tmr.precipitationProbability * 100),
                              systemImage: "drop.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    Image(systemName: tmrSymbol(tmr.condition))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    // MARK: - Pill helper

    @ViewBuilder
    private func weatherPill(_ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }

    // MARK: - Color helpers

    private func humidityColor(_ h: Double) -> Color {
        h >= 75 || h < 30 ? .orange : .blue
    }

    private func uvColor(_ uv: Int) -> Color {
        switch uv {
        case 0...2:  return .green
        case 3...5:  return .yellow
        case 6...7:  return .orange
        case 8...10: return .red
        default:     return .purple
        }
    }

    private func tmrSymbol(_ condition: String) -> String {
        switch condition {
        case let c where c.contains("rain") || c.contains("drizzle"): return "cloud.rain.fill"
        case let c where c.contains("snow"):                          return "cloud.snow.fill"
        case let c where c.contains("thunder"):                       return "cloud.bolt.rain.fill"
        case let c where c.contains("fog") || c.contains("haze"):    return "cloud.fog.fill"
        case let c where c.contains("cloud"):                         return "cloud.fill"
        case let c where c.contains("clear"):                         return "sun.max.fill"
        default:                                                       return "cloud.sun.fill"
        }
    }
}
