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

    @State private var diff: HomeSnapshotDiff?
    @State private var errorMessage: String?

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

            Section {
                // Un pulsante disabilitato sarebbe una finta: finché la
                // scrittura non c'è, meglio dirlo che mostrarne il fantasma.
                Label(String(localized: "diff.restore.notYet",
                             defaultValue: "Writing back to HomeKit is not available yet. This screen shows exactly what a restore would change."),
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: HomeSnapshotDiff.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: changeSymbol(item.change))
                .foregroundStyle(changeColor(item.change))
                .padding(.top, 2)

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
        case .automations:
            String(localized: "diff.footer.automations",
                   defaultValue: "Automations are kept as documentation. Most of them run Shortcuts, which no third-party app can read or recreate.")
        default:
            ""
        }
    }

    // MARK: - Confronto

    private func compare() async {
        do {
            let archived = try store.snapshot(with: entry.id)
            let now = try await capture.capture()
            diff = HomeSnapshotDiff.compute(restoring: archived, onto: now)
        } catch {
            errorMessage = error.localizedDescription
        }
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
