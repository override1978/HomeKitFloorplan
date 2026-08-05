import SwiftUI
import HomeKit

// MARK: - ArchiveView

/// Le copie singole messe da parte, e come rimetterle.
///
/// Separata da «Backup e Ripristino» perché risponde a un'altra domanda: là si
/// chiede «com'era **la casa**», qui «com'era **questa scena**». Un archivio
/// dentro l'elenco dei backup avrebbe confuso i due.
struct ArchiveView: View {

    @Environment(ArchiveStore.self) private var archive
    @Environment(HomeKitService.self) private var homeKit

    private var items: [ArchivedItem] {
        guard let home = homeKit.currentHome else { return [] }
        return archive.items(homeName: home.name)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    String(localized: "archive.empty.title", defaultValue: "Nothing set aside"),
                    systemImage: "archivebox",
                    description: Text(String(localized: "archive.empty.message",
                                             defaultValue: "Hold a scene or an automation and choose “Set aside for later” to keep a copy you can put back another day."))
                )
            } else {
                List {
                    // Per tipologia, non in ordine di data: si torna qui sapendo
                    // *cosa* si cerca — «la planimetria di prima» — molto più
                    // spesso che sapendo quando la si era messa da parte.
                    ForEach(grouped, id: \.kind) { group in
                        Section {
                            ForEach(group.items) { item in
                                NavigationLink {
                                    ArchivedItemDetailView(item: item)
                                } label: {
                                    row(item)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        archive.delete(item.id)
                                    } label: {
                                        Label(String(localized: "common.delete", defaultValue: "Delete"),
                                              systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Label(group.kind.title, systemImage: group.kind.symbolName)
                                Spacer()
                                Text("\(group.items.count)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .maintenanceBottomClearance()
        .navigationTitle(String(localized: "sidebar.archive", defaultValue: "Archive"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Le tipologie presenti, ognuna con le sue copie dalla più recente.
    private var grouped: [(kind: ArchivedItem.Kind, items: [ArchivedItem])] {
        Dictionary(grouping: items, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.archivedAt > $1.archivedAt }) }
            .sorted { $0.kind < $1.kind }
    }

    private func row(_ item: ArchivedItem) -> some View {
        // Niente icona sulla riga: la porta già l'intestazione della sezione, e
        // ripeterla su ogni riga della stessa tipologia è rumore.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.archivedAt.formatted(date: .abbreviated, time: .shortened)
                     + " · " + item.summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Dettaglio

struct ArchivedItemDetailView: View {

    let item: ArchivedItem

    @Environment(ArchiveStore.self) private var archive
    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(FloorplanArchiveService.self) private var floorplanArchive
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirming = false
    @State private var isApplying = false
    @State private var outcome: SnapshotRestoreExecutor.Outcome?
    @State private var draftNote = ""
    @State private var isEditingNote = false

    var body: some View {
        List {
            if let outcome { outcomeSection(outcome) }

            Section {
                LabeledContent(String(localized: "archive.archivedAt", defaultValue: "Set aside on"),
                               value: item.archivedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(String(localized: "snapshot.device", defaultValue: "Device"),
                               value: item.deviceName)
                if !item.note.isEmpty {
                    LabeledContent(String(localized: "archive.note", defaultValue: "Note"),
                                   value: item.note)
                }
            }

            contentSection

            Section {
                Button {
                    isConfirming = true
                } label: {
                    if isApplying {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(localized: "restore.running", defaultValue: "Restoring…"))
                        }
                    } else {
                        Label(String(localized: "archive.apply", defaultValue: "Restore"),
                              systemImage: "arrow.counterclockwise")
                    }
                }
                .disabled(isApplying)
            } footer: {
                Text(String(localized: "archive.apply.footer",
                            defaultValue: "Nothing is deleted: for a scene that still exists, only the values this copy held are rewritten."))
            }
        }
        .maintenanceBottomClearance()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftNote = item.note
                        isEditingNote = true
                    } label: {
                        Label(String(localized: "archive.editNote", defaultValue: "Edit note"),
                              systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        archive.delete(item.id)
                        dismiss()
                    } label: {
                        Label(String(localized: "common.delete", defaultValue: "Delete"),
                              systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(String(localized: "archive.editNote", defaultValue: "Edit note"), isPresented: $isEditingNote) {
            TextField(String(localized: "archive.note", defaultValue: "Note"), text: $draftNote)
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "common.save", defaultValue: "Save")) {
                archive.rename(item.id, note: draftNote)
            }
        }
        .alert(String(format: String(localized: "archive.confirm.title",
                                     defaultValue: "Restore “%@” into HomeKit?"), item.name),
               isPresented: $isConfirming) {
            Button(String(localized: "restore.confirm.action", defaultValue: "Restore"),
                   role: .destructive) {
                Task { await apply() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "restore.confirm.message",
                        defaultValue: "Nothing gets deleted: anything added since this snapshot stays where it is."))
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch item.content {
        case .scene(let scene):
            // Lo stesso raggruppamento per accessorio del dettaglio scena di uno
            // snapshot: una copia e l'originale vanno letti allo stesso modo.
            ForEach(SnapshotSceneDetailView.byAccessory(scene.actions), id: \.name) { group in
                Section {
                    ForEach(group.services) { service in
                        ForEach(Array(service.entries.enumerated()), id: \.offset) { _, entry in
                            LabeledContent(entry.characteristic, value: entry.value)
                        }
                    }
                } header: {
                    Text(group.name).textCase(nil)
                }
            }
        case .automation(let plan):
            Section {
                ForEach(Array(plan.confirmationLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                }
            } header: {
                Text(String(localized: "archive.automation.header", defaultValue: "What it does"))
            }
        case .floorplan(let floorplan):
            Section {
                LabeledContent(String(localized: "archive.floorplan.markers", defaultValue: "Markers"),
                               value: "\(floorplan.markers.count)")
                LabeledContent(String(localized: "snapshot.size", defaultValue: "Size"),
                               value: "\(floorplan.imageByteCount / 1024) KB")
            } footer: {
                Text(String(localized: "archive.floorplan.footer",
                            defaultValue: "It comes back as a new floorplan beside the current one, so nothing is overwritten here or on your other devices."))
            }
        }
    }

    private func outcomeSection(_ outcome: SnapshotRestoreExecutor.Outcome) -> some View {
        Section {
            ForEach(Array(outcome.restored.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            ForEach(Array(outcome.skipped.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(entry.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }

        // Una planimetria non passa da HomeKit: scrive su SwiftData e torna
        // come copia nuova.
        if item.isFloorplan {
            do {
                let report = try floorplanArchive.restoreAsNew(item)
                var result = SnapshotRestoreExecutor.Outcome()
                result.restored = [String(format: String(localized: "archive.floorplan.restored",
                                                         defaultValue: "New floorplan “%1$@” · %2$d markers"),
                                          report.name, report.markersPlaced)]
                if !report.markersUnresolved.isEmpty {
                    // Non è un fallimento: i marker ci sono, manca chi risponde.
                    // La domanda ha già una schermata sua, e si dice dov'è.
                    result.skipped = [(String(format: String(localized: "archive.floorplan.unresolvedTitle",
                                                             defaultValue: "%d markers without an accessory"),
                                              report.markersUnresolved.count),
                                       report.markersUnresolved.joined(separator: ", ")
                                        + " — " + String(localized: "archive.floorplan.unresolvedHint",
                                                         defaultValue: "you can match them under Unknown Accessories"))]
                }
                outcome = result
            } catch {
                outcome = SnapshotRestoreExecutor.Outcome(
                    skipped: [(item.name, error.localizedDescription)])
            }
            return
        }

        let executor = SnapshotRestoreExecutor(homeKit: homeKit,
                                               scenesService: scenesService,
                                               automationsService: automationsService)
        outcome = await executor.apply(item)
    }
}
