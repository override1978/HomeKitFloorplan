import SwiftUI

/// Pannello laterale destro per le scene, mostrato inline sul floorplan editor.
/// Si apre/chiude con animazione slide-from-right senza coprire interamente la planimetria.
struct ScenesSidePanel: View {
    @Binding var isPresented: Bool

    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var searchText: String = ""
    @State private var selectedRoomID: UUID?
    @State private var sceneDetailTarget: SceneItem?
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            searchBar
            if !scenesService.representedRooms.isEmpty {
                roomFilterBar
                Divider()
            }
            sceneList
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, x: -4, y: 0)
        .padding(.vertical, 12)
        .padding(.trailing, 12)
        .task {
            scenesService.refresh()
        }
        .sheet(item: $sceneDetailTarget) { scene in
            SceneDetailSheet(scene: scene)
                .presentationDetents([.large])
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            Text("Scene")
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("Cerca scena", text: $searchText)
                .font(.subheadline)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Room filter bar

    private var roomFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                roomPill(label: String(localized: "filter.all.scenes", defaultValue: "Tutte"), roomID: nil)
                ForEach(scenesService.representedRooms, id: \.id) { room in
                    roomPill(label: room.name, roomID: room.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func roomPill(label: String, roomID: UUID?) -> some View {
        let isSelected = selectedRoomID == roomID
        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedRoomID = roomID
            }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? AnyShapeStyle(BrandColor.heroGradient)
                              : AnyShapeStyle(.regularMaterial))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scene list

    private var sceneList: some View {
        let filtered = filteredScenes
        return ScrollView {
            if filtered.isEmpty && scenesService.scenes.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna scena", systemImage: "wand.and.sparkles")
                } description: {
                    Text("Non hai scene configurate in HomeKit.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .padding(.top, 24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { scene in
                        sceneRow(scene)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Scene row (compact, list-style)

    private func sceneRow(_ scene: SceneItem) -> some View {
        let isExecuting = executingSceneID == scene.id
        let justSucceeded = recentlySucceededID == scene.id

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        justSucceeded
                        ? AnyShapeStyle(Color.green.gradient)
                        : AnyShapeStyle(BrandColor.heroGradient)
                    )
                    .frame(width: 38, height: 38)

                if isExecuting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else if justSucceeded {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.bold))
                } else {
                    Image(systemName: iconOverrides.effectiveIcon(for: scene))
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .animation(.spring(response: 0.3), value: justSucceeded)

            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "azione") : String(localized: "count.action.plural", defaultValue: "azioni"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isExecuting ? 0.6 : 1.0)
        .onTapGesture {
            guard !isExecuting else { return }
            runScene(scene)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.impactOccurred()
            sceneDetailTarget = scene
        }
    }

    // MARK: - Filter

    private var filteredScenes: [SceneItem] {
        var result = scenesService.scenes
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        if let selectedRoomID {
            result = result.filter { $0.affiliatedRoomIDs.contains(selectedRoomID) }
        }
        return result
    }

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

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    if recentlySucceededID == scene.id {
                        recentlySucceededID = nil
                    }
                }

                // Chiudi il pannello dopo l'esecuzione
                await MainActor.run {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isPresented = false
                    }
                }
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
                await MainActor.run { executingSceneID = nil }
            }
        }
    }

}
