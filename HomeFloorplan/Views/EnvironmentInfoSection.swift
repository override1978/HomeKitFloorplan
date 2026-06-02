import SwiftUI

/// Sezione "Ambiente" con chip per qualità aria, PM2.5, temperatura,
/// umidità, luminosità. Si nasconde automaticamente se non c'è nulla da mostrare.
/// Le chip si dispongono in scroll orizzontale se troppe per stare in una riga.
struct EnvironmentInfoSection: View {
    var airQuality: String? = nil
    var pm25: Double? = nil
    var pm10: Double? = nil
    var temperatureC: Double? = nil
    var humidity: Double? = nil
    var lightLevel: Int? = nil
    var co2: Double? = nil
    var voc: Double? = nil
    
    private var hasContent: Bool {
        airQuality != nil
        || pm25 != nil
        || pm10 != nil
        || temperatureC != nil
        || humidity != nil
        || lightLevel != nil
        || co2 != nil
        || voc != nil
    }
    
    var body: some View {
        Group {
            if hasContent {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "environment.section.title", defaultValue: "Ambiente"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // ...tutto il contenuto chip identico a prima
                            if let aq = airQuality {
                                chip(symbol: "aqi.medium", value: aq)
                            }
                            if let pm25 {
                                chip(symbol: "smoke.fill", value: String(format: "PM2.5 %.0f", pm25), unit: "µg/m³")
                            }
                            if let pm10 {
                                chip(symbol: "smoke", value: String(format: "PM10 %.0f", pm10), unit: "µg/m³")
                            }
                            if let temperatureC {
                                chip(symbol: "thermometer", value: String(format: "%.0f°", temperatureC))
                            }
                            if let humidity {
                                chip(symbol: "humidity.fill", value: String(format: "%.0f%%", humidity))
                            }
                            if let lightLevel {
                                chip(symbol: "sun.max.fill", value: "\(lightLevel) lx")
                            }
                            if let co2 {
                                chip(symbol: "carbon.dioxide.cloud.fill", value: String(format: "CO₂ %.0f", co2), unit: "ppm")
                            }
                            if let voc {
                                chip(symbol: "wind", value: String(format: "VOC %.0f", voc), unit: "µg/m³")
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .onAppear {
                    dprint("🌱 EnvironmentInfoSection rendered with: airQ=\(airQuality ?? "nil") pm25=\(pm25.map(String.init(describing:)) ?? "nil") temp=\(temperatureC.map(String.init(describing:)) ?? "nil") hum=\(humidity.map(String.init(describing:)) ?? "nil")")
                }
            } else {
                EmptyView()
                    .onAppear {
                        dprint("🌱 EnvironmentInfoSection: hasContent=false, niente da mostrare")
                    }
            }
        }
    }
    
    private func chip(symbol: String, value: String, unit: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            if let unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}
