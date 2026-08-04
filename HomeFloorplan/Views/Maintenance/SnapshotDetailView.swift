import SwiftUI

// MARK: - SnapshotDetailView

/// Cosa c'è dentro uno snapshot, e se combacia ancora con la casa di adesso.
///
/// L'hero porta l'informazione che costa meno e vale di più: dopo quello scatto
/// è cambiato qualcosa oppure no, senza doverlo confrontare a mano. Sotto, il
/// contenuto diviso per tipologia.
struct SnapshotDetailView: View {

    let entry: HomeSnapshotStore.Entry

    @Environment(HomeSnapshotStore.self) private var store
    @Environment(HomeSnapshotCapture.self) private var capture
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: HomeConfigurationSnapshot?
    @State private var currentFingerprint: String?
    @State private var loadError: String?
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false

    /// `nil` finché il confronto con la casa viva non è pronto.
    private var isUpToDate: Bool? {
        guard let currentFingerprint else { return nil }
        return currentFingerprint == entry.fingerprint
    }

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let snapshot {
                if snapshot.formatVersion < HomeConfigurationSnapshot.currentFormatVersion {
                    Section {
                        Label(String(localized: "snapshot.olderFormat",
                                     defaultValue: "Taken by an earlier version: some details were not recorded yet, and show as raw identifiers. A new snapshot will have them."),
                              systemImage: "clock.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                contentSection(snapshot)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftTitle = entry.title
                        isRenaming = true
                    } label: {
                        Label(String(localized: "snapshot.rename", defaultValue: "Rename"),
                              systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label(String(localized: "common.delete", defaultValue: "Delete"),
                              systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .alert(String(localized: "snapshot.rename", defaultValue: "Rename"), isPresented: $isRenaming) {
            TextField(String(localized: "snapshot.title.placeholder", defaultValue: "Title"),
                      text: $draftTitle)
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "common.save", defaultValue: "Save")) {
                store.rename(entry.id, to: draftTitle)
            }
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

    // MARK: - Hero

    private var statusColor: Color {
        switch isUpToDate {
        case .some(true):  .green
        case .some(false): .blue
        case .none:        .secondary
        }
    }

    private var statusLabel: String {
        switch isUpToDate {
        case .some(true):
            String(localized: "snapshot.badge.upToDate", defaultValue: "Matches your home")
        case .some(false):
            String(localized: "snapshot.badge.outOfDate", defaultValue: "Your home has changed since")
        case .none:
            String(localized: "snapshot.badge.checking", defaultValue: "Comparing…")
        }
    }

    private var statusSymbol: String {
        switch isUpToDate {
        case .some(true):  "checkmark.seal.fill"
        case .some(false): "arrow.triangle.2.circlepath"
        case .none:        "clock"
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(statusColor)
                        Text(statusLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                    }

                    Text(entry.displayTitle)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [statusColor.opacity(0.15), statusColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(statusColor)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            HStack(spacing: 0) {
                statCell(icon: "calendar",
                         title: String(localized: "snapshot.savedAt", defaultValue: "Saved on"),
                         value: entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                Divider().frame(height: 36)
                statCell(icon: "ipad.and.iphone",
                         title: String(localized: "snapshot.device", defaultValue: "Device"),
                         value: entry.deviceName)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 0) {
                statCell(icon: "internaldrive",
                         title: String(localized: "snapshot.size", defaultValue: "Size"),
                         value: "\(entry.byteCount / 1024) KB")
                Divider().frame(height: 36)
                // Quota di accessori riconoscibili anche su un device diverso da
                // quello che ha catturato: là gli identificatori di HomeKit non
                // coincidono e contano solo seriale, marca, modello e stanza.
                statCell(icon: "checkmark.shield",
                         title: String(localized: "snapshot.coverage", defaultValue: "Sure identity"),
                         value: "\(Int((entry.identityCoverage * 100).rounded()))%")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(statusColor.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: statusColor.opacity(0.08), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    private func statCell(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(statusColor.opacity(0.75))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                         snapshot.userScenes.count)
            }
            NavigationLink {
                SnapshotAutomationListView(snapshot: snapshot)
            } label: {
                countRow("gearshape.2", String(localized: "snapshot.automations", defaultValue: "Automations"),
                         snapshot.automations.count)
            }
            NavigationLink {
                SnapshotRoomListView(snapshot: snapshot)
            } label: {
                countRow("door.left.hand.closed", String(localized: "snapshot.rooms", defaultValue: "Rooms"),
                         snapshot.rooms.count)
            }
            if !snapshot.zones.isEmpty {
                NavigationLink {
                    SnapshotZoneListView(snapshot: snapshot)
                } label: {
                    countRow("square.grid.3x3", String(localized: "snapshot.zones", defaultValue: "Zones"),
                             snapshot.zones.count)
                }
            }
            if !snapshot.serviceGroups.isEmpty {
                NavigationLink {
                    SnapshotServiceGroupListView(snapshot: snapshot)
                } label: {
                    countRow("rectangle.3.group",
                             String(localized: "snapshot.serviceGroups", defaultValue: "Service groups"),
                             snapshot.serviceGroups.count)
                }
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
        currentFingerprint = try? await capture.capture().configurationFingerprint
    }
}
