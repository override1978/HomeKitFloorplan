import SwiftUI
import SwiftData

// MARK: - DataSettingsView

/// Il dettaglio dell'archivio: quanto c'e' dentro, quando e' stata fatta
/// manutenzione l'ultima volta, e se i dati grezzi si tengono.
///
/// Stava disteso nell'elenco principale, quattro righe e un interruttore, e
/// pesava in altezza quanto una sezione intera per un'informazione che si
/// guarda due volte l'anno. Ora e' dietro una riga di riepilogo, come le
/// Notifiche.
struct DataSettingsView: View {

    @Environment(DataLifecycleService.self) private var dataLifecycleService
    @Environment(\.modelContext) private var modelContext
    @AppStorage(LocalDataProtection.preserveSwiftDataKey) private var preservesRawData = false

    @State private var dataCounts: (readings: Int, summaries: Int, oldest: Date?)?

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(String(localized: "settings.data.lastCycle", defaultValue: "Last maintenance"),
                          systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(Self.lastCycleText(dataLifecycleService.lastCycleDate))
                        .foregroundStyle(.secondary)
                }

                if let dataCounts {
                    HStack {
                        Label(String(localized: "settings.data.stored", defaultValue: "Stored"),
                              systemImage: "internaldrive")
                        Spacer()
                        Text(String(format: String(localized: "settings.data.counts",
                                                   defaultValue: "%d readings · %d summaries"),
                                    dataCounts.readings, dataCounts.summaries))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack {
                        Label(String(localized: "settings.data.oldest", defaultValue: "Oldest reading"),
                              systemImage: "calendar")
                        Spacer()
                        Text(dataCounts.oldest.map {
                            $0.formatted(date: .abbreviated, time: .omitted)
                        } ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task {
                        await dataLifecycleService.runFullCycle()
                        refreshDataCounts()
                    }
                } label: {
                    Label(String(localized: "settings.data.runNow", defaultValue: "Run maintenance now"),
                          systemImage: "play.circle")
                }
                .disabled(dataLifecycleService.isRunning)
            } footer: {
                Text(String(localized: "settings.data.footer", defaultValue: "Readings are summarised into permanent daily aggregates, which feed the environmental baselines. Maintenance normally runs by itself once a day."))
            }

            Section {
                Toggle(isOn: $preservesRawData) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "settings.data.preserveRaw",
                                        defaultValue: "Keep raw data"))
                            Text(String(localized: "settings.data.preserveRaw.subtitle",
                                        defaultValue: "Readings and events older than 30 days are removed once summarised. Their information survives in the permanent daily summaries."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "externaldrive")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings.section.data", defaultValue: "Data"))
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshDataCounts() }
    }

    /// Quando e' stata l'ultima manutenzione, o che non e' mai stata fatta.
    ///
    /// Statica e condivisa con l'elenco principale: la riga di riepilogo mostra
    /// la stessa frase, e calcolarla due volte e' come finiscono per divergere.
    static func lastCycleText(_ date: Date?) -> String {
        date.map { $0.formatted(.relative(presentation: .named)) }
            ?? String(localized: "settings.data.never", defaultValue: "Never")
    }

    private func refreshDataCounts() {
        let context = ModelContext(modelContext.container)
        var oldest = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\SensorReading.timestamp, order: .forward)]
        )
        oldest.fetchLimit = 1
        dataCounts = (
            readings: (try? context.fetchCount(FetchDescriptor<SensorReading>())) ?? 0,
            summaries: (try? context.fetchCount(FetchDescriptor<DailySensorSummary>())) ?? 0,
            oldest: (try? context.fetch(oldest))?.first?.timestamp
        )
    }
}
