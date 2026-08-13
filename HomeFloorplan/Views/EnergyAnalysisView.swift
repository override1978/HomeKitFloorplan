import SwiftUI
import SwiftData

// MARK: - EnergyAnalysisView

/// Lo strumento di analisi dei consumi di casa, a tre livelli che si
/// attraversano col tocco:
///
///   **Anno** (12 mesi) → tap su un mese → **Mese** (i suoi giorni) → tap su
///   un giorno → **Giorno** (le sue ore, dove la granularità c'è).
///
/// Ogni livello ha le sue cifre — totale, costo, confronto col periodo
/// precedente in rosso/verde, media — e le frecce ‹ › per scorrere i periodi
/// senza risalire. I dati sono quelli del contatore generale (import Vimar,
/// domani un meter Matter): il livello ore vive solo dove l'import ha tenuto
/// la granularità oraria (ultimi 60 giorni), e dove non c'è lo dice.
struct EnergyAnalysisView: View {
    @AppStorage("energy.tariffPerKWh") private var tariffPerKWh = 0.0
    @Query private var houseSamples: [EnergySample]

    @State private var selectedMonth: Date?
    @State private var selectedDay: Date?

    init() {
        let houseID = EnergySample.houseMeterDeviceID
        _houseSamples = Query(
            filter: #Predicate<EnergySample> { $0.deviceID == houseID },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
    }

    private var calendar: Calendar { .current }

    private var housePoints: [EnergyStatsPoint] {
        houseSamples.map {
            EnergyStatsPoint(timestamp: $0.timestamp, cumulativeKilowattHours: $0.cumulativeKilowattHours)
        }
    }

    private var months: [EnergyDayTotal] {
        EnergyStatsBuilder.monthlyTotals(points: housePoints, months: 12)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let day = selectedDay, let month = selectedMonth {
                    dayLevel(day: day, month: month)
                } else if let month = selectedMonth {
                    monthLevel(month)
                } else {
                    yearLevel
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(String(localized: "energy.analysis.title", defaultValue: "Consumption analysis"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Livello anno

    private var yearLevel: some View {
        let total = months.map(\.kilowattHours).reduce(0, +)
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "energy.monthly.title", defaultValue: "Last 12 months"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(EnergyFormat.kilowattHours(total))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                if let cost = EnergyFormat.cost(total, tariffPerKWh: tariffPerKWh) {
                    Text(cost)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            barsChart(
                months,
                height: 120,
                label: { $0.formatted(.dateTime.month(.narrow)) },
                labelEvery: 1
            ) { month in
                withAnimation(.easeOut(duration: 0.2)) { selectedMonth = month }
            }

            Text(String(localized: "energy.analysis.hint.year",
                        defaultValue: "Tap a month to see its days."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Livello mese

    private func monthLevel(_ month: Date) -> some View {
        let days = monthDays(of: month)
        let total = monthTotal(month)
        let previous = calendar.date(byAdding: .month, value: -1, to: month)
        let previousTotal = previous.map(monthTotal) ?? 0
        let dayCount = elapsedDayCount(of: month)

        return VStack(alignment: .leading, spacing: 14) {
            periodHeader(
                title: month.formatted(.dateTime.month(.wide).year()),
                backTitle: String(localized: "energy.analysis.back.year", defaultValue: "12 months"),
                onBack: { withAnimation { selectedMonth = nil } },
                onPrevious: canMove(month: month, by: -1) ? { move(month: -1) } : nil,
                onNext: canMove(month: month, by: 1) ? { move(month: 1) } : nil
            )

            card {
                summaryRow(total: total, comparison: previousTotal > 0 ? total - previousTotal : nil,
                           comparisonLabel: previous?.formatted(.dateTime.month(.abbreviated)) ?? "")

                if dayCount > 0 {
                    Text(String(format: String(localized: "energy.month.avgPerDay", defaultValue: "%@ per day"),
                                EnergyFormat.kilowattHours(total / Double(dayCount))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                barsChart(
                    days,
                    height: 110,
                    label: { day in
                        let number = calendar.component(.day, from: day)
                        return number == 1 || number % 5 == 0 ? "\(number)" : ""
                    },
                    labelEvery: 1
                ) { day in
                    withAnimation(.easeOut(duration: 0.2)) { selectedDay = day }
                }

                Text(String(localized: "energy.analysis.hint.month",
                            defaultValue: "Tap a day to open it."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Livello giorno

    private func dayLevel(day: Date, month: Date) -> some View {
        let hours = EnergyStatsBuilder.hourlyTotals(points: housePoints, day: day, calendar: calendar)
        let total = dayTotal(day)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: day)
        let weekAgoTotal = weekAgo.map(dayTotal) ?? 0
        let monthAverage = monthDailyAverage(month)
        let hasHourly = hourlySampleCount(on: day) >= 6

        return VStack(alignment: .leading, spacing: 14) {
            periodHeader(
                title: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                backTitle: month.formatted(.dateTime.month(.wide)),
                onBack: { withAnimation { selectedDay = nil } },
                onPrevious: canMove(day: day, by: -1) ? { move(day: -1) } : nil,
                onNext: canMove(day: day, by: 1) ? { move(day: 1) } : nil
            )

            card {
                summaryRow(total: total, comparison: weekAgoTotal > 0 ? total - weekAgoTotal : nil,
                           comparisonLabel: String(localized: "energy.analysis.sevenDaysAgo", defaultValue: "7 days ago"))

                if monthAverage > 0 {
                    let delta = total - monthAverage
                    Label {
                        Text(verbatim: "\(delta > 0 ? "+" : "−")\(EnergyFormat.kilowattHours(abs(delta))) \(String(localized: "energy.analysis.vsMonthAverage", defaultValue: "vs month average"))")
                    } icon: {
                        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    .font(.caption)
                    .foregroundStyle(delta > 0 ? Color(.systemRed) : Color(.systemGreen))
                }

                if hasHourly {
                    barsChart(
                        hours,
                        height: 110,
                        label: { hour in
                            let value = calendar.component(.hour, from: hour)
                            return value % 6 == 0 ? "\(value)" : ""
                        },
                        labelEvery: 1
                    ) { _ in }
                } else {
                    // Onestà sul limite: le ore esistono solo dove l'import le
                    // ha tenute. Il totale del giorno resta vero comunque.
                    Label(String(localized: "energy.analysis.noHourly",
                                 defaultValue: "Hourly detail is kept for the last 60 days — re-import a fresh export to fill recent days."),
                          systemImage: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Componenti

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func periodHeader(
        title: String,
        backTitle: String,
        onBack: @escaping () -> Void,
        onPrevious: (() -> Void)?,
        onNext: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label(backTitle, systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 8)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button { onPrevious?() } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(onPrevious == nil)

                Button { onNext?() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(onNext == nil)
            }
        }
    }

    private func summaryRow(total: Double, comparison: Double?, comparisonLabel: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(EnergyFormat.kilowattHours(total))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let cost = EnergyFormat.cost(total, tariffPerKWh: tariffPerKWh) {
                Text(cost)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let comparison {
                let rising = comparison > 0
                Label {
                    Text(verbatim: "\(rising ? "+" : "−")\(EnergyFormat.kilowattHours(abs(comparison))) \(String(localized: "energy.month.vs", defaultValue: "vs")) \(comparisonLabel)")
                } icon: {
                    Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(rising ? Color(.systemRed) : Color(.systemGreen))
            }
        }
    }

    /// Le barre toccabili, uguali a tutti i livelli: valore massimo in
    /// evidenza, etichette rade dove serve, tap sul periodo.
    private func barsChart(
        _ values: [EnergyDayTotal],
        height: CGFloat,
        label: @escaping (Date) -> String,
        labelEvery: Int,
        onTap: @escaping (Date) -> Void
    ) -> some View {
        let maximum = max(values.map(\.kilowattHours).max() ?? 0, 0.0001)
        return HStack(alignment: .bottom, spacing: values.count > 24 ? 2 : 4) {
            ForEach(values) { value in
                let barHeight = max(2, (height - 16) * CGFloat(value.kilowattHours / maximum))
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.yellow.opacity(value.kilowattHours > 0 ? 0.75 : 0.2))
                        .frame(height: barHeight)
                        .frame(maxWidth: .infinity)
                    Text(label(value.day))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 9)
                }
                .frame(height: height, alignment: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { onTap(value.day) }
            }
        }
    }

    // MARK: - Dati dei periodi

    private func monthTotal(_ month: Date) -> Double {
        months.first(where: { $0.day == month })?.kilowattHours
            ?? monthDays(of: month).map(\.kilowattHours).reduce(0, +)
    }

    private func monthDays(of month: Date) -> [EnergyDayTotal] {
        let count = elapsedDayCount(of: month)
        guard count > 0 else { return [] }
        let reference: Date
        if calendar.isDate(.now, equalTo: month, toGranularity: .month) {
            reference = .now
        } else {
            reference = calendar.date(byAdding: .day, value: count - 1, to: month) ?? month
        }
        return EnergyStatsBuilder.dailyTotals(points: housePoints, days: count, reference: reference, calendar: calendar)
    }

    private func elapsedDayCount(of month: Date) -> Int {
        if calendar.isDate(.now, equalTo: month, toGranularity: .month) {
            return calendar.component(.day, from: .now)
        }
        return calendar.range(of: .day, in: .month, for: month)?.count ?? 0
    }

    private func monthDailyAverage(_ month: Date) -> Double {
        let count = elapsedDayCount(of: month)
        guard count > 0 else { return 0 }
        return monthTotal(month) / Double(count)
    }

    private func dayTotal(_ day: Date) -> Double {
        EnergyStatsBuilder.dailyTotals(points: housePoints, days: 1, reference: day, calendar: calendar)
            .first?.kilowattHours ?? 0
    }

    private func hourlySampleCount(on day: Date) -> Int {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return houseSamples.filter { $0.timestamp >= start && $0.timestamp < end }.count
    }

    // MARK: - Navigazione fra periodi

    private func canMove(month: Date, by value: Int) -> Bool {
        guard let target = calendar.date(byAdding: .month, value: value, to: month) else { return false }
        return months.contains { $0.day == target }
    }

    private func move(month value: Int) {
        guard let current = selectedMonth,
              let target = calendar.date(byAdding: .month, value: value, to: current) else { return }
        withAnimation(.easeOut(duration: 0.2)) { selectedMonth = target }
    }

    private func canMove(day: Date, by value: Int) -> Bool {
        guard let target = calendar.date(byAdding: .day, value: value, to: day),
              let month = selectedMonth else { return false }
        return calendar.isDate(target, equalTo: month, toGranularity: .month)
            && target <= .now
    }

    private func move(day value: Int) {
        guard let current = selectedDay,
              let target = calendar.date(byAdding: .day, value: value, to: current) else { return }
        withAnimation(.easeOut(duration: 0.2)) { selectedDay = target }
    }
}
