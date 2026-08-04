import SwiftUI

// MARK: - SnapshotDetailView

/// Cosa c'è dentro uno snapshot, diviso per tipologia, e se combacia ancora con
/// la casa di adesso.
///
/// Il badge in cima è l'informazione che costa meno e vale di più: dice se dopo
/// quello scatto è cambiato qualcosa, senza doverlo confrontare a mano.
struct SnapshotDetailView: View {

    let entry: HomeSnapshotStore.Entry

    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(HomeSnapshotStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: HomeConfigurationSnapshot?
    @State private var currentFingerprint: String?
    @State private var loadError: String?
    @State private var editedTitle = ""
    @State private var isConfirmingDelete = false

    private var isUpToDate: Bool? {
        guard let currentFingerprint else { return nil }
        return currentFingerprint == entry.fingerprint
    }

    var body: some View {
        List {
            headerSection

            if let snapshot {
                contentSection(snapshot)
                identitySection(snapshot)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
            }

            actionsSection
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            editedTitle = entry.title
            await load()
        }
        .confirmationDialog(
            String(localized: "snapshot.delete.title", defaultValue: "Delete this snapshot?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "common.delete", defaultValue: "Delete"), role: .destructive) {
                store.delete(entry.id)
                dismiss()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }

    // MARK: - Intestazione

    private var headerSection: some View {
        Section {
            TextField(String(localized: "snapshot.title.placeholder", defaultValue: "Title"),
                      text: $editedTitle)
                .onSubmit { store.rename(entry.id, to: editedTitle) }

            LabeledContent(String(localized: "snapshot.capturedAt", defaultValue: "Captured"),
                           value: entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent(String(localized: "snapshot.device", defaultValue: "Device"),
                           value: entry.deviceName)
            LabeledContent(String(localized: "snapshot.size", defaultValue: "Size"),
                           value: "\(entry.byteCount / 1024) KB")

            if entry.lastConfirmedAt > entry.capturedAt {
                LabeledContent(String(localized: "snapshot.lastConfirmed", defaultValue: "Still matching as of"),
                               value: entry.lastConfirmedAt.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch isUpToDate {
        case .some(true):
            Label(String(localized: "snapshot.badge.upToDate", defaultValue: "Matches your home"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textCase(nil)
        case .some(false):
            Label(String(localized: "snapshot.badge.outOfDate", defaultValue: "Your home has changed since"),
                  systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .textCase(nil)
        case .none:
            Text(String(localized: "snapshot.badge.checking", defaultValue: "Comparing…"))
                .textCase(nil)
        }
    }

    // MARK: - Contenuto

    private func contentSection(_ snapshot: HomeConfigurationSnapshot) -> some View {
        Section {
            NavigationLink {
                SnapshotAccessoryListView(snapshot: snapshot)
            } label: {
                countRow("lightbulb", String(localized: "snapshot.accessories", defaultValue: "Accessories"),
                         snapshot.accessories.count)
            }
            NavigationLink {
                SnapshotSceneListView(snapshot: snapshot)
            } label: {
                countRow("wand.and.sparkles", String(localized: "snapshot.scenes", defaultValue: "Scenes"),
                         snapshot.scenes.count)
            }
            NavigationLink {
                SnapshotAutomationListView(snapshot: snapshot)
            } label: {
                countRow("gearshape.2", String(localized: "snapshot.automations", defaultValue: "Automations"),
                         snapshot.automations.count)
            }
            countRow("door.left.hand.closed", String(localized: "snapshot.rooms", defaultValue: "Rooms"),
                     snapshot.rooms.count)
            countRow("square.grid.3x3", String(localized: "snapshot.zones", defaultValue: "Zones"),
                     snapshot.zones.count)
            if !snapshot.serviceGroups.isEmpty {
                countRow("rectangle.3.group", String(localized: "snapshot.serviceGroups", defaultValue: "Service groups"),
                         snapshot.serviceGroups.count)
            }
        } header: {
            Text(String(localized: "snapshot.content.header", defaultValue: "Content"))
        }
    }

    private func countRow(_ icon: String, _ title: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Identità

    private func identitySection(_ snapshot: HomeConfigurationSnapshot) -> some View {
        Section {
            LabeledContent(String(localized: "snapshot.identity", defaultValue: "Identifiable without names"),
                           value: "\(Int((snapshot.reliableIdentityCoverage * 100).rounded()))%")
        } footer: {
            // Serve a sapere, prima di provarci, quanto di questo snapshot
            // sarebbe ripristinabile su un device diverso da quello che l'ha
            // catturato: là gli identificatori di HomeKit non coincidono e
            // contano solo numero di serie, marca, modello e stanza.
            Text(String(localized: "snapshot.identity.footer",
                        defaultValue: "How much of this snapshot could be recognised on another device, where HomeKit's own identifiers do not match."))
        }
    }

    // MARK: - Azioni

    private var actionsSection: some View {
        Section {
            Button {
                store.setPinned(!entry.isPinned, for: entry.id)
            } label: {
                Label(entry.isPinned
                      ? String(localized: "snapshot.unpin", defaultValue: "Allow pruning")
                      : String(localized: "snapshot.pin", defaultValue: "Keep forever"),
                      systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label(String(localized: "common.delete", defaultValue: "Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Caricamento

    private func load() async {
        do {
            snapshot = try store.snapshot(with: entry.id)
        } catch {
            loadError = error.localizedDescription
            return
        }
        // Il confronto con l'adesso richiede una cattura, che a regime è
        // istantanea: i numeri di serie sono già in cache.
        let capture = HomeSnapshotCapture(homeKit: homeKit,
                                          scenesService: scenesService,
                                          automationsService: automationsService)
        currentFingerprint = try? await capture.capture().configurationFingerprint
    }
}
