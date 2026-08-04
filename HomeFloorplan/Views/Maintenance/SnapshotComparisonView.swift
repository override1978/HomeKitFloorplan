import SwiftUI

// MARK: - SnapshotComparisonView

/// Cosa succederebbe ripristinando questo snapshot.
///
/// La lettura è sempre nello stesso verso: **cosa tornerebbe**. Le voci arrivate
/// dopo lo scatto si vedono, ma marcate come intoccabili — un ripristino non
/// cancella mai niente, e dirlo qui è più utile che scriverlo in un avviso.
struct SnapshotComparisonView: View {

    let entry: HomeSnapshotStore.Entry

    @Environment(HomeSnapshotStore.self) private var store
    @Environment(HomeSnapshotCapture.self) private var capture
    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService

    @State private var diff: HomeSnapshotDiff?
    @State private var archived: HomeConfigurationSnapshot?
    @State private var errorMessage: String?
    @State private var selection: Set<String> = []
    @State private var isConfirming = false
    @State private var isRestoring = false
    @State private var outcome: SnapshotRestoreExecutor.Outcome?

    var body: some View {
        Group {
            if let diff {
                if diff.isEmpty {
                    ContentUnavailableView(
                        String(localized: "diff.identical.title", defaultValue: "Nothing has changed"),
                        systemImage: "equal.circle",
                        description: Text(String(localized: "diff.identical.message",
                                                 defaultValue: "Your home is exactly as it was in this snapshot. There is nothing to restore."))
                    )
                } else {
                    list(diff)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    String(localized: "diff.error.title", defaultValue: "Could not compare"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView(String(localized: "diff.comparing", defaultValue: "Comparing with your home…"))
            }
        }
        .navigationTitle(String(localized: "diff.title", defaultValue: "Restore"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await compare() }
        .confirmationDialog(
            String(format: String(localized: "restore.confirm.title",
                                  defaultValue: "Restore %d items into HomeKit?"), selection.count),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(String(localized: "restore.confirm.action", defaultValue: "Restore"), role: .destructive) {
                Task { await performRestore() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "restore.confirm.message",
                        defaultValue: "Nothing gets deleted: anything added since this snapshot stays where it is."))
        }
    }

    private func list(_ diff: HomeSnapshotDiff) -> some View {
        List {
            Section {
                Text(String(format: String(localized: "diff.intro",
                                           defaultValue: "Differences between “%@” and your home right now."),
                            entry.displayTitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(diff.categoriesWithChanges) { category in
                Section {
                    ForEach(diff.items(in: category)) { item in
                        row(item)
                    }
                } header: {
                    Label(category.title, systemImage: category.symbol)
                } footer: {
                    if !category.isRestorable {
                        Text(footerReason(for: category))
                    }
                }
            }

            if let outcome { outcomeSection(outcome) }

            Section {
                Button {
                    isConfirming = true
                } label: {
                    if isRestoring {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(localized: "restore.running", defaultValue: "Restoring…"))
                        }
                    } else {
                        Label(String(format: String(localized: "diff.restore.action",
                                                    defaultValue: "Restore %d selected"), selection.count),
                              systemImage: "arrow.counterclockwise")
                    }
                }
                .disabled(selection.isEmpty || isRestoring)
            } footer: {
                Text(String(localized: "diff.restore.footer",
                            defaultValue: "Only what is ticked is written. A restore never deletes: for a scene that already exists, only the values it also contained are rewritten."))
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
            // Un ripristino che tace su ciò che non è riuscito è peggio di uno
            // che fallisce: qui ogni scarto porta il suo motivo.
            ForEach(Array(outcome.skipped.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "restore.outcome.header", defaultValue: "Result"))
        }
    }

    private func row(_ item: HomeSnapshotDiff.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if item.isRestorable {
                Button {
                    if selection.contains(item.id) { selection.remove(item.id) }
                    else { selection.insert(item.id) }
                } label: {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(item.id) ? BrandColor.primary : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else {
                Image(systemName: changeSymbol(item.change))
                    .foregroundStyle(changeColor(item.change))
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                    changeBadge(item.change)
                }
                ForEach(Array(item.details.prefix(6).enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.details.count > 6 {
                    Text(String(format: String(localized: "diff.more",
                                               defaultValue: "and %d more"), item.details.count - 6))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func changeBadge(_ change: HomeSnapshotDiff.Change) -> some View {
        Text(changeTitle(change))
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(changeColor(change).opacity(0.16), in: Capsule())
            .foregroundStyle(changeColor(change))
    }

    private func changeTitle(_ change: HomeSnapshotDiff.Change) -> String {
        switch change {
        case .missingNow:   String(localized: "diff.change.missing", defaultValue: "gone")
        case .newSinceThen: String(localized: "diff.change.new", defaultValue: "added later")
        case .changed:      String(localized: "diff.change.changed", defaultValue: "changed")
        }
    }

    private func changeColor(_ change: HomeSnapshotDiff.Change) -> Color {
        switch change {
        case .missingNow:   .orange
        case .newSinceThen: .secondary
        case .changed:      .blue
        }
    }

    private func changeSymbol(_ change: HomeSnapshotDiff.Change) -> String {
        switch change {
        case .missingNow:   "minus.circle"
        case .newSinceThen: "plus.circle"
        case .changed:      "arrow.triangle.2.circlepath"
        }
    }

    private func footerReason(for category: HomeSnapshotDiff.Category) -> String {
        switch category {
        case .accessories:
            String(localized: "diff.footer.accessories",
                   defaultValue: "Accessories cannot be restored: no app can pair a device back into HomeKit. They are listed so you know what is missing.")
        case .serviceGroups:
            String(localized: "diff.footer.serviceGroups",
                   defaultValue: "Service groups are shown but not restored: the snapshot recorded how many services each one held, not which ones.")
        default:
            ""
        }
    }

    // MARK: - Confronto

    private func compare() async {
        do {
            let stored = try store.snapshot(with: entry.id)
            let now = try await capture.capture()
            let computed = HomeSnapshotDiff.compute(restoring: stored, onto: now)
            archived = stored
            diff = computed
            // Preselezionato tutto il ripristinabile: chi apre questa schermata
            // vuole tornare indietro, non spuntare caselle una per una.
            selection = Set(computed.restorableItems.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRestore() async {
        guard let diff, let archived else { return }
        isRestoring = true
        defer { isRestoring = false }

        let executor = SnapshotRestoreExecutor(homeKit: homeKit,
                                              scenesService: scenesService,
                                              automationsService: automationsService)
        let selected = diff.items.filter { selection.contains($0.id) }
        outcome = await executor.restore(selected, from: archived)

        // Si riconfronta: dopo aver scritto, la casa è cambiata e la lista di
        // prima non descrive più niente.
        await compare()
    }
}

// MARK: - Scelta dello snapshot da cui ripristinare

/// «Da quale backup vuoi partire?» — l'elenco esiste già altrove, ma questo è un
/// ingresso diverso: qui si arriva sapendo *che* si vuole tornare indietro, e la
/// scelta va offerta come domanda, non come archivio da sfogliare.
struct RestorePickerView: View {

    @Environment(HomeSnapshotStore.self) private var store

    var body: some View {
        List {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "restore.empty.title", defaultValue: "No snapshot yet"),
                    systemImage: "camera.viewfinder",
                    description: Text(String(localized: "restore.empty.message",
                                             defaultValue: "Create one first: there is nothing to go back to."))
                )
            } else {
                ForEach(store.entries) { entry in
                    NavigationLink {
                        SnapshotComparisonView(entry: entry)
                    } label: {
                        SnapshotRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "restore.picker.title", defaultValue: "Restore from"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
