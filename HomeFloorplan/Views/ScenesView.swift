import SwiftUI

/// Vista dedicata per le scene HomeKit. Accessibile sia dalla sidebar
/// principale dell'app (come vista navigata) sia dal floorplan (come sheet).
struct ScenesView: View {
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss
    @Environment(IconOverrideStore.self) private var iconOverrides
    @State private var sceneDetailTarget: SceneItem?
    @State private var selectedRoomID: UUID?

    /// Mostra il bottone "Fine" solo quando la vista è presentata come sheet.
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
                            Label(String(localized: "scenes.empty.title", defaultValue: "Nessuna scena"), systemImage: "wand.and.sparkles")
                        } description: {
                            VStack(spacing: 8) {
                                Text(String(localized: "scenes.empty.description1", defaultValue: "Non hai ancora scene configurate."))
                                Text(String(localized: "scenes.empty.description2", defaultValue: "Le scene combinano più accessori in un comando: una scena \"Buonanotte\" può spegnere tutte le luci e abbassare il termostato."))
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
                                    Label(String(localized: "scenes.empty.openHome", defaultValue: "Crea da Apple Casa"), systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.top, 60)
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(filtered) { scene in
                                sceneTile(scene)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: String(localized: "scenes.search.prompt", defaultValue: "Cerca scena"))
            }
            .navigationTitle(String(localized: "scenes.navigationTitle", defaultValue: "Scene"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "scenes.toolbar.done", defaultValue: "Fine")) { dismiss() }
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
        [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]
    }

    private func sceneTile(_ scene: SceneItem) -> some View {
        let isExecuting = executingSceneID == scene.id
        let justSucceeded = recentlySucceededID == scene.id

        return VStack(alignment: .leading, spacing: 10) {
            // Icona con gradiente brand
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        justSucceeded
                        ? AnyShapeStyle(Color.green.gradient)
                        : AnyShapeStyle(BrandColor.heroGradient)
                    )
                    .frame(width: 44, height: 44)

                if isExecuting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else if justSucceeded {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.body.weight(.bold))
                } else {
                    Image(systemName: iconOverrides.effectiveIcon(for: scene))
                        .foregroundStyle(.white)
                        .font(.body.weight(.semibold))
                }
            }
            .animation(.spring(response: 0.3), value: justSucceeded)

            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "azione") : String(localized: "count.action.plural", defaultValue: "azioni"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    // MARK: - Room filter bar

    private var roomFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                roomPill(label: String(localized: "filter.all.scenes", defaultValue: "Tutte"), roomID: nil)
                ForEach(scenesService.representedRooms, id: \.id) { room in
                    roomPill(label: room.name, roomID: room.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? AnyShapeStyle(BrandColor.heroGradient)
                              : AnyShapeStyle(.regularMaterial))
                )
        }
        .buttonStyle(.plain)
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

    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?

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

                if presentedAsSheet {
                    await MainActor.run { dismiss() }
                }
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
                await MainActor.run { executingSceneID = nil }
            }
        }
    }

}
