import SwiftUI
import HomeKit
import SwiftData

// MARK: - AccessoryRoomDetailView

struct AccessoryRoomDetailView: View {

    let room: RoomAccessoryData

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(ActionExecutionService.self) private var actionExecutionService
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAccessory: HMAccessory?
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?
    @State private var usageStore: SceneUsageStore?
    @State private var isReorderingSections = false

    /// Ordine sezioni persistito in UserDefaults (raw value CSV).
    @AppStorage("roomDetailSectionOrder") private var sectionOrderRaw: String = ""

    /// Tutte le sezioni riordinabili (ordine di default).
    private let reorderableSections: [AccessoryCategory] = [
        .lights, .outlets, .climate, .television, .sensors, .security, .cameras, .switches, .buttons
    ]

    /// Solo le sezioni che hanno almeno un accessorio in questa stanza.
    @MainActor
    private var presentSections: [AccessoryCategory] {
        reorderableSections.filter { !accessories(in: $0).isEmpty }
    }

    /// Sezioni nell'ordine salvato; le nuove categorie vengono aggiunte in coda.
    private var orderedSections: [AccessoryCategory] {
        let stored = sectionOrderRaw
            .split(separator: ",")
            .compactMap { AccessoryCategory(rawValue: String($0)) }
        let storedSet = Set(stored)
        let missing = reorderableSections.filter { !storedSet.contains($0) }
        return stored.filter { reorderableSections.contains($0) } + missing
    }

    // MARK: - Scene helpers

    private var roomScenes: [SceneItem] {
        let filtered = scenesService.scenes.filter { $0.affiliatedRoomIDs.contains(room.id) }
        guard let store = usageStore else {
            return filtered.sorted { $0.displayPriority < $1.displayPriority }
        }
        let suggestedIDs = Set(store.suggestedScenes(from: filtered).map { $0.scene.id })
        return filtered.sorted { a, b in
            let aSuggested = suggestedIDs.contains(a.id)
            let bSuggested = suggestedIDs.contains(b.id)
            if aSuggested != bSuggested { return aSuggested }
            return a.displayPriority < b.displayPriority
        }
    }

    private var suggestedSceneIDs: Set<UUID> {
        guard let store = usageStore else { return [] }
        return Set(store.suggestedScenes(from: roomScenes).map { $0.scene.id })
    }

