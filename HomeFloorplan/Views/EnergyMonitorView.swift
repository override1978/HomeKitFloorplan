import SwiftUI
import SwiftData
import HomeKit
import UniformTypeIdentifiers

// MARK: - EnergyMonitorView

/// Il monitoring dei consumi: cosa tira adesso, cosa è costato oggi, come è
/// andata la settimana — per ogni presa misurata, raggruppate per stanza.
///
/// I numeri live arrivano da `MatterEnergyLiveStore` (che ad ogni lettura
/// alimenta anche lo storico, via `onSnapshotsRead`); i giornalieri escono da
/// `EnergyStatsBuilder` sulle righe `EnergySample`. I costi compaiono solo se
/// la tariffa è impostata nelle Impostazioni: meglio nessun numero che un
/// numero inventato.
struct EnergyMonitorView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(MatterEnergyLiveStore.self) private var matterEnergy
    @AppStorage("energy.tariffPerKWh") private var tariffPerKWh = 0.0
    @Environment(\.modelContext) private var modelContext
    @Query private var samples: [EnergySample]
    /// Lo storico del contatore generale, TUTTO: sono ~2 campioni al giorno
    /// (l'import sottocampiona), un anno intero pesa meno di una settimana
    /// di prese.
    @Query private var houseSamples: [EnergySample]
    /// Tutte le righe delle prese misurate, per la ripartizione del mese:
    /// stessa scelta dell'analisi — storia breve, righe poche.
    @Query private var allPlugSamples: [EnergySample]
    @State private var isImporterPresented = false
    @State private var importMessage: String?
    /// Il mese mostrato nella card Trend (nil = l'ultimo).
    @State private var trendMonth: Date?
    /// Il drill-down verso l'analisi già puntata (mese o giorno preciso).
    @State private var analysisDestination: EnergyAnalysisDestination?
    /// Il giorno scelto dal drill-down del Trend: riempie la card
    /// «Distribuzione giornata» qui accanto, senza cambiare vista.
    @State private var selectedTrendDay: Date?
    /// Esito dell'auto-import Vimar, mostrato come toast solo se ha
    /// portato righe nuove.
    @State private var autoImportToast: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let windowDays = 7

    init() {
        // La finestra della vista: un giorno in più dei 7 mostrati, così i
        // delta a cavallo del primo giorno hanno il loro punto di partenza.
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.windowDays + 1),
            to: Calendar.current.startOfDay(for: .now)
        ) ?? .distantPast
        _samples = Query(
            filter: #Predicate<EnergySample> { $0.timestamp >= cutoff },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
        let houseID = EnergySample.houseMeterDeviceID
        _houseSamples = Query(
            filter: #Predicate<EnergySample> { $0.deviceID == houseID },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
        _allPlugSamples = Query(
            filter: #Predicate<EnergySample> { $0.deviceID != houseID },
            sort: [SortDescriptor(\EnergySample.timestamp)]
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if devices.isEmpty && houseSamples.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle(String(localized: "energy.title", defaultValue: "Energy"))
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label(String(localized: "energy.import.button", defaultValue: "Import meter export"),
                              systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationDestination(item: $analysisDestination) { destination in
                EnergyAnalysisView(initialMonth: destination.month, initialDay: destination.day)
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data]
            ) { result in
                handleImport(result)
            }
            .overlay(alignment: .bottom) {
                if let toast = autoImportToast {
                    Label(toast, systemImage: "checkmark.icloud.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: autoImportToast)
            .alert(String(localized: "energy.import.title", defaultValue: "Meter import"),
                   isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                   ),
                   presenting: importMessage) { _ in
                Button("OK") { importMessage = nil }
            } message: { message in
                Text(message)
            }
        }
        .task {
            await refreshLive()
            await autoImportVimarIfNeeded()
        }
        .refreshable { await refreshLive(force: true) }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let url):
            // Il file vive su iCloud Drive: fuori dal nostro container serve
            // l'accesso security-scoped, e va rilasciato comunque vada.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let outcome = try HouseMeterImport.importArchive(data, modelContainer: modelContext.container)
                // Il primo import manuale arma l'aggiornamento automatico:
                // da ora Energia controlla da sola se l'export è cambiato.
                VimarAutoImport.rememberFile(at: url)
                importMessage = String(
                    format: String(localized: "energy.import.result",
                                   defaultValue: "%1$d new days imported, %2$d already present."),
                    outcome.inserted, outcome.skipped
                )
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Hero e card della sezione Casa

    /// L'hero del contatore, a tre zone: oggi + potenza live, costi con la
    /// proiezione di fine mese, la settimana in barrette. Su spazi stretti
    /// le zone si impilano da sole.
    private var houseHeroCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                heroTodayColumn
                Divider()
                heroCostColumn
                Divider()
                heroWeekColumn.frame(maxWidth: 220)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    heroTodayColumn
                    Divider()
                    heroCostColumn
                }
                heroWeekColumn
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var heroTodayColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "energy.total.today", defaultValue: "Today"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(EnergyFormat.kilowattHours(houseTodayKilowattHours))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let watts = totalWattsNow {
                Label(EnergyFormat.watts(watts), systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroCostColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "energy.hero.costToday", defaultValue: "Estimated cost today"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedCost(houseTodayKilowattHours) ?? "—")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            if let projection = monthEndProjection {
                Text(String(localized: "energy.hero.projection", defaultValue: "Month-end projection"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                HStack(spacing: 6) {
                    Text(EnergyFormat.kilowattHours(projection))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if let cost = formattedCost(projection) {
                        Text(verbatim: "· \(cost)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroWeekColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(houseDays) { day in
                    let maximum = max(houseDays.map(\.kilowattHours).max() ?? 0, 0.0001)
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.yellow.opacity(day.id == houseDays.last?.id ? 0.95 : 0.5))
                            .frame(height: max(3, 40 * CGFloat(day.kilowattHours / maximum)))
                            .frame(maxWidth: .infinity)
                        Text(day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 52, alignment: .bottom)
                }
            }
            Text(String(localized: "energy.hero.source", defaultValue: "house data from Vimar"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// I quattro riquadri: ieri, trend 30 giorni, base notturna, picco.
    /// Su iPad si dividono TUTTA la larghezza (niente buco a destra);
    /// su iPhone si impilano a griglia.
    private var statTilesGrid: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 10) { statTiles }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                    statTiles
                }
            }
        }
    }

    @ViewBuilder
    private var statTiles: some View {
        Group {
            if houseYesterdayKilowattHours > 0 {
                let delta = houseTodayKilowattHours - houseYesterdayKilowattHours
                let percent = EnergyInsights.percentChange(houseTodayKilowattHours,
                                                           versus: houseYesterdayKilowattHours)
                EnergyStatTile(
                    iconName: delta > 0 ? "arrow.up.right" : "arrow.down.right",
                    tint: delta > 0 ? Color(.systemRed) : Color(.systemGreen),
                    title: String(localized: "energy.tile.vsYesterday", defaultValue: "Vs yesterday"),
                    value: "\(delta > 0 ? "+" : "−")\(EnergyFormat.kilowattHours(abs(delta)))",
                    subtitle: percent.map { "\($0 > 0 ? "+" : "−")\(abs($0).formatted(.number.precision(.fractionLength(0))))%" }
                )
            }
            if let trend = thirtyDayTrendPercent {
                EnergyStatTile(
                    iconName: trend > 0 ? "arrow.up.right" : "arrow.down.right",
                    tint: trend > 0 ? Color(.systemRed) : Color(.systemGreen),
                    title: String(localized: "energy.tile.avg30", defaultValue: "30-day average"),
                    value: "\(trend > 0 ? "+" : "−")\(abs(trend).formatted(.number.precision(.fractionLength(0))))%",
                    subtitle: String(localized: "energy.tile.avg30.subtitle", defaultValue: "vs previous 30 days")
                )
            }
            if let nightBase = nightBaseWatts {
                EnergyStatTile(
                    iconName: "moon.fill",
                    tint: .indigo,
                    title: String(localized: "energy.tile.nightBase", defaultValue: "Night base"),
                    value: EnergyFormat.watts(nightBase),
                    subtitle: String(localized: "energy.tile.nightBase.subtitle", defaultValue: "average 01:00–05:00")
                )
            }
            if let peak = latestPeak {
                EnergyStatTile(
                    iconName: "flame.fill",
                    tint: .orange,
                    title: String(format: String(localized: "energy.tile.peak", defaultValue: "Peak %@"), peak.dayLabel),
                    value: "\(peak.kilowatts.formatted(.number.precision(.fractionLength(1)))) kW",
                    subtitle: String(format: String(localized: "energy.tile.peakAt", defaultValue: "at %@"), peak.hourLabel)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// La forma di una giornata, ore per ore. Due modi: di default l'ultimo
    /// giorno con granularità oraria; col drill-down del Trend, il giorno
    /// scelto — con totale, costo, confronto e la ✕ per tornare. La card c'è
    /// SEMPRE: senza ore spiega come ottenerle invece di sparire.
    private var dayProfileCard: some View {
        let explicitDay = selectedTrendDay
        let day = explicitDay ?? latestHourlyDay
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if explicitDay != nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.yellow)
                        .frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(explicitDay != nil
                         ? (day?.formatted(.dateTime.weekday(.wide).day().month()) ?? "")
                         : String(localized: "energy.card.dayProfile", defaultValue: "Day distribution"))
                        .font(.subheadline.weight(.semibold))
                    if explicitDay != nil {
                        Text(String(localized: "energy.dayCard.fromTrend", defaultValue: "Day selected in Trends"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if explicitDay == nil, let profile = latestDayProfile {
                    Text(profile.day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let explicitDay {
                    Button {
                        analysisDestination = EnergyAnalysisDestination(
                            month: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: explicitDay)) ?? explicitDay,
                            day: explicitDay
                        )
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { selectedTrendDay = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let day {
                if let explicitDay {
                    let total = trendDayTotal(explicitDay)
                    let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: explicitDay).map(trendDayTotal) ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(EnergyFormat.kilowattHours(total))
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        if let cost = formattedCost(total) {
                            Text(cost)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if weekAgo > 0 {
                            let delta = total - weekAgo
                            Label {
                                Text(verbatim: "\(delta > 0 ? "+" : "−")\(EnergyFormat.kilowattHours(abs(delta))) \(String(localized: "energy.month.vs", defaultValue: "vs")) \(String(localized: "energy.analysis.sevenDaysAgo", defaultValue: "7 days ago"))")
                            } icon: {
                                Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta > 0 ? Color(.systemRed) : Color(.systemGreen))
                        }
                    }
                }

                let hours = EnergyStatsBuilder.hourlyTotals(points: housePoints, day: day)
                if hours.filter({ $0.kilowattHours > 0 }).count >= 6 {
                    EnergyAxisBarChart(
                        values: hours,
                        height: 120,
                        unitLabel: "kW",
                        xLabel: { hour in
                            let value = Calendar.current.component(.hour, from: hour)
                            return value % 6 == 0 ? String(format: "%02d", value) : ""
                        }
                    )
                } else {
                    Label(String(localized: "energy.analysis.noHourly",
                                 defaultValue: "Hourly detail is kept for the last 60 days — re-import a fresh export to fill recent days."),
                          systemImage: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                }
            } else {
                Label(String(localized: "energy.analysis.noHourly",
                             defaultValue: "Hourly detail is kept for the last 60 days — re-import a fresh export to fill recent days."),
                      systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selectedTrendDay != nil ? Color.yellow.opacity(0.35) : Color.primary.opacity(0.08),
                              lineWidth: 1)
        }
    }

    private func trendDayTotal(_ day: Date) -> Double {
        EnergyStatsBuilder.dailyTotals(points: housePoints, days: 1, reference: day)
            .first?.kilowattHours ?? 0
    }

    /// La classifica del giorno fra i device misurati.
    @ViewBuilder
    private var topConsumersCard: some View {
        let ranked = devices
            .filter { $0.todayKilowattHours > 0 }
            .sorted { $0.todayKilowattHours > $1.todayKilowattHours }
            .prefix(4)
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "energy.card.topConsumers", defaultValue: "Top consumers today"))
                    .font(.subheadline.weight(.semibold))
                let maximum = ranked.first?.todayKilowattHours ?? 1
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(device.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(device.roomName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(EnergyFormat.kilowattHours(device.todayKilowattHours))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                if let watts = device.liveWatts {
                                    Text(EnergyFormat.watts(watts))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.yellow.opacity(0.75))
                                    .frame(width: max(3, proxy.size.width * device.todayKilowattHours / maximum))
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    /// «Ripartizione consumi» del mese selezionato nel Trend: prese
    /// misurate, standby stimato e resto casa — la stessa torta
    /// dell'analisi, portata in dashboard come nel mockup.
    @ViewBuilder
    private var trendBreakdownCard: some View {
        let months = houseMonths
        if let month = trendMonth ?? months.last?.day,
           let total = months.first(where: { $0.day == month })?.kilowattHours,
           let segments = trendMonthBreakdown(month: month, total: total) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(localized: "energy.analysis.breakdown", defaultValue: "Consumption breakdown"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                EnergyDonutChart(segments: segments)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func trendMonthBreakdown(month: Date, total: Double) -> [EnergyDonutSegment]? {
        guard total > 0 else { return nil }
        let calendar = Calendar.current
        let count: Int
        let reference: Date
        if calendar.isDate(.now, equalTo: month, toGranularity: .month) {
            count = calendar.component(.day, from: .now)
            reference = .now
        } else {
            count = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
            reference = calendar.date(byAdding: .day, value: max(0, count - 1), to: month) ?? month
        }
        guard count > 0 else { return nil }

        let plugsTotal = Dictionary(grouping: allPlugSamples, by: \.deviceID).values
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

    /// Gli insight del giorno, solo dove i numeri reggono.
    @ViewBuilder
    private var insightsCard: some View {
        let rows = insightRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "energy.card.insights", defaultValue: "Insights"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    EnergyInsightRow(iconName: row.icon, tint: row.tint, text: row.text)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    // MARK: Calcoli della sezione Casa

    private var monthEndProjection: Double? {
        let calendar = Calendar.current
        let dayOfMonth = calendar.component(.day, from: .now)
        guard let daysInMonth = calendar.range(of: .day, in: .month, for: .now)?.count else { return nil }
        let monthDays = EnergyStatsBuilder.dailyTotals(points: housePoints, days: dayOfMonth, reference: .now)
        return EnergyInsights.monthEndProjection(
            monthToDate: monthDays.map(\.kilowattHours).reduce(0, +),
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth
        )
    }

    private var thirtyDayTrendPercent: Double? {
        let days = EnergyStatsBuilder.dailyTotals(points: housePoints, days: 60)
        let recent = days.suffix(30).map(\.kilowattHours).filter { $0 > 0 }
        let previous = days.prefix(30).map(\.kilowattHours).filter { $0 > 0 }
        guard recent.count >= 15, previous.count >= 15 else { return nil }
        return EnergyInsights.percentChange(
            recent.reduce(0, +) / Double(recent.count),
            versus: previous.reduce(0, +) / Double(previous.count)
        )
    }

    private var nightBaseWatts: Double? {
        EnergyInsights.nightBaseWatts(points: housePoints)
    }

    /// L'ultimo giorno con forma oraria (oggi o indietro fino a 7 giorni).
    private var latestHourlyDay: Date? {
        let calendar = Calendar.current
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let count = houseSamples.filter { $0.timestamp >= start && $0.timestamp < end }.count
            if count >= 12 { return start }
        }
        return nil
    }

    private struct PeakInfo {
        let kilowatts: Double
        let dayLabel: String
        let hourLabel: String
    }

    private var latestPeak: PeakInfo? {
        guard let day = latestHourlyDay else { return nil }
        let hours = EnergyStatsBuilder.hourlyTotals(points: housePoints, day: day)
        guard let peak = EnergyInsights.peakHour(hours: hours) else { return nil }
        let calendar = Calendar.current
        let dayLabel = calendar.isDateInToday(day)
            ? String(localized: "energy.day.today", defaultValue: "Today").lowercased()
            : (calendar.isDateInYesterday(day)
               ? String(localized: "energy.day.yesterday", defaultValue: "Yesterday").lowercased()
               : day.formatted(.dateTime.day().month(.abbreviated)))
        return PeakInfo(
            kilowatts: peak.kilowatts,
            dayLabel: dayLabel,
            hourLabel: peak.hour.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        )
    }

    private var latestDayProfile: (day: Date, kilowatts: [Double])? {
        guard let day = latestHourlyDay else { return nil }
        let hours = EnergyStatsBuilder.hourlyTotals(points: housePoints, day: day)
        return (day, hours.map(\.kilowattHours))
    }

    private var insightRows: [(icon: String, tint: Color, text: String)] {
        var rows: [(String, Color, String)] = []

        if let nightBase = nightBaseWatts {
            rows.append(("moon.fill", .indigo, String(
                format: String(localized: "energy.insight.nightBase",
                               defaultValue: "Night standby steady around %@ between 01:00 and 05:00."),
                EnergyFormat.watts(nightBase)
            )))
        }

        if houseTodayKilowattHours > 0,
           let top = devices.filter({ $0.todayKilowattHours > 0 })
               .max(by: { $0.todayKilowattHours < $1.todayKilowattHours }) {
            let share = top.todayKilowattHours / houseTodayKilowattHours
            if share > 0.05 {
                rows.append(("powerplug.fill", .orange, String(
                    format: String(localized: "energy.insight.topPlug",
                                   defaultValue: "%1$@ accounts for %2$@ of the house consumption today."),
                    top.name,
                    share.formatted(.percent.precision(.fractionLength(0)))
                )))
            }
        }

        let months = houseMonths
        if months.count >= 4 {
            let current = months[months.count - 1].kilowattHours
            let previous = months[(months.count - 4)...(months.count - 2)].map(\.kilowattHours)
            let average = previous.reduce(0, +) / 3
            if average > 0, current > 0 {
                // Proiettato a fine mese per confrontare mele con mele.
                let projected = monthEndProjection ?? current
                rows.append((projected > average ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                             projected > average ? Color(.systemRed) : Color(.systemGreen),
                             projected > average
                             ? String(localized: "energy.insight.monthAbove", defaultValue: "The current month is tracking above the 3-month average.")
                             : String(localized: "energy.insight.monthBelow", defaultValue: "The current month is tracking below the 3-month average.")))
            }
        }

        return rows
    }

    /// «Trend e confronti»: il mese si sfoglia QUI, con ‹ › e barre
    /// selezionabili — l'analisi completa resta a un tap (lente in alto).
    private var trendCard: some View {
        let months = houseMonths
        let selected = trendMonth ?? months.last?.day
        let selectedTotal = selected.flatMap { day in months.first { $0.day == day }?.kilowattHours } ?? 0
        let previousTotal: Double = {
            guard let selected,
                  let index = months.firstIndex(where: { $0.day == selected }), index > 0 else { return 0 }
            return months[index - 1].kilowattHours
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "energy.card.trend", defaultValue: "Trends and comparisons"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                NavigationLink {
                    EnergyAnalysisView()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if let selected {
                HStack(spacing: 10) {
                    Button { moveTrendMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canMoveTrendMonth(-1))

                    Text(selected.formatted(.dateTime.month(.wide).year()))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)

                    Button { moveTrendMonth(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canMoveTrendMonth(1))
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(EnergyFormat.kilowattHours(selectedTotal))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    if let cost = formattedCost(selectedTotal) {
                        Text(cost)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if previousTotal > 0 {
                        let delta = selectedTotal - previousTotal
                        Label {
                            Text(verbatim: "\(delta > 0 ? "+" : "−")\(EnergyFormat.kilowattHours(abs(delta)))")
                        } icon: {
                            Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delta > 0 ? Color(.systemRed) : Color(.systemGreen))
                    }
                }
            }

            EnergyAxisBarChart(
                values: months,
                height: 120,
                unitLabel: "kWh",
                xLabel: { $0.formatted(.dateTime.month(.narrow)) },
                barColor: { value in
                    value.day == selected ? .yellow : .yellow.opacity(0.35)
                },
                // La serie spenta accanto: ogni mese col suo precedente.
                secondaryValues: [0] + months.dropLast().map(\.kilowattHours),
                selectedDay: selected
            ) { month in
                withAnimation(.easeOut(duration: 0.15)) { trendMonth = month }
            }

            HStack(spacing: 12) {
                Label {
                    Text(String(localized: "energy.trend.legend.current", defaultValue: "Selected month"))
                } icon: {
                    RoundedRectangle(cornerRadius: 2).fill(Color.yellow).frame(width: 8, height: 8)
                }
                Label {
                    Text(String(localized: "energy.trend.legend.previous", defaultValue: "Previous month"))
                } icon: {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.18)).frame(width: 8, height: 8)
                }
                Spacer()
                Text(String(localized: "energy.trend.footer", defaultValue: "Compared with the previous month"))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // Il drill-down che si era perso: i GIORNI del mese scelto, qui
            // dentro — e ogni giorno apre l'analisi già puntata su di lui.
            if let selected {
                Divider()
                HStack {
                    Text(String(format: String(localized: "energy.trend.days", defaultValue: "Days of %@"),
                                selected.formatted(.dateTime.month(.wide))))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let day = selectedTrendDay {
                        // Il ponte visivo verso la card della giornata: stesso
                        // giallo, stesso giorno, con la ✕ per liberarlo.
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { selectedTrendDay = nil }
                        } label: {
                            HStack(spacing: 4) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                EnergyAxisBarChart(
                    values: trendMonthDays(selected),
                    height: 96,
                    unitLabel: "kWh",
                    xLabel: { day in
                        let number = Calendar.current.component(.day, from: day)
                        return number == 1 || number % 5 == 0 ? "\(number)" : ""
                    },
                    barColor: { value in
                        guard let day = selectedTrendDay else { return .yellow.opacity(0.8) }
                        return value.day == day ? .yellow : .yellow.opacity(0.3)
                    },
                    selectedDay: selectedTrendDay
                ) { day in
                    withAnimation(.easeOut(duration: 0.2)) { selectedTrendDay = day }
                }
                Text(selectedTrendDay != nil
                     ? String(localized: "energy.trend.days.selectedHint", defaultValue: "The highlighted day is open in the day card.")
                     : String(localized: "energy.trend.days.hint", defaultValue: "Tap a day to see it in the day card."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func trendMonthDays(_ month: Date) -> [EnergyDayTotal] {
        let calendar = Calendar.current
        let count: Int
        let reference: Date
        if calendar.isDate(.now, equalTo: month, toGranularity: .month) {
            count = calendar.component(.day, from: .now)
            reference = .now
        } else {
            count = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
            reference = calendar.date(byAdding: .day, value: max(0, count - 1), to: month) ?? month
        }
        guard count > 0 else { return [] }
        return EnergyStatsBuilder.dailyTotals(points: housePoints, days: count, reference: reference)
    }

    private func canMoveTrendMonth(_ delta: Int) -> Bool {
        let months = houseMonths
        guard let current = trendMonth ?? months.last?.day,
              let index = months.firstIndex(where: { $0.day == current }) else { return false }
        let target = index + delta
        return months.indices.contains(target)
    }

    private func moveTrendMonth(_ delta: Int) {
        let months = houseMonths
        guard let current = trendMonth ?? months.last?.day,
              let index = months.firstIndex(where: { $0.day == current }),
              months.indices.contains(index + delta) else { return }
        withAnimation(.easeOut(duration: 0.15)) { trendMonth = months[index + delta].day }
    }

    private var annualSummary: String? {
        let total = houseMonths.map(\.kilowattHours).reduce(0, +)
        guard total > 0 else { return nil }
        var summary = String(
            format: String(localized: "energy.monthly.total", defaultValue: "Total: %@"),
            formattedKilowattHours(total)
        )
        if let cost = formattedCost(total) {
            summary += " · \(cost)"
        }
        return summary
    }

    // MARK: Dati

    private var devices: [EnergyDeviceSummary] {
        EnergyDeviceSummary.build(samples: samples,
                                  liveSnapshots: matterEnergy.snapshots,
                                  windowDays: Self.windowDays)
    }

    private var housePoints: [EnergyStatsPoint] {
        houseSamples.map {
            EnergyStatsPoint(timestamp: $0.timestamp, cumulativeKilowattHours: $0.cumulativeKilowattHours)
        }
    }

    private var houseDays: [EnergyDayTotal] {
        EnergyStatsBuilder.dailyTotals(points: housePoints, days: Self.windowDays)
    }

    private var houseMonths: [EnergyDayTotal] {
        EnergyStatsBuilder.monthlyTotals(points: housePoints, months: 12)
    }

    private var houseTodayKilowattHours: Double { houseDays.last?.kilowattHours ?? 0 }
    private var houseYesterdayKilowattHours: Double { houseDays.dropLast().last?.kilowattHours ?? 0 }

    /// Ciò che il contatore vede e le prese no: luci, forno, induzione,
    /// clima. È il numero che nessuna presa smart può dare.
    private var otherTodayKilowattHours: Double? {
        guard !houseSamples.isEmpty else { return nil }
        let difference = houseTodayKilowattHours - totalTodayKilowattHours
        return difference > 0.05 ? difference : nil
    }

    private var totalWattsNow: Double? {
        let watts = matterEnergy.snapshots.compactMap(\.activePowerWatts)
        return watts.isEmpty ? nil : watts.reduce(0, +)
    }

    private var totalTodayKilowattHours: Double {
        devices.map(\.todayKilowattHours).reduce(0, +)
    }

    /// Controlla se l'export Vimar ricordato è cambiato e in quel caso lo
    /// reimporta. Silenzioso quando non c'è nulla: il toast compare solo
    /// con righe nuove.
    private func autoImportVimarIfNeeded() async {
        guard let outcome = await VimarAutoImport.importIfChanged(modelContainer: modelContext.container),
              outcome.inserted > 0 else { return }
        autoImportToast = String(
            format: String(localized: "energy.autoImport.toast",
                           defaultValue: "Vimar export updated: %d new samples"),
            outcome.inserted
        )
        try? await Task.sleep(for: .seconds(4))
        autoImportToast = nil
    }

    private func refreshLive(force: Bool = false) async {
        guard let home = homeKit.currentHome else { return }
        if force {
            await matterEnergy.refresh(home: home)
        } else {
            await matterEnergy.refreshIfNeeded(home: home, minimumInterval: 60)
        }
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !houseSamples.isEmpty {
                    houseHeroCard
                    statTilesGrid
                    // Due colonne dove lo spazio c'è (iPad), una dove non c'è:
                    // il mockup usa TUTTA la larghezza, e aveva ragione.
                    if horizontalSizeClass == .regular {
                        // La ripartizione sta SOTTO il Trend: segue lo stesso
                        // mese selezionato, è figlia sua. A destra le card di
                        // oggi; il biglietto prese chiude a tutta larghezza.
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 14) {
                                trendCard
                                trendBreakdownCard
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: 14) {
                                dayProfileCard
                                insightsCard
                                topConsumersCard
                            }
                            .frame(maxWidth: .infinity)
                        }
                        plugsSummaryCard
                    } else {
                        trendCard
                        trendBreakdownCard
                        dayProfileCard
                        insightsCard
                        topConsumersCard
                        plugsSummaryCard
                    }
                } else {
                    // Senza contatore generale la dashboard è solo prese:
                    // resta il biglietto verso il dettaglio.
                    plugsSummaryCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// Il biglietto verso il dettaglio per accessorio: totale prese di oggi,
    /// costo, W adesso — e il resto vive in `EnergyDevicesView`.
    @ViewBuilder
    private var plugsSummaryCard: some View {
        if !devices.isEmpty {
            NavigationLink {
                EnergyDevicesView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "powerplug.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 34, height: 34)
                        .background(Color.yellow.opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "energy.plugs.section", defaultValue: "Measured outlets"))
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: String(localized: "energy.plugs.count", defaultValue: "%d outlets"),
                                    devices.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(EnergyFormat.kilowattHours(totalTodayKilowattHours))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                            if let cost = formattedCost(totalTodayKilowattHours) {
                                Text(cost)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let watts = totalWattsNow {
                            Label(EnergyFormat.watts(watts), systemImage: "bolt.fill")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.yellow)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "energy.empty.title", defaultValue: "No energy data yet"),
                  systemImage: "bolt.circle")
        } description: {
            Text(String(localized: "energy.empty.message",
                        defaultValue: "History builds up on its own from Matter and Eve outlets that measure consumption. Keep the app open for a while and come back."))
        }
    }

    // MARK: Formato

    private func formattedKilowattHours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " kWh"
    }

    /// `nil` a tariffa zero: i costi compaiono solo se l'utente li ha chiesti.
    private func formattedCost(_ kilowattHours: Double) -> String? {
        guard tariffPerKWh > 0 else { return nil }
        return (kilowattHours * tariffPerKWh)
            .formatted(.currency(code: Locale.current.currency?.identifier ?? "EUR")
                .precision(.fractionLength(2)))
    }
}


/// Il biglietto per l'analisi già aperta sul punto giusto.
struct EnergyAnalysisDestination: Identifiable, Hashable {
    var id: String { "\(month.timeIntervalSince1970)-\(day?.timeIntervalSince1970 ?? 0)" }
    let month: Date
    let day: Date?
}
