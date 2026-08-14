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
    /// Le prese misurate, per la ripartizione: storia breve, righe poche.
    @Query private var plugSamples: [EnergySample]

    @State private var selectedMonth: Date?
    @State private var selectedDay: Date?

    init() {
        let houseID = EnergySample.houseMeterDeviceID
        _houseSamples = Query(
            filter: #Predicate<EnergySample> { $0.deviceID == houseID },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
        _plugSamples = Query(
            filter: #Predicate<EnergySample> { $0.deviceID != houseID },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
    }

    private var calendar: Calendar { .current }

    private var housePoints: [EnergyStatsPoint] {
        houseSamples.map {
            EnergyStatsPoint(timestamp: $0.timestamp, cumulativeKilowattHours: $0.cumulativeKilowattHours)
        }
    }

    /// 14 mesi di finestra: i 12 mostrati più il margine per «stesso mese
    /// dell'anno scorso» quando l'export arriva così indietro.
    private var allMonths: [EnergyDayTotal] {
        EnergyStatsBuilder.monthlyTotals(points: housePoints, months: 14)
    }

    private var months: [EnergyDayTotal] {
        Array(allMonths.suffix(12))
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

            EnergyAxisBarChart(
                values: months,
                height: 130,
                unitLabel: "kWh",
                xLabel: { $0.formatted(.dateTime.month(.narrow)) }
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
        let peak = EnergyInsights.peakDay(days: days)

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

                HStack(spacing: 14) {
                    if dayCount > 0 {
                        Text(String(format: String(localized: "energy.month.avgPerDay", defaultValue: "%@ per day"),
                                    EnergyFormat.kilowattHours(total / Double(dayCount))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let peak {
                        Text(String(format: String(localized: "energy.analysis.peakDay", defaultValue: "Peak: %1$@ · %2$@"),
                                    EnergyFormat.kilowattHours(peak.kilowattHours),
                                    peak.day.formatted(.dateTime.day().month(.abbreviated))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                EnergyAxisBarChart(
                    values: days,
                    height: 120,
                    unitLabel: "kWh",
                    xLabel: { day in
                        let number = calendar.component(.day, from: day)
                        return number == 1 || number % 5 == 0 ? "\(number)" : ""
                    }
                ) { day in
                    withAnimation(.easeOut(duration: 0.2)) { selectedDay = day }
                }

                Text(String(localized: "energy.analysis.hint.month",
                            defaultValue: "Tap a day to open it."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            monthComparisonTiles(month: month, total: total)

            if let profile = monthProfile(month) {
                card {
                    Text(String(localized: "energy.analysis.avgProfile", defaultValue: "Average time-of-day profile"))
                        .font(.subheadline.weight(.semibold))
                    EnergyProfileChart(hourlyKilowatts: profile, height: 86)
                }
            }

            if let breakdown = monthBreakdown(month: month, total: total) {
                card {
                    Text(String(localized: "energy.analysis.breakdown", defaultValue: "Consumption breakdown"))
                        .font(.subheadline.weight(.semibold))
                    EnergyDonutChart(segments: breakdown)
                }
            }

            monthInsightsCard(month: month, days: days)
        }
    }

    /// I tre confronti del mese: precedente, media 3 mesi, stesso mese di un
    /// anno fa — ciascuno solo se il riferimento esiste davvero.
    private func monthComparisonTiles(month: Date, total: Double) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
            if let previous = calendar.date(byAdding: .month, value: -1, to: month) {
                comparisonTile(total: total, reference: monthTotal(previous),
                               title: String(localized: "energy.analysis.vsPrevious", defaultValue: "Vs previous month"))
            }
            let lastThree = (1...3).compactMap { offset -> Double? in
                guard let target = calendar.date(byAdding: .month, value: -offset, to: month) else { return nil }
                let value = monthTotal(target)
                return value > 0 ? value : nil
            }
            if lastThree.count == 3 {
                comparisonTile(total: total, reference: lastThree.reduce(0, +) / 3,
                               title: String(localized: "energy.analysis.vs3Months", defaultValue: "Vs 3-month average"))
            }
            if let yearAgo = calendar.date(byAdding: .month, value: -12, to: month) {
                comparisonTile(total: total, reference: monthTotal(yearAgo),
                               title: String(format: String(localized: "energy.analysis.vsYearAgo", defaultValue: "Vs %@"),
                                             yearAgo.formatted(.dateTime.month(.abbreviated).year())))
            }
        }
    }

    @ViewBuilder
    private func comparisonTile(total: Double, reference: Double, title: String) -> some View {
        if reference > 0, let percent = EnergyInsights.percentChange(total, versus: reference) {
            let rising = percent > 0
            EnergyStatTile(
                iconName: rising ? "arrow.up.right" : "arrow.down.right",
                tint: rising ? Color(.systemRed) : Color(.systemGreen),
                title: title,
                value: "\(rising ? "+" : "−")\(abs(percent).formatted(.number.precision(.fractionLength(1))))%",
                subtitle: "\(rising ? "+" : "−")\(EnergyFormat.kilowattHours(abs(total - reference)))"
            )
        }
    }

    /// Il profilo medio delle ore sui giorni del mese coperti dalla
    /// granularità oraria. nil dove le ore non ci sono.
    private func monthProfile(_ month: Date) -> [Double]? {
        let count = elapsedDayCount(of: month)
        guard count > 0 else { return nil }
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        return EnergyInsights.averageDayProfile(points: housePoints, days: days, calendar: calendar)
    }

    /// Prese misurate, standby stimato e resto casa: la torta del mese.
    private func monthBreakdown(month: Date, total: Double) -> [EnergyDonutSegment]? {
        guard total > 0 else { return nil }
        let count = elapsedDayCount(of: month)
        guard count > 0 else { return nil }
        let reference = calendar.isDate(.now, equalTo: month, toGranularity: .month)
            ? Date.now
            : (calendar.date(byAdding: .day, value: count - 1, to: month) ?? month)

        // Le prese: la somma dei giornalieri di ogni device nel mese.
        let plugsTotal = Dictionary(grouping: plugSamples, by: \.deviceID).values
            .map { rows -> Double in
                let points = rows.map { EnergyStatsPoint(timestamp: $0.timestamp,
                                                          cumulativeKilowattHours: $0.cumulativeKilowattHours) }
                return EnergyStatsBuilder.dailyTotals(points: points, days: count,
                                                      reference: reference, calendar: calendar)
                    .map(\.kilowattHours).reduce(0, +)
            }
            .reduce(0, +)

        // Lo standby: la base notturna proiettata sulle 24 ore. È una STIMA
        // e la legenda lo dice.
        let standby = EnergyInsights.nightBaseWatts(points: housePoints, calendar: calendar)
            .map { $0 / 1_000 * 24 * Double(count) } ?? 0

        let measured = min(plugsTotal, total)
        let estimatedStandby = min(standby, max(0, total - measured))
        let rest = max(0, total - measured - estimatedStandby)
        guard measured > 0 || estimatedStandby > 0 else { return nil }

        var segments: [EnergyDonutSegment] = []
        segments.append(EnergyDonutSegment(
            label: String(localized: "energy.analysis.segment.rest", defaultValue: "House (rest)"),
            kilowattHours: rest, color: .yellow))
        if measured > 0 {
            segments.append(EnergyDonutSegment(
                label: String(localized: "energy.analysis.segment.plugs", defaultValue: "Measured outlets"),
                kilowattHours: measured, color: .orange))
        }
        if estimatedStandby > 0 {
            segments.append(EnergyDonutSegment(
                label: String(localized: "energy.analysis.segment.standby", defaultValue: "Standby (estimated)"),
                kilowattHours: estimatedStandby, color: .purple))
        }
        return segments
    }

    /// Giorni critici e fasce del mese, solo dove i numeri reggono.
    @ViewBuilder
    private func monthInsightsCard(month: Date, days: [EnergyDayTotal]) -> some View {
        let rows = monthInsightRows(month: month, days: days)
        if !rows.isEmpty {
            card {
                Text(String(localized: "energy.analysis.insights", defaultValue: "Critical days and insights"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    EnergyInsightRow(iconName: row.icon, tint: row.tint, text: row.text)
                }
            }
        }
    }

    private func monthInsightRows(month: Date, days: [EnergyDayTotal]) -> [(icon: String, tint: Color, text: String)] {
        var rows: [(String, Color, String)] = []

        if let stretch = EnergyInsights.criticalStretch(days: days) {
            rows.append(("chart.line.uptrend.xyaxis", Color(.systemRed), String(
                format: String(localized: "energy.analysis.insight.stretch",
                               defaultValue: "Between %1$@ and %2$@ consumption ran %3$@%% above the month's average."),
                stretch.start.formatted(.dateTime.day().month(.abbreviated)),
                stretch.end.formatted(.dateTime.day().month(.abbreviated)),
                abs(stretch.upliftPercent).formatted(.number.precision(.fractionLength(0)))
            )))
        }

        // La fascia serale, mediata sui giorni con forma oraria.
        let count = elapsedDayCount(of: month)
        let monthDayDates = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        var shares: [Double] = []
        for day in monthDayDates {
            let hours = EnergyStatsBuilder.hourlyTotals(points: housePoints, day: day, calendar: calendar)
            if hours.filter({ $0.kilowattHours > 0 }).count >= 12,
               let share = EnergyInsights.bandShare(hours: hours, from: 19, to: 22, calendar: calendar) {
                shares.append(share)
            }
        }
        if shares.count >= 3 {
            let average = shares.reduce(0, +) / Double(shares.count)
            rows.append(("clock.fill", .orange, String(
                format: String(localized: "energy.analysis.insight.band",
                               defaultValue: "The 19:00–22:00 band concentrates %@ of daily consumption."),
                average.formatted(.percent.precision(.fractionLength(0)))
            )))
        }

        if let nightBase = EnergyInsights.nightBaseWatts(points: housePoints, calendar: calendar) {
            rows.append(("moon.fill", .indigo, String(
                format: String(localized: "energy.analysis.insight.nightBase",
                               defaultValue: "Estimated night base: %@ constant."),
                EnergyFormat.watts(nightBase)
            )))
        }

        return rows
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
                    EnergyAxisBarChart(
                        values: hours,
                        height: 110,
                        unitLabel: "kWh",
                        xLabel: { hour in
                            let value = calendar.component(.hour, from: hour)
                            return value % 6 == 0 ? "\(value)" : ""
                        }
                    )
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
