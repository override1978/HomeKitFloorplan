import SwiftUI

/// Vista dedicata per le scene HomeKit. Accessibile sia dalla sidebar
/// principale dell'app (come vista navigata) sia dal floorplan (come sheet).
struct ScenesView: View {
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss
    @Environment(IconOverrideStore.self) private var iconOverrides
    @State private var iconPickerTarget: SceneItem?
    @State private var selectedRoomID: UUID?
    @State private var sceneDetailTarget: SceneItem?
    
    /// Mostra il bottone "Chiudi" solo quando la vista è presentata come sheet.
    var presentedAsSheet: Bool = false
    
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !scenesService.representedRooms.isEmpty {
                    roomFilterBar
                }
                
                ScrollView {
                    let filtered = filteredScenes
                    
                    if filtered.isEmpty && scenesService.scenes.isEmpty {
                        ContentUnavailableView {
                            Label("Nessuna scena", systemImage: "wand.and.sparkles")
                        } description: {
                            VStack(spacing: 8) {
                                Text("Non hai ancora scene configurate.")
                                Text("Le scene combinano più accessori in un comando: una scena \"Buonanotte\" può spegnere tutte le luci e abbassare il termostato.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        } actions: {
                            if let url = URL(string: "x-apple-homekit://"), UIApplication.shared.canOpenURL(url) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Label("Crea da Apple Casa", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.top, 60)
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(filtered) { scene in
                                sceneTile(scene)
                            }
                        }
                        .padding(16)
                    }
                }
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Cerca scena")
            }
            .navigationTitle("Scene")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fine") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .task {
                scenesService.refresh()
            }
            .sheet(item: $sceneDetailTarget) { scene in
                SceneDetailSheet(scene: scene)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - Grid

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)]
    }

    private func sceneTile(_ scene: SceneItem) -> some View {
        let isExecuting = executingSceneID == scene.id
        let justSucceeded = recentlySucceededID == scene.id
        
        return Button {
            runScene(scene)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(justSucceeded
                              ? AnyShapeStyle(.green)
                              : AnyShapeStyle(.tint))
                        .frame(width: 44, height: 44)
                    
                    if isExecuting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else if justSucceeded {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.white)
                            .font(.title3.weight(.bold))
                    } else {
                        Image(systemName: iconOverrides.effectiveIcon(for: scene))
                            .foregroundStyle(.white)
                            .font(.title3)
                    }
                }
                .animation(.spring(response: 0.3), value: justSucceeded)
                
                Spacer(minLength: 0)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text("\(scene.actionCount) \(scene.actionCount == 1 ? "azione" : "azioni")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SceneTileButtonStyle())
        .disabled(isExecuting)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    let haptic = UIImpactFeedbackGenerator(style: .medium)
                    haptic.impactOccurred()
                    sceneDetailTarget = scene
                }
        )
    }
    
    private var roomFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                roomPill(label: "Tutte", roomID: nil)
                ForEach(scenesService.representedRooms, id: \.id) { room in
                    roomPill(label: room.name, roomID: room.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        //.background(.bar)
        .background(
                BrandColor.subtleGradient
                    .overlay(.thinMaterial.opacity(0.6))
            )
    }
    
    /// Lista piatta delle scene filtrata per search + stanza.
    private var filteredScenes: [SceneItem] {
        var result = scenesService.scenes
        
        // Filtro search
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        
        // Filtro stanza
        if let selectedRoomID {
            result = result.filter { $0.affiliatedRoomIDs.contains(selectedRoomID) }
        }
        
        return result
    }

    private func roomPill(label: String, roomID: UUID?) -> some View {
        let isSelected = selectedRoomID == roomID
        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedRoomID = roomID
            }
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(.regularMaterial))
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Row
    
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?
    
    // MARK: - Run scene
    
    private func runScene(_ scene: SceneItem) {
        guard executingSceneID == nil else { return }
        
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        
        executingSceneID = scene.id
        
        Task {
            do {
                try await scenesService.run(scene)
                
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.success)
                
                await MainActor.run {
                    executingSceneID = nil
                    recentlySucceededID = scene.id
                }
                
                // Reset "succeeded" stato dopo 1.5s
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    if recentlySucceededID == scene.id {
                        recentlySucceededID = nil
                    }
                }
                
                if presentedAsSheet {
                    await MainActor.run {
                        dismiss()
                    }
                }
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
                
                await MainActor.run {
                    executingSceneID = nil
                }
            }
        }
    }
    
    /// Stile per la cella scena: comprime e scurisce al press, ritorna a normale al release.
    private struct SceneTileButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .opacity(configuration.isPressed ? 0.85 : 1.0)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}