    /// Dimmable or color lights in this room, used to decide whether to show the lighting strip.
    private var lightingAccessories: [HMAccessory] {
        room.accessories.filter {
            let cat = AccessoryCategorizer.categorize($0)
            return cat == "colorLight" || cat == "dimmableLight"
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── 1. Header stanza ───────────────────────────────────
                roomHeaderCard

                // ── 1b. Lighting quick-actions ─────────────────────────
                if !lightingAccessories.isEmpty {
                    LightingChipsStrip(
                        room: room,
                        homeKit: homeKit,
                        actionExecutionService: actionExecutionService
                    )
                }

                // ── 1c. Scene della stanza ────────────────────────────
                if !roomScenes.isEmpty {
                    RoomScenesStrip(
                        scenes: roomScenes,
                        suggestedIDs: suggestedSceneIDs,
                        roomID: room.id,
                        executingSceneID: $executingSceneID,
                        recentlySucceededID: $recentlySucceededID,
                        scenesService: scenesService
                    )
                }

                // ── 2…N. Sezioni riordinabili ─────────────────────────
                ForEach(orderedSections) { category in
                    let items = accessories(in: category)
                    if !items.isEmpty {
                        sectionCard(for: category, accessories: items)
                    }
                }

                // ── Ultimo. Altro — catch-all per categorie senza sezione
                let others = accessoriesNotInDedicatedSection
                if !others.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.other", defaultValue: "Other"),
                        symbol: "ellipsis.circle",
                        symbolColor: .secondary
                    ) {
                        ForEach(others, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle(room.roomName)
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isReorderingSections = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .onAppear {
            if usageStore == nil {
                let store = SceneUsageStore(modelContainer: modelContext.container)
                store.loadUsageData()
                usageStore = store
            }
        }
        .sheet(item: $selectedAccessory) { accessory in
            AccessoryDetailView(accessory: accessory)
        }
        .sheet(isPresented: $isReorderingSections) {
            SectionReorderSheet(
                sectionOrderRaw: $sectionOrderRaw,
                reorderableSections: presentSections
            )
        }
    }

    // MARK: - Room header card

    private var roomHeaderCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(room.healthLevel.color.opacity(0.18), lineWidth: 5)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: CGFloat(room.healthScore) / 100)
                    .stroke(room.healthLevel.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 52, height: 52)
                Text("\(room.healthScore)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(room.healthLevel.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(room.roomName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text(room.subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let issue = room.primaryIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Label(room.healthLevel.label, systemImage: room.healthLevel.sfSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(room.healthLevel.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(room.healthLevel.color.opacity(0.12), in: Capsule())
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Section rendering

    @ViewBuilder
    private func sectionCard(for category: AccessoryCategory, accessories items: [HMAccessory]) -> some View {
        DetailSectionCard(
            title: roomSectionTitle(category),
            symbol: roomSectionSymbol(category),
            symbolColor: roomSectionColor(category)
        ) {
            ForEach(items, id: \.uniqueIdentifier) { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                AccessoryDetailRow(
                    accessory: accessory,
                    adapter: adapter,
                    homeKit: homeKit,
                    iconOverrides: iconOverrides
                ) {
                    selectedAccessory = accessory
                }
            }
        }
    }

    // MARK: - Category filtering

    @MainActor
    private func accessories(in category: AccessoryCategory) -> [HMAccessory] {
        room.accessories(in: category, homeKit: homeKit)
    }

    /// Accessori non catturati da nessuna sezione dedicata.
    /// Cattura: tende, hub, aria, e qualsiasi categoria senza sezione propria.
    @MainActor
    private var accessoriesNotInDedicatedSection: [HMAccessory] {
        let dedicated: Set<AccessoryCategory> = [
            .lights, .outlets, .climate, .television, .sensors, .security, .cameras, .switches, .buttons
        ]
        return room.accessories.filter { accessory in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            return !dedicated.contains(AccessoryCategory.classify(adapter: adapter))
        }
    }
}

// MARK: - Section metadata (file-private helpers)

private func roomSectionTitle(_ category: AccessoryCategory) -> String {
    switch category {
    case .lights:     return String(localized: "accessories.section.lights",     defaultValue: "Lights")
    case .outlets:    return String(localized: "accessories.section.outlets",    defaultValue: "Outlets")
    case .climate:    return String(localized: "accessories.section.climate",    defaultValue: "Climate")
    case .television: return String(localized: "accessories.section.television", defaultValue: "TV")
    case .sensors:    return String(localized: "accessories.section.sensors",    defaultValue: "Sensors")
    case .security:   return String(localized: "accessories.section.security",   defaultValue: "Security")
    case .cameras:    return String(localized: "accessories.section.cameras",    defaultValue: "Cameras")
    case .switches:   return String(localized: "accessories.section.switches",   defaultValue: "Switch")
    case .buttons:    return String(localized: "accessories.section.buttons",    defaultValue: "Buttons")
    default:          return category.displayName
    }
}

private func roomSectionSymbol(_ category: AccessoryCategory) -> String {
    switch category {
    case .lights:     return "lightbulb.fill"
    case .outlets:    return "powerplug.fill"
    case .climate:    return "thermometer.medium"
    case .television: return "tv"
    case .sensors:    return "sensor.tag.radiowaves.forward"
    case .security:   return "lock.shield.fill"
    case .cameras:    return "camera.fill"
    case .switches:   return "lightswitch.on"
    case .buttons:    return "button.programmable"
    default:          return category.symbolName
    }
}

private func roomSectionColor(_ category: AccessoryCategory) -> Color {
    switch category {
    case .lights:     return .yellow
    case .outlets:    return .orange
    case .climate:    return .cyan
    case .television: return .indigo
    case .sensors:    return .green
    case .security:   return .red
    case .cameras:    return .gray
    case .switches:   return .teal
    case .buttons:    return .purple
    default:          return .secondary
    }
}

// MARK: - SectionReorderSheet

private struct SectionReorderSheet: View {

    @Binding var sectionOrderRaw: String
    let reorderableSections: [AccessoryCategory]
    @Environment(\.dismiss) private var dismiss

    @State private var localSections: [AccessoryCategory] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(localSections) { category in
                        HStack(spacing: 12) {
                            Image(systemName: roomSectionSymbol(category))
                                .foregroundStyle(roomSectionColor(category))
                                .frame(width: 22)
                            Text(roomSectionTitle(category))
                                .font(.body)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { from, to in
                        localSections.move(fromOffsets: from, toOffset: to)
                    }
                } footer: {
                    Text(String(
                        localized: "accessories.reorder.sections.footer",
                        defaultValue: "The \"Other\" section is always shown last."
                    ))
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(
                localized: "accessories.reorder.sections.title",
                defaultValue: "Reorder Sections"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "accessories.reorder.reset", defaultValue: "Reset")) {
                        sectionOrderRaw = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "accessories.reorder.done", defaultValue: "Done")) {
                        sectionOrderRaw = localSections.map(\.rawValue).joined(separator: ",")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            let stored = sectionOrderRaw
                .split(separator: ",")
                .compactMap { AccessoryCategory(rawValue: String($0)) }
            let storedSet = Set(stored)
            let missing = reorderableSections.filter { !storedSet.contains($0) }
            localSections = stored.filter { reorderableSections.contains($0) } + missing
        }
    }
}

// MARK: - RoomScenesStrip

private struct RoomScenesStrip: View {

