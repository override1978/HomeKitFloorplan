import SwiftUI
import HomeKit

/// Sheet dettaglio scena: header con icona cliccabile + nome modificabile,
/// poi azioni raggruppate per stanza.
struct SceneDetailSheet: View {
    let scene: SceneItem
    
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool
    
    @State private var editedName: String = ""
    @State private var iconPickerOpen: Bool = false
    @State private var renameError: String?
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: scene)
    }
    
    private var groupedByRoom: [(roomID: UUID, roomName: String, actions: [SceneActionSummary])] {
        let summaries = scene.actionSummaries
        let grouped = Dictionary(grouping: summaries, by: { $0.roomID })
        return grouped.map { (roomID, actions) in
            let roomName = actions.first?.roomName ?? "Senza stanza"
            return (roomID: roomID, roomName: roomName, actions: actions)
        }
        .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerRow
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                if groupedByRoom.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nessuna azione",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Questa scena non ha azioni associate. Puoi configurarla dall'app Casa di Apple.")
                        )
                    }
                } else {
                    ForEach(groupedByRoom, id: \.roomID) { group in
                        Section(group.roomName) {
                            ForEach(group.actions) { action in
                                actionRow(action)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scena")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") {
                        commitRename()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                if nameFieldFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("OK") {
                            commitRename()
                            nameFieldFocused = false
                        }
                    }
                }
            }
            .sheet(isPresented: $iconPickerOpen) {
                SceneIconPickerSheet(scene: scene)
                    .presentationDetents([.large])
            }
            .alert("Errore",
                   isPresented: Binding(
                    get: { renameError != nil },
                    set: { if !$0 { renameError = nil } }
                   ),
                   presenting: renameError) { _ in
                Button("OK") {}
            } message: { msg in
                Text(msg)
            }
            .onAppear {
                editedName = scene.name
            }
        }
    }
    
    // MARK: - Header row (icona + nome modificabile)
    
    private var headerRow: some View {
        HStack(spacing: 16) {
            Button {
                iconPickerOpen = true
            } label: {
                ZStack {
                    Circle()
                        .fill(.tint.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: iconName)
                        .foregroundStyle(.tint)
                        .font(.largeTitle)
                    
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "pencil")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        )
                        .offset(x: 26, y: 26)
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Nome scena", text: $editedName)
                        .font(.title3.weight(.semibold))
                        .focused($nameFieldFocused)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .onSubmit { commitRename() }
                    
                    if !nameFieldFocused {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(nameFieldFocused
                              ? AnyShapeStyle(Color.accentColor.opacity(0.1))
                              : AnyShapeStyle(.thinMaterial))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(nameFieldFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.2), value: nameFieldFocused)
                
                Text("\(scene.actionCount) \(scene.actionCount == 1 ? "azione" : "azioni")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    
    // MARK: - Action row
    
    private func actionRow(_ action: SceneActionSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.accessoryName)
                    .font(.body)
                Text(action.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Rename
    
    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editedName = scene.name
            return
        }
        guard trimmed != scene.name else { return }
        
        scene.actionSet.updateName(trimmed) { error in
            Task { @MainActor in
                if let error {
                    renameError = "Impossibile rinominare: \(error.localizedDescription)"
                    editedName = scene.name
                } else {
                    // Refresh per propagare il nuovo nome alla lista
                    scenesService.refresh()
                }
            }
        }
    }
}
