import SwiftUI
import HomeKit

// MARK: - SnapshotsView

/// Backup e ripristino della configurazione HomeKit.
///
/// **Un pulsante** che cattura, e sotto l'elenco di ciò che è stato catturato.
/// Niente schedulazione: gli snapshot si fanno quando si sta per toccare
/// qualcosa, ed è quello il momento in cui ha senso dargli un nome.
struct SnapshotsView: View {

    @Environment(HomeSnapshotStore.self) private var store
    @Environment(HomeSnapshotCapture.self) private var capture
    @Environment(ArchiveStore.self) private var archive
    @Environment(HomeKitService.self) private var homeKit

    @State private var isCapturing = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var lastOutcome: HomeSnapshotStore.SaveOutcome?
    @State private var pendingTitle = ""
    @State private var isAskingTitle = false

    private var archivedCount: Int {
        guard let home = homeKit.currentHome else { return 0 }
        return archive.items(homeName: home.name).count
    }

    var body: some View {
        List {
            statusSection
            snapshotsSection
        }
        .maintenanceBottomClearance()
        .navigationTitle(String(localized: "sidebar.snapshots", defaultValue: "Backup & Restore"))
        .alert(String(localized: "maintenance.newSnapshot.title", defaultValue: "New snapshot"),
               isPresented: $isAskingTitle) {
            TextField(String(localized: "maintenance.newSnapshot.placeholder",
                             defaultValue: "What are you about to change?"),
                      text: $pendingTitle)
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingTitle = ""
            }
            Button(String(localized: "maintenance.newSnapshot.confirm", defaultValue: "Capture")) {
                Task { await performCapture(title: pendingTitle) }
            }
        } message: {
            // Il titolo non è un vezzo: chi tiene backup da anni li chiama col
            // motivo per cui li ha fatti — «prima di aggiungere il sensore»,
            // «recupero Vimar» — e un elenco di sole date non si legge.
            Text(String(localized: "maintenance.newSnapshot.message",
                        defaultValue: "A name helps later: “before adding the sensor” tells you more than a date."))
        }
    }

    // MARK: - Stato

    private var statusSection: some View {
        Section {
            if isCapturing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                    Text(String(localized: "maintenance.capturing", defaultValue: "Reading the configuration…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    pendingTitle = ""
                    isAskingTitle = true
                } label: {
                    Label(String(localized: "maintenance.capture", defaultValue: "Create snapshot"),
                          systemImage: "camera.viewfinder")
                }
            }

            if !store.entries.isEmpty {
                NavigationLink {
                    RestorePickerView()
                } label: {
                    Label(String(localized: "restore.open", defaultValue: "Restore…"),
                          systemImage: "arrow.counterclockwise")
                }
            }

            // L'archivio è raggiungibile anche dalla sidebar, ma chi è entrato
            // qui sta già cercando come rimettere qualcosa: nascondergli le
            // copie singole lo costringerebbe a ricordarsi dell'altra voce.
            if archivedCount > 0 {
                NavigationLink {
                    ArchiveView()
                } label: {
                    HStack {
                        Label(String(localized: "sidebar.archive", defaultValue: "Archive"),
                              systemImage: "archivebox")
                        Spacer()
                        Text("\(archivedCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if let latest = store.entries.first {
                NavigationLink {
                    SnapshotDetailView(entry: latest)
                } label: {
                    latestRow(latest)
                }
            }

            if let outcome = lastOutcome {
                outcomeRow(outcome)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(String(localized: "maintenance.status.header", defaultValue: "Latest snapshot"))
        }
    }

    private func latestRow(_ entry: HomeSnapshotStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayTitle)
            Text(entry.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: HomeSnapshotStore.SaveOutcome) -> some View {
        switch outcome {
        case .created:
            Label(String(localized: "maintenance.outcome.created", defaultValue: "Snapshot created"),
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .unchanged(let entry):
            // Non è un errore né un fallimento: è l'informazione che serviva.
            Label(String(format: String(localized: "maintenance.outcome.unchanged",
                                        defaultValue: "Nothing has changed since %@ — no copy was made."),
                         entry.displayTitle),
                  systemImage: "equal.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Elenco

    private var snapshotsSection: some View {
        Section {
            if store.entries.isEmpty {
                Text(String(localized: "maintenance.empty",
                            defaultValue: "No snapshots yet. Make one before changing something in your home."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.entries) { entry in
                    NavigationLink {
                        SnapshotDetailView(entry: entry)
                    } label: {
                        SnapshotRow(entry: entry)
                    }
                    // Senza scorrimento completo: eliminare un backup resta
                    // irreversibile, e due gesti volute costano meno di una
                    // finestra di conferma che rallenterebbe proprio il caso
                    // per cui questo esiste — farne fuori diversi di fila.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.delete(entry.id)
                        } label: {
                            Label(String(localized: "common.delete", defaultValue: "Delete"),
                                  systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(String(localized: "maintenance.all.header", defaultValue: "All snapshots"))
                Spacer()
                if !store.entries.isEmpty {
                    Text("\(store.entries.count) · \(store.totalByteCount / 1024) KB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Cattura

    private func performCapture(title: String) async {
        isCapturing = true
        errorMessage = nil
        defer { isCapturing = false }

        do {
            let snapshot = try await capture.capture()
            lastOutcome = try store.save(snapshot, title: title)
        } catch {
            errorMessage = error.localizedDescription
            lastOutcome = nil
        }
        pendingTitle = ""
    }
}

// MARK: - Riga

struct SnapshotRow: View {
    let entry: HomeSnapshotStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(BrandColor.primary)
                }
                Text(entry.displayTitle)
            }
            Text(entry.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.countsLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Presentazione della riga d'indice

extension HomeSnapshotStore.Entry {

    var displayTitle: String {
        title.isEmpty
            ? capturedAt.formatted(date: .abbreviated, time: .shortened)
            : title
    }

    var subtitle: String {
        var parts: [String] = []
        if !title.isEmpty {
            parts.append(capturedAt.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(capturedAt.formatted(.relative(presentation: .named)))
        parts.append(deviceName)
        return parts.joined(separator: " · ")
    }

    var countsLine: String {
        String(
            format: String(localized: "snapshot.counts",
                           defaultValue: "%1$d accessories · %2$d scenes · %3$d automations · %4$d rooms"),
            counts.accessories, counts.scenes, counts.automations, counts.rooms
        )
    }
}