    let scenes: [SceneItem]
    let suggestedIDs: Set<UUID>
    let roomID: UUID
    @Binding var executingSceneID: UUID?
    @Binding var recentlySucceededID: UUID?
    let scenesService: HomeKitScenesService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 20)
                Text("Scene")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(scenes.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(scenes) { scene in
                        SceneRoomCard(
                            scene: scene,
                            isSuggested: suggestedIDs.contains(scene.id),
                            isExecuting: executingSceneID == scene.id,
                            didSucceed: recentlySucceededID == scene.id
                        ) {
                            runScene(scene)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runScene(_ scene: SceneItem) {
        guard executingSceneID == nil else { return }
        executingSceneID = scene.id
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        Task {
            do {
                try await scenesService.run(scene)
                recentlySucceededID = scene.id
                let notify = UINotificationFeedbackGenerator()
                notify.notificationOccurred(.success)
                try? await Task.sleep(for: .seconds(1.5))
                recentlySucceededID = nil
            } catch {
                // Nessun feedback visivo di errore: non blocchiamo l'UI
            }
            executingSceneID = nil
        }
    }
}

// MARK: - SceneRoomCard

private struct SceneRoomCard: View {

    let scene: SceneItem
    let isSuggested: Bool
    let isExecuting: Bool
    let didSucceed: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(didSucceed
                              ? LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .topLeading, endPoint: .bottomTrailing)
                              : BrandColor.heroGradient)
                        .frame(width: 44, height: 44)
                    if isExecuting {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                            .frame(width: 44, height: 44)
                    } else if didSucceed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: scene.symbolName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    if isSuggested && !isExecuting && !didSucceed {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(3)
                            .background(Color.black.opacity(0.35), in: Circle())
                            .offset(x: -4, y: -4)
                    }
                }

                Spacer()

                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isExecuting || didSucceed ? .secondary : Color.orange)
                }
                .buttonStyle(.plain)
                .disabled(isExecuting || didSucceed)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(scene.actionCount == 1
                     ? String(localized: "count.action.singular", defaultValue: "1 action")
                     : String(localized: "count.action.plural", defaultValue: "\(scene.actionCount) actions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(width: 160, height: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSuggested
                        ? Color.orange.opacity(0.5)
                        : Color(uiColor: .separator).opacity(0.45),
                        lineWidth: isSuggested ? 1.5 : 1)
        )
        .opacity(isExecuting ? 0.65 : 1.0)
        .animation(.spring(response: 0.3), value: isExecuting)
        .animation(.spring(response: 0.3), value: didSucceed)
    }
}

