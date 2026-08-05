import SwiftUI
import SwiftData

// MARK: - LocalDataView

/// Lo stato del database locale e il ciclo che lo tiene in ordine.
///
/// Stava in Impostazioni, ma già si chiamava manutenzione — «Ultima
/// manutenzione», «Esegui manutenzione adesso» — mentre una sezione Manutenzione
/// esisteva altrove. Due posti con lo stesso nome e contenuti diversi sono un
/// posto in cui non si cerca.
///
/// Da distinguere da «Backup e Ripristino», che riguarda la **casa**: qui si
/// parla di quanto misurato conserviamo noi, e di quando lo si compatta.
struct LocalDataView: View {

    @Environment(DataLifecycleService.self) private var dataLifecycleService
    @Environment(\.modelContext) private var modelContext

    @AppStorage(LocalDataProtection.preserveSwiftDataKey) private var preservesRawData = true
    @State private var counts: (readings: Int, summaries: Int, oldest: Date?)?

    var body: some View {
        List {
            Section {
                LabeledContent {
                    Text(dataLifecycleService.lastCycleDate.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? String(localized: "settings.data.never", defaultValue: "Never"))
                } label: {
                    Label(String(localized: "settings.data.lastCycle", defaultValue: "Last maintenance"),
                          systemImage: "arrow.triangle.2.circlepath")
                }

                if let counts {
                    LabeledContent {
                        Text(String(format: String(localized: "settings.data.counts",
                                                   defaultValue: "%d readings · %d summaries"),
                                    counts.readings, counts.summaries))
                            .monospacedDigit()
                    } label: {
                        Label(String(localized: "settings.data.stored", defaultValue: "Stored"),
                              systemImage: "internaldrive")
                    }

                    LabeledContent {
                        Text(counts.oldest.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    } label: {
                        Label(String(localized: "settings.data.oldest", defaultValue: "Oldest reading"),
                              systemImage: "calendar")
                    }
                }

                Button {
                    Task {
                        await dataLifecycleService.runFullCycle()
                        refresh()
                    }
                } label: {
                    Label(String(localized: "settings.data.runNow", defaultValue: "Run maintenance now"),
                          systemImage: "play.circle")
                }
                .disabled(dataLifecycleService.isRunning)
            } footer: {
                Text(String(localized: "settings.data.footer",
                            defaultValue: "Readings are summarised into permanent daily aggregates, which feed the environmental baselines. Maintenance normally runs by itself once a day."))
            }

            // La preferenza resta accanto ai numeri che governa: staccarla e
            // lasciarla in Impostazioni l'avrebbe separata dall'unica cosa che
            // spiega cosa fa.
            Section {
                Toggle(isOn: $preservesRawData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.data.preserveRaw", defaultValue: "Keep raw data"))
                        Text(String(localized: "settings.data.preserveRaw.subtitle",
                                    defaultValue: "Readings and events older than 30 days are removed once summarised. Their information survives in the permanent daily summaries."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .maintenanceBottomClearance()
        .navigationTitle(String(localized: "sidebar.localData", defaultValue: "Local data"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    private func refresh() {
        let context = ModelContext(modelContext.container)
        var oldest = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\SensorReading.timestamp, order: .forward)]
        )
        oldest.fetchLimit = 1
        counts = (
            readings: (try? context.fetchCount(FetchDescriptor<SensorReading>())) ?? 0,
            summaries: (try? context.fetchCount(FetchDescriptor<DailySensorSummary>())) ?? 0,
            oldest: (try? context.fetch(oldest))?.first?.timestamp
        )
    }
}
