import SwiftUI
import SwiftData

// MARK: - OutdoorBannerView
//
// Banner compatto che mostra temperatura e umidità del modulo outdoor.
// La stanza da cercare è configurabile in Impostazioni → Ambiente → "Stanza esterna"
// (chiave AppStorage "outdoorRoomName", default "Outdoor Module").
// Il banner è nascosto automaticamente se il nome non è configurato o
// non esistono letture recenti (ultimi 3 h).

struct OutdoorBannerView: View {

    let modelContainer: ModelContainer
    /// Nome stanza outdoor, passato dall'esterno (letto da AppStorage nel parent).
    let roomName: String

    @State private var temp: Double?
    @State private var humidity: Double?
    @State private var lastUpdate: Date?

    var body: some View {
        Group {
            if !roomName.isEmpty, temp != nil || humidity != nil {
                bannerContent
            }
        }
        .onAppear { loadOutdoorReadings() }
        .onChange(of: roomName) { _, _ in loadOutdoorReadings() }
    }

    // MARK: - Banner UI

    private var bannerContent: some View {
        HStack(spacing: 0) {

            // Icona decorativa
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
            }
            .padding(.trailing, 12)

            // Label + timestamp
            VStack(alignment: .leading, spacing: 2) {
                Text("Esterno")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let date = lastUpdate {
                    Text("Agg. \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Pillole valori
            HStack(spacing: 14) {
                if let t = temp {
                    outdoorPill(
                        value: String(format: "%.1f°", t),
                        icon: "thermometer.medium",
                        color: temperatureColor(t)
                    )
                }
                if let h = humidity {
                    outdoorPill(
                        value: String(format: "%.0f%%", h),
                        icon: "humidity.fill",
                        color: humidityColor(h)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    @ViewBuilder
    private func outdoorPill(value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }

    // MARK: - Colori contestuali

    private func temperatureColor(_ t: Double) -> Color {
        if t >= 32 { return .red }
        if t >= 28 { return .orange }
        if t <= 5  { return .blue }
        return .green
    }

    private func humidityColor(_ h: Double) -> Color {
        if h >= 75 || h < 30 { return .orange }
        return .blue
    }

    // MARK: - Fetch SwiftData

    private func loadOutdoorReadings() {
        guard !roomName.isEmpty else {
            temp = nil; humidity = nil; lastUpdate = nil
            return
        }

        let context = ModelContext(modelContainer)
        let name = roomName
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let tempRaw = SensorServiceType.temperature.rawValue
        let humRaw  = SensorServiceType.humidity.rawValue

        let tempDescriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.roomName == name &&
                $0.serviceTypeRaw == tempRaw &&
                $0.timestamp > cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let humDescriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.roomName == name &&
                $0.serviceTypeRaw == humRaw &&
                $0.timestamp > cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        if let t = try? context.fetch(tempDescriptor).first {
            temp = t.value
            lastUpdate = t.timestamp
        } else {
            temp = nil
        }

        if let h = try? context.fetch(humDescriptor).first {
            humidity = h.value
            if let lu = lastUpdate {
                lastUpdate = max(lu, h.timestamp)
            } else {
                lastUpdate = h.timestamp
            }
        } else {
            humidity = nil
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
            }
            .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text("Esterno")
                    .font(.subheadline.weight(.semibold))
                Text("Agg. 5 min fa")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium").font(.system(size: 12)).foregroundStyle(.green)
                    Text("22.4°").font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.green.opacity(0.10), in: Capsule())

                HStack(spacing: 4) {
                    Image(systemName: "humidity.fill").font(.system(size: 12)).foregroundStyle(.blue)
                    Text("58%").font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.blue.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
