import SwiftUI

// MARK: - AccessoryCensusView

/// Il censimento, guardabile.
///
/// L'ordinamento non è alfabetico: in cima vanno **gli spariti**, perché sono
/// gli unici su cui ci sarà qualcosa da decidere, e subito sotto i comparsi di
/// recente, che sono i loro possibili sostituti. Il resto della casa è materiale
/// di consultazione e sta in fondo.
struct AccessoryCensusView: View {

    @Environment(AccessoryCensusService.self) private var census

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var isSweeping = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, gone, recent, withoutSerial
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:           String(localized: "census.filter.all", defaultValue: "All")
            case .gone:          String(localized: "census.filter.gone", defaultValue: "Gone")
            case .recent:        String(localized: "census.filter.recent", defaultValue: "Recent")
            case .withoutSerial: String(localized: "census.filter.noSerial", defaultValue: "No serial")
            }
        }
    }

    /// Quanto indietro guardare per dire «comparso di recente». Trenta giorni
    /// coprono comodamente il tempo fra «ho tolto il vecchio» e «ho finito di
    /// configurare il nuovo», che raramente è la stessa sera.
    private static let recentWindow: TimeInterval = 30 * 24 * 3600

    var body: some View {
        List {
            if !gone.isEmpty && filter != .recent && filter != .withoutSerial {
                Section {
                    ForEach(gone) { row in CensusRow(row: row) }
                } header: {
                    Label(String(localized: "census.section.gone", defaultValue: "Gone from HomeKit"),
                          systemImage: "exclamationmark.triangle.fill")
                } footer: {
                    Text(String(localized: "census.section.gone.footer",
                                defaultValue: "Still known here, no longer in HomeKit. These are the ones that may have been replaced."))
                }
            }

            if !recent.isEmpty && filter != .gone {
                Section {
                    ForEach(recent) { row in CensusRow(row: row) }
                } header: {
                    Label(String(localized: "census.section.recent", defaultValue: "Appeared recently"),
                          systemImage: "sparkles")
                }
            }

            if filter != .gone && filter != .recent {
                ForEach(groupedRooms, id: \.room) { group in
                    Section(group.room) {
                        ForEach(group.rows) { row in CensusRow(row: row) }
                    }
                }
            }

            if isEmpty {
                ContentUnavailableView(
                    String(localized: "census.empty", defaultValue: "Nothing here"),
                    systemImage: "questionmark.square.dashed"
                )
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "census.header", defaultValue: "Accessory census"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isSweeping = true
                        await census.sweep()
                        isSweeping = false
                    }
                } label: {
                    if isSweeping {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isSweeping)
            }
        }
    }

    // MARK: - Selezione

    private var matching: [KnownAccessory] {
        let rows = census.currentRows
        guard !search.isEmpty else { return rows }
        let needle = search.lowercased()
        return rows.filter {
            [$0.name, $0.roomName, $0.manufacturer, $0.model, $0.serialNumber]
                .compactMap { $0 }.joined(separator: " ").lowercased().contains(needle)
        }
    }

    private var gone: [KnownAccessory] {
        matching.filter(\.isRetired).sorted { ($0.retiredAt ?? .distantPast) > ($1.retiredAt ?? .distantPast) }
    }

    private var recent: [KnownAccessory] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return matching
            // Le righe seminate hanno una data di comparsa che non significa
            // niente: sono state censite, non viste nascere.
            .filter { !$0.isRetired && !$0.isSeeded && $0.firstSeenAt > cutoff }
            .sorted { $0.firstSeenAt > $1.firstSeenAt }
    }

    private var groupedRooms: [(room: String, rows: [KnownAccessory])] {
        var live = matching.filter { !$0.isRetired }
        if filter == .withoutSerial {
            live = live.filter { ($0.serialNumber ?? "").isEmpty }
        }
        let recentIDs = Set(recent.map(\.id))
        if filter == .all { live = live.filter { !recentIDs.contains($0.id) } }
        return Dictionary(grouping: live) { $0.roomName ?? "—" }
            .map { (room: $0.key, rows: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.room < $1.room }
    }

    private var isEmpty: Bool {
        switch filter {
        case .gone:   gone.isEmpty
        case .recent: recent.isEmpty
        default:      gone.isEmpty && recent.isEmpty && groupedRooms.isEmpty
        }
    }
}

// MARK: - Riga

private struct CensusRow: View {
    let row: KnownAccessory

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.name)
                if row.isRetired {
                    Text(String(localized: "census.badge.gone", defaultValue: "gone"))
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            let description = [row.manufacturer, row.model].compactMap { $0 }.joined(separator: " · ")
            if !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                identityBadge
                Text(dateLine)
                if row.deviceUUIDs.count > 1 {
                    // Quante installazioni sanno chi è: è la prova visibile che
                    // l'identità ha attraversato i device.
                    Label("\(row.deviceUUIDs.count)", systemImage: "ipad.and.iphone")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var identityBadge: some View {
        if !(row.serialNumber ?? "").isEmpty {
            Label(String(localized: "snapshot.identity.serial", defaultValue: "serial"),
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label(String(localized: "snapshot.identity.byName", defaultValue: "no serial"),
                  systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }

    /// Su una riga seminata `firstSeenAt` è il giorno in cui l'app ha guardato,
    /// non quello in cui l'accessorio è arrivato. Dirlo «aggiunto il» sarebbe
    /// una data inventata, e questa funzione vive di date.
    private var dateLine: String {
        if let retiredAt = row.retiredAt {
            return String(format: String(localized: "census.date.gone", defaultValue: "gone %@"),
                          retiredAt.formatted(date: .abbreviated, time: .omitted))
        }
        let key = row.isSeeded
            ? String(localized: "census.date.observed", defaultValue: "observed since %@")
            : String(localized: "census.date.added", defaultValue: "added %@")
        return String(format: key, row.firstSeenAt.formatted(date: .abbreviated, time: .omitted))
    }
}
