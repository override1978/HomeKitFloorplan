import SwiftUI

/// Pannello fluttuante con la lista scene HomeKit.
/// Si mostra come sheet/popover dal floorplan.
struct ScenesPanel: View {
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header compatto
            HStack {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(.tint)
                Text("Scene")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Lista scene
            List {
                if !scenesService.builtInScenes.isEmpty {
                    Section("Predefinite") {
                        ForEach(scenesService.builtInScenes) { scene in
                            sceneRow(scene)
                        }
                    }
                }
                
                if !scenesService.customScenes.isEmpty {
                    Section("Personalizzate") {
                        ForEach(scenesService.customScenes) { scene in
                            sceneRow(scene)
                        }
                    }
                }
                
                if scenesService.scenes.isEmpty {
                    ContentUnavailableView(
                        "Nessuna scena",
                        systemImage: "wand.and.sparkles",
                        description: Text("Crea scene dall'app Casa di Apple.")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .task {
            scenesService.refresh()
        }
    }
    
    private func sceneRow(_ scene: SceneItem) -> some View {
        Button {
            runScene(scene)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.thinMaterial)
                        .frame(width: 36, height: 36)
                    Image(systemName: scene.symbolName)
                        .foregroundStyle(.tint)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(scene.actionCount) \(scene.actionCount == 1 ? "azione" : "azioni")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "play.fill")
                    .foregroundStyle(.tint)
                    .font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func runScene(_ scene: SceneItem) {
        // Haptic immediato per dare feedback "comando ricevuto"
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        
        Task {
            do {
                try await scenesService.run(scene)
                // Success haptic
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.success)
                dismiss()
            } catch {
                // Error haptic
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
