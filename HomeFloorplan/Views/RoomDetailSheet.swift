import SwiftUI
import HomeKit

/// Sheet dettaglio stanza: scene affiliate + accessori raggruppati per tipologia.
/// Presentato con .medium / .large da AllAccessoriesView quando si tappa il nome di una stanza.
struct RoomDetailSheet: View {

    let room: HMRoom

    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(\.dismiss) private var dismiss

    @State private var observedUUIDs: Set<UUID> = []
    @State private var sceneDetailTarget: SceneItem?
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?

    // MARK: - Computed

    private var roomAccessories: [HMAccessory] {
        homeKit.allAccessories
            .filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var roomScenes: [SceneItem] {
        scenesService.scenes.filter { $0.affiliatedRoomIDs.contains(room.uniqueIdentifier) }
    }

    /// Accessori raggruppati per categoria, nell'ordine di AccessoryCategory.allCases.
    private var accessoriesByCategory: [(category: AccessoryCategory, accessories: [HMAccessory])] {
        let grouped = Dictionary(grouping: roomAccessories) { acc -> AccessoryCategory in
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            return AccessoryCategory.classify(adapter: adapter)
        }
        return AccessoryCategory.allCases.compactMap { cat in
            guard let accs = grouped[cat], !accs.isEmpty else { return nil }
            return (category: cat, accessories: accs)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Sezione scene (solo se presenti)
                    if !roomScenes.isEmpty {
                        scenesSection
                    }

                    // Sezioni accessori per categoria
                    if accessoriesByCategory.isEmpty {
                        emptyState
                    } else {
                        ForEach(accessoriesByCategory, id: \.category) { group in
                            categorySection(group.category, accessories: group.accessories)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $sceneDetailTarget) { scene in
                SceneDetailSheet(scene: scene)
                    .presentationDetents([.large])
            }
        }
        .task {
            let uuids = Set(roomAccessories.map { $0.uniqueIdentifier })
            guard !uuids.isEmpty else { return }
            observedUUIDs = uuids
            homeKit.startObserving(accessoryUUIDs: uuids)
            // Refresh scene per avere affiliazioni aggiornate
            scenesService.refresh()
        }
        .onDisappear {
            if !observedUUIDs.isEmpty {
                homeKit.stopObserving(accessoryUUIDs: observedUUIDs)
                observedUUIDs = []
            }
        }
    }

    // MARK: - Scene section

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "scenes.title", defaultValue: "Scenes"), systemImage: "wand.and.sparkles")
                .font(.headline)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(roomScenes) { scene in
                        sceneTile(scene)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func sceneTile(_ scene: SceneItem) -> some View {
        let isExecuting = executingSceneID == scene.id
        let justSucceeded = recentlySucceededID == scene.id

        return Button {
            runScene(scene)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
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

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)

                    Text(scene.actionCount == 1
                         ? String(localized: "roomDetail.sceneActionCount.one", defaultValue: "1 action")
                         : String(localized: "roomDetail.sceneActionCount.many", defaultValue: "\(scene.actionCount) actions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(minWidth: 130, maxWidth: 130, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            )
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

    // MARK: - Category section

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]
    }

    private func categorySection(_ category: AccessoryCategory, accessories: [HMAccessory]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header categoria
            HStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .foregroundStyle(BrandColor.primary)
                    .font(.subheadline)
                Text(category.displayName)
                    .font(.headline)
                Spacer()
                Text("\(accessories.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Tile grid stile Apple Home
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                    NavigationLink {
                        AccessoryDetailView(accessory: accessory)
                    } label: {
                        accessoryTile(accessory)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func accessoryTile(_ accessory: HMAccessory) -> some View {
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
        let appearance = AccessoryAppearance.from(adapter)
        let urgency = appearance.urgency
        let isOffline = homeKit.isLikelyOffline(accessory)

        return VStack(alignment: .leading, spacing: 8) {
            // Icona + badge offline in alto
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appearance.statusColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    AccessoryIconView(iconName: iconName)
                        .foregroundStyle(appearance.statusColor)
                        .frame(width: 20, height: 20)
                }

                if isOffline {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                        .offset(x: 4, y: -4)
                }
            }

            Spacer(minLength: 0)

            // Testo
            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if let status = adapter.primaryStatusText, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let battery = adapter.batteryInfo {
                    BatteryBadgeView(info: battery)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            (urgency == .alarm || urgency == .warning)
                                ? appearance.statusColor.opacity(0.35)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "roomDetail.empty.title", defaultValue: "No accessories"), systemImage: "house")
        } description: {
            Text(String(localized: "roomDetail.empty.description", defaultValue: "This room has no accessories configured in HomeKit."))
        }
        .padding(.top, 40)
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
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
                await MainActor.run { executingSceneID = nil }
            }
        }
    }

    // MARK: - Button style

    private struct SceneTileButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                .opacity(configuration.isPressed ? 0.88 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