// MARK: - DetailSectionCard

private struct DetailSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 16)

            content()
                .padding(.vertical, 4)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - LightingChipsStrip

private struct LightingChipsStrip: View {

    let room: RoomAccessoryData
    let homeKit: HomeKitService
    let actionExecutionService: ActionExecutionService

    @State private var executingKey: String?

    private var bestColorLight: HMAccessory? {
        room.accessories.first { AccessoryCategorizer.categorize($0) == "colorLight" }
    }

    private var bestLight: HMAccessory? {
        bestColorLight
            ?? room.accessories.first { AccessoryCategorizer.categorize($0) == "dimmableLight" }
    }

    private var currentProfile: LightingContextAnalyzer.LightingProfile {
        LightingContextAnalyzer.profile(for: Calendar.current.component(.hour, from: Date()))
    }

    var body: some View {
        let profile = currentProfile
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 20)
                Text(profile.description)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(chips(profile: profile), id: \.key) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private struct LightingChip {
        let key: String
        let label: String
        let icon: String
        let actionType: String
        let value: Double?
    }

    private func chips(profile: LightingContextAnalyzer.LightingProfile) -> [LightingChip] {
        var result: [LightingChip] = []
        for intent in profile.preferredIntents {
            switch intent {
            case .brightenRoom:
                result.append(LightingChip(
                    key: "brighten",
                    label: String(localized: "lighting.chip.brighten", defaultValue: "Brighten"),
                    icon: "sun.max.fill", actionType: "dim", value: 0.8
                ))
            case .dimRoom:
                result.append(LightingChip(
                    key: "dim",
                    label: String(localized: "lighting.chip.dim", defaultValue: "Dim"),
                    icon: "light.min", actionType: "dim", value: 0.25
                ))
            case .setCircadianLight where bestColorLight != nil:
                result.append(LightingChip(
                    key: "circadian",
                    label: String(localized: "lighting.chip.circadian", defaultValue: "Evening Light"),
                    icon: "sun.min.fill", actionType: "dim", value: 0.35
                ))
            default:
                break
            }
        }
        result.append(LightingChip(
            key: "off",
            label: String(localized: "lighting.chip.off", defaultValue: "Turn Off"),
            icon: "moon.fill", actionType: "off", value: nil
        ))
        return result
    }

    @ViewBuilder
    private func chipButton(_ chip: LightingChip) -> some View {
        let isExecuting = executingKey == chip.key
        let isDisabled  = isExecuting || bestLight == nil || homeKit.currentHome == nil

        Button {
            guard let light = bestLight, let home = homeKit.currentHome else { return }
            executingKey = chip.key
            Task {
                let action = AINextAction(
                    label:               chip.label,
                    actionType:          "executeNow",
                    accessoryID:         light.uniqueIdentifier.uuidString,
                    accessoryActionType: chip.actionType,
                    accessoryValue:      chip.value
                )
                await actionExecutionService.executeRaw(action, in: home)
                executingKey = nil
            }
        } label: {
            HStack(spacing: 6) {
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: chip.icon)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(chip.label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                isExecuting
                    ? Color.secondary.opacity(0.12)
                    : Color.yellow.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isDisabled ? .secondary : .primary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.spring(response: 0.25), value: isExecuting)
    }
}

// MARK: - AccessoryDetailRow

private struct AccessoryDetailRow: View {

    let accessory: HMAccessory
    let adapter: any AccessoryAdapter
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {

                let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
                let appearance = AccessoryAppearance.from(adapter)
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(appearance.statusColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(appearance.statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(accessory.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let status = adapter.primaryStatusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !homeKit.isReachable(accessory) {
                        Text(String(localized: "accessories.row.offline", defaultValue: "Unreachable"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if !homeKit.isReachable(accessory) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)

        Divider()
            .padding(.horizontal, 16)
    }
}
