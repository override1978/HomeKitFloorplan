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
    @State private var editorOpen: Bool = false
    @State private var renameError: String?
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: scene)
    }
    
    private var groupedByRoom: [(roomID: UUID, roomName: String, actions: [SceneActionSummary])] {
        let summaries = scene.actionSummaries
        let grouped = Dictionary(grouping: summaries, by: { $0.roomID })
        return grouped.map { (roomID, actions) in
            let roomName = actions.first?.roomName ?? String(localized: "scene.detail.noRoom", defaultValue: "No room")
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
                            String(localized: "scene.detail.noActions.title", defaultValue: "No actions"),
                            systemImage: "list.bullet.rectangle",
                            description: Text(String(localized: "scene.detail.noActions.description", defaultValue: "This scene has no associated actions. You can configure it in the Apple Home app."))
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
            .navigationTitle(String(localized: "scene.detail.navigationTitle", defaultValue: "Scene"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !scene.isBuiltIn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "common.edit", defaultValue: "Edit")) {
                            commitRename()
                            editorOpen = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
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
            .sheet(isPresented: $editorOpen) {
                SceneEditorSheet(scene: scene)
                    .presentationDetents([.large])
            }
            .alert(String(localized: "alert.error.title", defaultValue: "Error"),
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
                    TextField(String(localized: "scene.detail.namePlaceholder", defaultValue: "Scene name"), text: $editedName)
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
                
                Text(scene.actionCount == 1
                     ? String(localized: "count.action.singular", defaultValue: "1 action")
                     : String(localized: "count.action.plural", defaultValue: "\(scene.actionCount) actions"))
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
                    renameError = "\(String(localized: "scene.detail.renameError.prefix", defaultValue: "Could not rename")): \(error.localizedDescription)"
                    editedName = scene.name
                } else {
                    // Refresh per propagare il nuovo nome alla lista
                    scenesService.refresh()
                }
            }
        }
    }
}

struct SceneEditorSheet: View {
    let scene: SceneItem?

    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var drafts: [SceneLightActionDraft] = []
    @State private var outletDrafts: [SceneOutletActionDraft] = []
    @State private var switchDrafts: [SceneSwitchActionDraft] = []
    @State private var windowCoveringDrafts: [SceneWindowCoveringActionDraft] = []
    @State private var thermostatDrafts: [SceneThermostatActionDraft] = []
    @State private var airPurifierDrafts: [SceneAirPurifierActionDraft] = []
    @State private var humidifierDrafts: [SceneHumidifierActionDraft] = []
    @State private var securitySystemDrafts: [SceneSecuritySystemActionDraft] = []
    @State private var doorLockDrafts: [SceneDoorLockActionDraft] = []
    @State private var garageDoorDrafts: [SceneGarageDoorActionDraft] = []
    @State private var selectedAccessoryFilter: SceneEditorAccessoryFilter = .all
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var isEditing: Bool { scene != nil }
    private var selectedCount: Int {
        drafts.filter(\.isIncluded).count +
        outletDrafts.filter(\.isIncluded).count +
        switchDrafts.filter(\.isIncluded).count +
        windowCoveringDrafts.filter(\.isIncluded).count +
        thermostatDrafts.filter(\.isIncluded).count +
        airPurifierDrafts.filter(\.isIncluded).count +
        humidifierDrafts.filter(\.isIncluded).count +
        securitySystemDrafts.filter(\.isIncluded).count +
        doorLockDrafts.filter(\.isIncluded).count +
        garageDoorDrafts.filter(\.isIncluded).count
    }
    private var roomGroups: [SceneEditorRoomGroup] {
        let roomNames = Set(drafts.map(\.roomName))
            .union(outletDrafts.map(\.roomName))
            .union(switchDrafts.map(\.roomName))
            .union(windowCoveringDrafts.map(\.roomName))
            .union(thermostatDrafts.map(\.roomName))
            .union(airPurifierDrafts.map(\.roomName))
            .union(humidifierDrafts.map(\.roomName))
            .union(securitySystemDrafts.map(\.roomName))
            .union(doorLockDrafts.map(\.roomName))
            .union(garageDoorDrafts.map(\.roomName))
        return roomNames
            .map { roomName in
                SceneEditorRoomGroup(
                    roomName: roomName,
                    lightIndices: drafts.indices
                        .filter { drafts[$0].roomName == roomName }
                        .sorted { drafts[$0].accessoryName.localizedCaseInsensitiveCompare(drafts[$1].accessoryName) == .orderedAscending },
                    outletIndices: outletDrafts.indices
                        .filter { outletDrafts[$0].roomName == roomName }
                        .sorted { outletDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(outletDrafts[$1].accessoryName) == .orderedAscending },
                    switchIndices: switchDrafts.indices
                        .filter { switchDrafts[$0].roomName == roomName }
                        .sorted { switchDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(switchDrafts[$1].accessoryName) == .orderedAscending },
                    windowCoveringIndices: windowCoveringDrafts.indices
                        .filter { windowCoveringDrafts[$0].roomName == roomName }
                        .sorted { windowCoveringDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(windowCoveringDrafts[$1].accessoryName) == .orderedAscending },
                    thermostatIndices: thermostatDrafts.indices
                        .filter { thermostatDrafts[$0].roomName == roomName }
                        .sorted { thermostatDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(thermostatDrafts[$1].accessoryName) == .orderedAscending },
                    airPurifierIndices: airPurifierDrafts.indices
                        .filter { airPurifierDrafts[$0].roomName == roomName }
                        .sorted { airPurifierDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(airPurifierDrafts[$1].accessoryName) == .orderedAscending },
                    humidifierIndices: humidifierDrafts.indices
                        .filter { humidifierDrafts[$0].roomName == roomName }
                        .sorted { humidifierDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(humidifierDrafts[$1].accessoryName) == .orderedAscending },
                    securitySystemIndices: securitySystemDrafts.indices
                        .filter { securitySystemDrafts[$0].roomName == roomName }
                        .sorted { securitySystemDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(securitySystemDrafts[$1].accessoryName) == .orderedAscending },
                    doorLockIndices: doorLockDrafts.indices
                        .filter { doorLockDrafts[$0].roomName == roomName }
                        .sorted { doorLockDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(doorLockDrafts[$1].accessoryName) == .orderedAscending },
                    garageDoorIndices: garageDoorDrafts.indices
                        .filter { garageDoorDrafts[$0].roomName == roomName }
                        .sorted { garageDoorDrafts[$0].accessoryName.localizedCaseInsensitiveCompare(garageDoorDrafts[$1].accessoryName) == .orderedAscending }
                )
            }
            .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }
    private var filteredRoomGroups: [SceneEditorRoomGroup] {
        roomGroups.compactMap { group in
            let filtered = selectedAccessoryFilter == .selected
                ? selectedOnlyGroup(from: group)
                : group.filtered(for: selectedAccessoryFilter)
            return filtered.isEmpty ? nil : filtered
        }
    }
    private var availableAccessoryFilters: [SceneEditorAccessoryFilter] {
        let filters = SceneEditorAccessoryFilter.allCases.filter { filter in
            filter == .all || filter == .selected || count(for: filter) > 0
        }
        guard isEditing else { return filters.filter { $0 != .selected || count(for: .selected) > 0 } }
        return filters.sorted { lhs, rhs in
            if lhs == .selected { return true }
            if rhs == .selected { return false }
            return lhs.displayOrder < rhs.displayOrder
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        editorHero

                        if drafts.isEmpty && outletDrafts.isEmpty && switchDrafts.isEmpty && windowCoveringDrafts.isEmpty && thermostatDrafts.isEmpty && airPurifierDrafts.isEmpty && humidifierDrafts.isEmpty && securitySystemDrafts.isEmpty && doorLockDrafts.isEmpty && garageDoorDrafts.isEmpty {
                            ContentUnavailableView(
                                String(localized: "scene.editor.noDevices.title", defaultValue: "No compatible accessories"),
                                systemImage: "slider.horizontal.3",
                                description: Text(String(localized: "scene.editor.noDevices.description", defaultValue: "This editor supports dimmable lights, outlets, switches, window coverings, climate, air purifiers, diffusers, security systems, locks and garage doors. Other accessory types can still be managed from Apple Home."))
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                        } else {
                            accessoryFilterBar

                            ForEach(filteredRoomGroups) { group in
                                roomSection(group)
                            }
                        }

                        if isEditing {
                            deleteButton
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 98)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())

                bottomSaveBar
            }
            .navigationTitle(isEditing
                             ? String(localized: "scene.editor.title.edit", defaultValue: "Edit Scene")
                             : String(localized: "scene.editor.title.create", defaultValue: "New Scene"))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(String(localized: "scene.editor.delete.confirm.title", defaultValue: "Delete this scene?"),
                                isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible) {
                Button(String(localized: "scene.editor.delete.confirm.action", defaultValue: "Delete Scene"), role: .destructive) {
                    deleteScene()
                }
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "scene.editor.delete.confirm.message", defaultValue: "This removes the scene from HomeKit."))
            }
            .alert(String(localized: "alert.error.title", defaultValue: "Error"),
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                   ),
                   presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .onAppear {
                name = scene?.name ?? ""
                drafts = scenesService.lightActionDrafts(for: scene)
                outletDrafts = scenesService.outletActionDrafts(for: scene)
                switchDrafts = scenesService.switchActionDrafts(for: scene)
                windowCoveringDrafts = scenesService.windowCoveringActionDrafts(for: scene)
                thermostatDrafts = scenesService.thermostatActionDrafts(for: scene)
                airPurifierDrafts = scenesService.airPurifierActionDrafts(for: scene)
                humidifierDrafts = scenesService.humidifierActionDrafts(for: scene)
                securitySystemDrafts = scenesService.securitySystemActionDrafts(for: scene)
                doorLockDrafts = scenesService.doorLockActionDrafts(for: scene)
                garageDoorDrafts = scenesService.garageDoorActionDrafts(for: scene)
                selectedAccessoryFilter = scene == nil ? .all : .selected
            }
        }
    }

    private var editorHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BrandColor.heroGradient)
                        .frame(width: 58, height: 58)
                    Image(systemName: scene.map { SceneItem.inferIcon(from: $0.name) } ?? "wand.and.sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(isEditing
                         ? String(localized: "scene.editor.hero.edit", defaultValue: "Update scene")
                         : String(localized: "scene.editor.hero.create", defaultValue: "Build a scene"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    TextField(String(localized: "scene.editor.name.placeholder", defaultValue: "Scene name"), text: $name)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                heroMetric(
                    icon: "lightbulb.fill",
                    value: "\(selectedCount)",
                    label: String(localized: "scene.editor.metric.selected", defaultValue: "selected")
                )
                heroMetric(
                    icon: "slider.horizontal.3",
                    value: "\(drafts.count)",
                    label: String(localized: "scene.editor.metric.lights", defaultValue: "lights")
                )
                heroMetric(
                    icon: "powerplug.fill",
                    value: "\(outletDrafts.count)",
                    label: String(localized: "scene.editor.metric.outlets", defaultValue: "outlets")
                )
                heroMetric(
                    icon: "lightswitch.on.fill",
                    value: "\(switchDrafts.count)",
                    label: String(localized: "scene.editor.metric.switches", defaultValue: "switches")
                )
                heroMetric(
                    icon: "blinds.horizontal.open",
                    value: "\(windowCoveringDrafts.count)",
                    label: String(localized: "scene.editor.metric.windowCoverings", defaultValue: "blinds")
                )
                heroMetric(
                    icon: "thermometer.medium",
                    value: "\(thermostatDrafts.count)",
                    label: String(localized: "scene.editor.metric.climate", defaultValue: "climate")
                )
                heroMetric(
                    icon: "air.purifier.fill",
                    value: "\(airPurifierDrafts.count)",
                    label: String(localized: "scene.editor.metric.airPurifiers", defaultValue: "air")
                )
                heroMetric(
                    icon: "humidifier.fill",
                    value: "\(humidifierDrafts.count)",
                    label: String(localized: "scene.editor.metric.diffusers", defaultValue: "diffusers")
                )
                heroMetric(
                    icon: "shield.lefthalf.filled",
                    value: "\(count(for: .security))",
                    label: String(localized: "scene.editor.metric.security", defaultValue: "security")
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var accessoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableAccessoryFilters) { filter in
                    accessoryFilterPill(filter)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
    }

    private func accessoryFilterPill(_ filter: SceneEditorAccessoryFilter) -> some View {
        let isSelected = selectedAccessoryFilter == filter
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                selectedAccessoryFilter = filter
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: filter.symbolName)
                    .font(.caption.weight(.semibold))
                Text(filter.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count(for: filter))")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.white.opacity(0.20) : BrandColor.primary.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(isSelected ? .white : BrandColor.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(BrandColor.primary) : AnyShapeStyle(.regularMaterial))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : BrandColor.primary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func heroMetric(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(BrandColor.primary.opacity(0.10), in: Capsule())
    }

    private func count(for filter: SceneEditorAccessoryFilter) -> Int {
        switch filter {
        case .all:
            return drafts.count +
            outletDrafts.count +
            switchDrafts.count +
            windowCoveringDrafts.count +
            thermostatDrafts.count +
            airPurifierDrafts.count +
            humidifierDrafts.count +
            securitySystemDrafts.count +
            doorLockDrafts.count +
            garageDoorDrafts.count
        case .selected:
            return selectedCount
        case .lights:
            return drafts.count
        case .outlets:
            return outletDrafts.count
        case .switches:
            return switchDrafts.count
        case .windowCoverings:
            return windowCoveringDrafts.count
        case .climate:
            return thermostatDrafts.count
        case .air:
            return airPurifierDrafts.count + humidifierDrafts.count
        case .security:
            return securitySystemDrafts.count + doorLockDrafts.count + garageDoorDrafts.count
        }
    }

    private func selectedOnlyGroup(from group: SceneEditorRoomGroup) -> SceneEditorRoomGroup {
        SceneEditorRoomGroup(
            roomName: group.roomName,
            lightIndices: group.lightIndices.filter { drafts[$0].isIncluded },
            outletIndices: group.outletIndices.filter { outletDrafts[$0].isIncluded },
            switchIndices: group.switchIndices.filter { switchDrafts[$0].isIncluded },
            windowCoveringIndices: group.windowCoveringIndices.filter { windowCoveringDrafts[$0].isIncluded },
            thermostatIndices: group.thermostatIndices.filter { thermostatDrafts[$0].isIncluded },
            airPurifierIndices: group.airPurifierIndices.filter { airPurifierDrafts[$0].isIncluded },
            humidifierIndices: group.humidifierIndices.filter { humidifierDrafts[$0].isIncluded },
            securitySystemIndices: group.securitySystemIndices.filter { securitySystemDrafts[$0].isIncluded },
            doorLockIndices: group.doorLockIndices.filter { doorLockDrafts[$0].isIncluded },
            garageDoorIndices: group.garageDoorIndices.filter { garageDoorDrafts[$0].isIncluded }
        )
    }


    private func roomSection(_ group: SceneEditorRoomGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.roomName, systemImage: "square.split.bottomrightquarter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(selectedCount(in: group))/\(accessoryCount(in: group))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 10) {
                ForEach(group.lightIndices, id: \.self) { index in
                    SceneLightActionEditorRow(draft: $drafts[index])
                }

                ForEach(group.outletIndices, id: \.self) { index in
                    SceneOutletActionEditorRow(draft: $outletDrafts[index])
                }

                ForEach(group.switchIndices, id: \.self) { index in
                    SceneSwitchActionEditorRow(draft: $switchDrafts[index])
                }

                ForEach(group.windowCoveringIndices, id: \.self) { index in
                    SceneWindowCoveringActionEditorRow(draft: $windowCoveringDrafts[index])
                }

                ForEach(group.thermostatIndices, id: \.self) { index in
                    SceneThermostatActionEditorRow(draft: $thermostatDrafts[index])
                }

                ForEach(group.airPurifierIndices, id: \.self) { index in
                    SceneAirPurifierActionEditorRow(draft: $airPurifierDrafts[index])
                }

                ForEach(group.humidifierIndices, id: \.self) { index in
                    SceneHumidifierActionEditorRow(draft: $humidifierDrafts[index])
                }

                ForEach(group.securitySystemIndices, id: \.self) { index in
                    SceneSecuritySystemActionEditorRow(draft: $securitySystemDrafts[index])
                }

                ForEach(group.doorLockIndices, id: \.self) { index in
                    SceneDoorLockActionEditorRow(draft: $doorLockDrafts[index])
                }

                ForEach(group.garageDoorIndices, id: \.self) { index in
                    SceneGarageDoorActionEditorRow(draft: $garageDoorDrafts[index])
                }
            }
        }
    }

    private func selectedCount(in group: SceneEditorRoomGroup) -> Int {
        group.lightIndices.filter { drafts[$0].isIncluded }.count +
        group.outletIndices.filter { outletDrafts[$0].isIncluded }.count +
        group.switchIndices.filter { switchDrafts[$0].isIncluded }.count +
        group.windowCoveringIndices.filter { windowCoveringDrafts[$0].isIncluded }.count +
        group.thermostatIndices.filter { thermostatDrafts[$0].isIncluded }.count +
        group.airPurifierIndices.filter { airPurifierDrafts[$0].isIncluded }.count +
        group.humidifierIndices.filter { humidifierDrafts[$0].isIncluded }.count +
        group.securitySystemIndices.filter { securitySystemDrafts[$0].isIncluded }.count +
        group.doorLockIndices.filter { doorLockDrafts[$0].isIncluded }.count +
        group.garageDoorIndices.filter { garageDoorDrafts[$0].isIncluded }.count
    }

    private func accessoryCount(in group: SceneEditorRoomGroup) -> Int {
        group.lightIndices.count +
        group.outletIndices.count +
        group.switchIndices.count +
        group.windowCoveringIndices.count +
        group.thermostatIndices.count +
        group.airPurifierIndices.count +
        group.humidifierIndices.count +
        group.securitySystemIndices.count +
        group.doorLockIndices.count +
        group.garageDoorIndices.count
    }

    private var bottomSaveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(BrandColor.primary)
                .disabled(isSaving)

                Button {
                    save()
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isEditing
                             ? String(localized: "scene.editor.save.update", defaultValue: "Update Scene")
                             : String(localized: "scene.editor.save.create", defaultValue: "Create Scene"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)
                .disabled(!canSave || isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label(String(localized: "scene.editor.delete", defaultValue: "Delete Scene"), systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .padding(.top, 6)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCount > 0
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            do {
                _ = try await scenesService.saveUserScene(
                    name: name,
                    drafts: drafts,
                    outletDrafts: outletDrafts,
                    switchDrafts: switchDrafts,
                    windowCoveringDrafts: windowCoveringDrafts,
                    thermostatDrafts: thermostatDrafts,
                    airPurifierDrafts: airPurifierDrafts,
                    humidifierDrafts: humidifierDrafts,
                    securitySystemDrafts: securitySystemDrafts,
                    doorLockDrafts: doorLockDrafts,
                    garageDoorDrafts: garageDoorDrafts,
                    editing: scene
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isSaving = false
        }
    }

    private func deleteScene() {
        guard let scene else { return }
        isSaving = true
        Task {
            do {
                try await scenesService.deleteUserScene(scene)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isSaving = false
        }
    }
}

struct SceneActionDraftEditorSheet: View {
    @Binding var actionBundle: SceneActionDraftBundle
    let title: String
    let subtitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccessoryFilter: SceneEditorAccessoryFilter = .all

    init(
        actionBundle: Binding<SceneActionDraftBundle>,
        title: String,
        subtitle: String,
        startWithSelectedFilter: Bool = false
    ) {
        self._actionBundle = actionBundle
        self.title = title
        self.subtitle = subtitle
        self._selectedAccessoryFilter = State(initialValue: startWithSelectedFilter ? .selected : .all)
    }

    private var roomGroups: [SceneEditorRoomGroup] {
        let roomNames = Set(actionBundle.lightDrafts.map(\.roomName))
            .union(actionBundle.outletDrafts.map(\.roomName))
            .union(actionBundle.switchDrafts.map(\.roomName))
            .union(actionBundle.windowCoveringDrafts.map(\.roomName))
            .union(actionBundle.thermostatDrafts.map(\.roomName))
            .union(actionBundle.airPurifierDrafts.map(\.roomName))
            .union(actionBundle.humidifierDrafts.map(\.roomName))
            .union(actionBundle.securitySystemDrafts.map(\.roomName))
            .union(actionBundle.doorLockDrafts.map(\.roomName))
            .union(actionBundle.garageDoorDrafts.map(\.roomName))

        return roomNames.map { roomName in
            SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: sortedIndices(actionBundle.lightDrafts, roomName: roomName),
                outletIndices: sortedIndices(actionBundle.outletDrafts, roomName: roomName),
                switchIndices: sortedIndices(actionBundle.switchDrafts, roomName: roomName),
                windowCoveringIndices: sortedIndices(actionBundle.windowCoveringDrafts, roomName: roomName),
                thermostatIndices: sortedIndices(actionBundle.thermostatDrafts, roomName: roomName),
                airPurifierIndices: sortedIndices(actionBundle.airPurifierDrafts, roomName: roomName),
                humidifierIndices: sortedIndices(actionBundle.humidifierDrafts, roomName: roomName),
                securitySystemIndices: sortedIndices(actionBundle.securitySystemDrafts, roomName: roomName),
                doorLockIndices: sortedIndices(actionBundle.doorLockDrafts, roomName: roomName),
                garageDoorIndices: sortedIndices(actionBundle.garageDoorDrafts, roomName: roomName)
            )
        }
        .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }

    private var filteredRoomGroups: [SceneEditorRoomGroup] {
        roomGroups.compactMap { group in
            let filtered = selectedAccessoryFilter == .selected
                ? selectedOnlyGroup(from: group)
                : group.filtered(for: selectedAccessoryFilter)
            return filtered.isEmpty ? nil : filtered
        }
    }

    private var availableAccessoryFilters: [SceneEditorAccessoryFilter] {
        SceneEditorAccessoryFilter.allCases.filter { filter in
            filter == .all || filter == .selected || count(for: filter) > 0
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    accessoryFilterBar

                    if filteredRoomGroups.isEmpty {
                        ContentUnavailableView(
                            String(localized: "scene.editor.noDevices.title", defaultValue: "No compatible accessories"),
                            systemImage: "slider.horizontal.3",
                            description: Text(String(localized: "scene.editor.noDevices.description", defaultValue: "This editor supports dimmable lights, outlets, switches, window coverings, climate, air purifiers, diffusers, security systems, locks and garage doors. Other accessory types can still be managed from Apple Home."))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                    } else {
                        ForEach(filteredRoomGroups) { group in
                            roomSection(group)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(String(localized: "automation.wizard.action.title", defaultValue: "Choose an accessory action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var accessoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableAccessoryFilters) { filter in
                    accessoryFilterPill(filter)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
    }

    private func accessoryFilterPill(_ filter: SceneEditorAccessoryFilter) -> some View {
        let isSelected = selectedAccessoryFilter == filter
        return Button {
            selectedAccessoryFilter = filter
        } label: {
            HStack(spacing: 7) {
                Image(systemName: filter.symbolName)
                    .font(.caption.weight(.semibold))
                Text(filter.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count(for: filter))")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.white.opacity(0.20) : BrandColor.primary.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(isSelected ? .white : BrandColor.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(BrandColor.primary) : AnyShapeStyle(.regularMaterial))
            )
        }
        .buttonStyle(.plain)
    }

    private func roomSection(_ group: SceneEditorRoomGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.roomName, systemImage: "square.split.bottomrightquarter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(selectedCount(in: group))/\(accessoryCount(in: group))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 12) {
                ForEach(accessoryGroups(in: group)) { accessoryGroup in
                    accessoryGroupSection(accessoryGroup)
                }
            }
        }
    }

    private func accessoryGroupSection(_ group: SceneEditorAccessoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if group.actionCount > 1 {
                HStack(spacing: 8) {
                    Text(group.accessoryName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(String(format: String(localized: "scene.editor.accessoryGroup.actionsCount",
                                               defaultValue: "%d actions"),
                                group.actionCount))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .padding(.horizontal, 4)
            }

            ForEach(group.lightIndices, id: \.self) { index in
                SceneLightActionEditorRow(draft: $actionBundle.lightDrafts[index])
            }
            ForEach(group.outletIndices, id: \.self) { index in
                SceneOutletActionEditorRow(draft: $actionBundle.outletDrafts[index])
            }
            ForEach(group.switchIndices, id: \.self) { index in
                SceneSwitchActionEditorRow(draft: $actionBundle.switchDrafts[index])
            }
            ForEach(group.windowCoveringIndices, id: \.self) { index in
                SceneWindowCoveringActionEditorRow(draft: $actionBundle.windowCoveringDrafts[index])
            }
            ForEach(group.thermostatIndices, id: \.self) { index in
                SceneThermostatActionEditorRow(draft: $actionBundle.thermostatDrafts[index])
            }
            ForEach(group.airPurifierIndices, id: \.self) { index in
                SceneAirPurifierActionEditorRow(draft: $actionBundle.airPurifierDrafts[index])
            }
            ForEach(group.humidifierIndices, id: \.self) { index in
                SceneHumidifierActionEditorRow(draft: $actionBundle.humidifierDrafts[index])
            }
            ForEach(group.securitySystemIndices, id: \.self) { index in
                SceneSecuritySystemActionEditorRow(draft: $actionBundle.securitySystemDrafts[index])
            }
            ForEach(group.doorLockIndices, id: \.self) { index in
                SceneDoorLockActionEditorRow(draft: $actionBundle.doorLockDrafts[index])
            }
            ForEach(group.garageDoorIndices, id: \.self) { index in
                SceneGarageDoorActionEditorRow(draft: $actionBundle.garageDoorDrafts[index])
            }
        }
        .padding(group.actionCount > 1 ? 10 : 0)
        .background {
            if group.actionCount > 1 {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .overlay {
            if group.actionCount > 1 {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
    }

    private func count(for filter: SceneEditorAccessoryFilter) -> Int {
        switch filter {
        case .all:
            return actionBundle.lightDrafts.count +
            actionBundle.outletDrafts.count +
            actionBundle.switchDrafts.count +
            actionBundle.windowCoveringDrafts.count +
            actionBundle.thermostatDrafts.count +
            actionBundle.airPurifierDrafts.count +
            actionBundle.humidifierDrafts.count +
            actionBundle.securitySystemDrafts.count +
            actionBundle.doorLockDrafts.count +
            actionBundle.garageDoorDrafts.count
        case .selected:
            return actionBundle.selectedCount
        case .lights:
            return actionBundle.lightDrafts.count
        case .outlets:
            return actionBundle.outletDrafts.count
        case .switches:
            return actionBundle.switchDrafts.count
        case .windowCoverings:
            return actionBundle.windowCoveringDrafts.count
        case .climate:
            return actionBundle.thermostatDrafts.count
        case .air:
            return actionBundle.airPurifierDrafts.count + actionBundle.humidifierDrafts.count
        case .security:
            return actionBundle.securitySystemDrafts.count + actionBundle.doorLockDrafts.count + actionBundle.garageDoorDrafts.count
        }
    }

    private func selectedOnlyGroup(from group: SceneEditorRoomGroup) -> SceneEditorRoomGroup {
        SceneEditorRoomGroup(
            roomName: group.roomName,
            lightIndices: group.lightIndices.filter { actionBundle.lightDrafts[$0].isIncluded },
            outletIndices: group.outletIndices.filter { actionBundle.outletDrafts[$0].isIncluded },
            switchIndices: group.switchIndices.filter { actionBundle.switchDrafts[$0].isIncluded },
            windowCoveringIndices: group.windowCoveringIndices.filter { actionBundle.windowCoveringDrafts[$0].isIncluded },
            thermostatIndices: group.thermostatIndices.filter { actionBundle.thermostatDrafts[$0].isIncluded },
            airPurifierIndices: group.airPurifierIndices.filter { actionBundle.airPurifierDrafts[$0].isIncluded },
            humidifierIndices: group.humidifierIndices.filter { actionBundle.humidifierDrafts[$0].isIncluded },
            securitySystemIndices: group.securitySystemIndices.filter { actionBundle.securitySystemDrafts[$0].isIncluded },
            doorLockIndices: group.doorLockIndices.filter { actionBundle.doorLockDrafts[$0].isIncluded },
            garageDoorIndices: group.garageDoorIndices.filter { actionBundle.garageDoorDrafts[$0].isIncluded }
        )
    }

    private func selectedCount(in group: SceneEditorRoomGroup) -> Int {
        group.lightIndices.filter { actionBundle.lightDrafts[$0].isIncluded }.count +
        group.outletIndices.filter { actionBundle.outletDrafts[$0].isIncluded }.count +
        group.switchIndices.filter { actionBundle.switchDrafts[$0].isIncluded }.count +
        group.windowCoveringIndices.filter { actionBundle.windowCoveringDrafts[$0].isIncluded }.count +
        group.thermostatIndices.filter { actionBundle.thermostatDrafts[$0].isIncluded }.count +
        group.airPurifierIndices.filter { actionBundle.airPurifierDrafts[$0].isIncluded }.count +
        group.humidifierIndices.filter { actionBundle.humidifierDrafts[$0].isIncluded }.count +
        group.securitySystemIndices.filter { actionBundle.securitySystemDrafts[$0].isIncluded }.count +
        group.doorLockIndices.filter { actionBundle.doorLockDrafts[$0].isIncluded }.count +
        group.garageDoorIndices.filter { actionBundle.garageDoorDrafts[$0].isIncluded }.count
    }

    private func accessoryCount(in group: SceneEditorRoomGroup) -> Int {
        group.lightIndices.count +
        group.outletIndices.count +
        group.switchIndices.count +
        group.windowCoveringIndices.count +
        group.thermostatIndices.count +
        group.airPurifierIndices.count +
        group.humidifierIndices.count +
        group.securitySystemIndices.count +
        group.doorLockIndices.count +
        group.garageDoorIndices.count
    }

    private func accessoryGroups(in group: SceneEditorRoomGroup) -> [SceneEditorAccessoryGroup] {
        var groupsByID: [UUID: SceneEditorAccessoryGroup] = [:]

        for index in group.lightIndices {
            append(index, kind: .light, draft: actionBundle.lightDrafts[index], to: &groupsByID)
        }
        for index in group.outletIndices {
            append(index, kind: .outlet, draft: actionBundle.outletDrafts[index], to: &groupsByID)
        }
        for index in group.switchIndices {
            append(index, kind: .switch, draft: actionBundle.switchDrafts[index], to: &groupsByID)
        }
        for index in group.windowCoveringIndices {
            append(index, kind: .windowCovering, draft: actionBundle.windowCoveringDrafts[index], to: &groupsByID)
        }
        for index in group.thermostatIndices {
            append(index, kind: .thermostat, draft: actionBundle.thermostatDrafts[index], to: &groupsByID)
        }
        for index in group.airPurifierIndices {
            append(index, kind: .airPurifier, draft: actionBundle.airPurifierDrafts[index], to: &groupsByID)
        }
        for index in group.humidifierIndices {
            append(index, kind: .humidifier, draft: actionBundle.humidifierDrafts[index], to: &groupsByID)
        }
        for index in group.securitySystemIndices {
            append(index, kind: .securitySystem, draft: actionBundle.securitySystemDrafts[index], to: &groupsByID)
        }
        for index in group.doorLockIndices {
            append(index, kind: .doorLock, draft: actionBundle.doorLockDrafts[index], to: &groupsByID)
        }
        for index in group.garageDoorIndices {
            append(index, kind: .garageDoor, draft: actionBundle.garageDoorDrafts[index], to: &groupsByID)
        }

        return groupsByID.values.sorted {
            if $0.accessoryName == $1.accessoryName {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    private func append<T: SceneActionDraftDisplayable>(
        _ index: Int,
        kind: SceneEditorActionKind,
        draft: T,
        to groupsByID: inout [UUID: SceneEditorAccessoryGroup]
    ) {
        let groupID = draft.accessoryGroupID
        var group = groupsByID[groupID] ?? SceneEditorAccessoryGroup(
            id: groupID,
            accessoryName: draft.accessoryName,
            lightIndices: [],
            outletIndices: [],
            switchIndices: [],
            windowCoveringIndices: [],
            thermostatIndices: [],
            airPurifierIndices: [],
            humidifierIndices: [],
            securitySystemIndices: [],
            doorLockIndices: [],
            garageDoorIndices: []
        )
        group.append(index, kind: kind)
        groupsByID[groupID] = group
    }

    private func sortedIndices<T>(_ drafts: [T], roomName: String) -> [Int] where T: SceneActionDraftDisplayable {
        drafts.indices
            .filter { drafts[$0].roomName == roomName }
            .sorted { drafts[$0].accessoryName.localizedCaseInsensitiveCompare(drafts[$1].accessoryName) == .orderedAscending }
    }
}

protocol SceneActionDraftDisplayable {
    var accessoryName: String { get }
    var roomName: String { get }
    var isIncluded: Bool { get set }
    var accessoryGroupID: UUID { get }
}

extension SceneLightActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { accessoryID }
}
extension SceneOutletActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { accessoryID }
}
extension SceneSwitchActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneWindowCoveringActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneThermostatActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneAirPurifierActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneHumidifierActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneSecuritySystemActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneDoorLockActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}
extension SceneGarageDoorActionDraft: SceneActionDraftDisplayable {
    var accessoryGroupID: UUID { id }
}

private enum SceneEditorActionKind {
    case light
    case outlet
    case `switch`
    case windowCovering
    case thermostat
    case airPurifier
    case humidifier
    case securitySystem
    case doorLock
    case garageDoor
}

private struct SceneEditorAccessoryGroup: Identifiable {
    let id: UUID
    let accessoryName: String
    var lightIndices: [Int]
    var outletIndices: [Int]
    var switchIndices: [Int]
    var windowCoveringIndices: [Int]
    var thermostatIndices: [Int]
    var airPurifierIndices: [Int]
    var humidifierIndices: [Int]
    var securitySystemIndices: [Int]
    var doorLockIndices: [Int]
    var garageDoorIndices: [Int]

    var actionCount: Int {
        lightIndices.count +
        outletIndices.count +
        switchIndices.count +
        windowCoveringIndices.count +
        thermostatIndices.count +
        airPurifierIndices.count +
        humidifierIndices.count +
        securitySystemIndices.count +
        doorLockIndices.count +
        garageDoorIndices.count
    }

    mutating func append(_ index: Int, kind: SceneEditorActionKind) {
        switch kind {
        case .light:
            lightIndices.append(index)
        case .outlet:
            outletIndices.append(index)
        case .switch:
            switchIndices.append(index)
        case .windowCovering:
            windowCoveringIndices.append(index)
        case .thermostat:
            thermostatIndices.append(index)
        case .airPurifier:
            airPurifierIndices.append(index)
        case .humidifier:
            humidifierIndices.append(index)
        case .securitySystem:
            securitySystemIndices.append(index)
        case .doorLock:
            doorLockIndices.append(index)
        case .garageDoor:
            garageDoorIndices.append(index)
        }
    }
}

private struct SceneEditorRoomGroup: Identifiable {
    let roomName: String
    let lightIndices: [Int]
    let outletIndices: [Int]
    let switchIndices: [Int]
    let windowCoveringIndices: [Int]
    let thermostatIndices: [Int]
    let airPurifierIndices: [Int]
    let humidifierIndices: [Int]
    let securitySystemIndices: [Int]
    let doorLockIndices: [Int]
    let garageDoorIndices: [Int]

    var id: String { roomName }

    var isEmpty: Bool {
        lightIndices.isEmpty &&
        outletIndices.isEmpty &&
        switchIndices.isEmpty &&
        windowCoveringIndices.isEmpty &&
        thermostatIndices.isEmpty &&
        airPurifierIndices.isEmpty &&
        humidifierIndices.isEmpty &&
        securitySystemIndices.isEmpty &&
        doorLockIndices.isEmpty &&
        garageDoorIndices.isEmpty
    }

    func filtered(for filter: SceneEditorAccessoryFilter) -> SceneEditorRoomGroup {
        switch filter {
        case .all, .selected:
            return self
        case .lights:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: lightIndices,
                outletIndices: [],
                switchIndices: [],
                windowCoveringIndices: [],
                thermostatIndices: [],
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .outlets:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: outletIndices,
                switchIndices: [],
                windowCoveringIndices: [],
                thermostatIndices: [],
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .switches:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: [],
                switchIndices: switchIndices,
                windowCoveringIndices: [],
                thermostatIndices: [],
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .windowCoverings:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: [],
                switchIndices: [],
                windowCoveringIndices: windowCoveringIndices,
                thermostatIndices: [],
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .climate:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: [],
                switchIndices: [],
                windowCoveringIndices: [],
                thermostatIndices: thermostatIndices,
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .air:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: [],
                switchIndices: [],
                windowCoveringIndices: [],
                thermostatIndices: [],
                airPurifierIndices: airPurifierIndices,
                humidifierIndices: humidifierIndices,
                securitySystemIndices: [],
                doorLockIndices: [],
                garageDoorIndices: []
            )
        case .security:
            return SceneEditorRoomGroup(
                roomName: roomName,
                lightIndices: [],
                outletIndices: [],
                switchIndices: [],
                windowCoveringIndices: [],
                thermostatIndices: [],
                airPurifierIndices: [],
                humidifierIndices: [],
                securitySystemIndices: securitySystemIndices,
                doorLockIndices: doorLockIndices,
                garageDoorIndices: garageDoorIndices
            )
        }
    }
}

private enum SceneEditorAccessoryFilter: CaseIterable, Identifiable {
    case all
    case selected
    case lights
    case outlets
    case switches
    case windowCoverings
    case climate
    case air
    case security

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return String(localized: "scene.editor.filter.all", defaultValue: "Tutti")
        case .selected:
            return String(localized: "scene.editor.filter.selected", defaultValue: "Selezionati")
        case .lights:
            return String(localized: "scene.editor.filter.lights", defaultValue: "Luci")
        case .outlets:
            return String(localized: "scene.editor.filter.outlets", defaultValue: "Prese")
        case .switches:
            return String(localized: "scene.editor.filter.switches", defaultValue: "Interruttori")
        case .windowCoverings:
            return String(localized: "scene.editor.filter.windowCoverings", defaultValue: "Tende")
        case .climate:
            return String(localized: "scene.editor.filter.climate", defaultValue: "Clima")
        case .air:
            return String(localized: "scene.editor.filter.air", defaultValue: "Aria")
        case .security:
            return String(localized: "scene.editor.filter.security", defaultValue: "Sicurezza")
        }
    }

    var symbolName: String {
        switch self {
        case .all:
            return "square.grid.2x2.fill"
        case .selected:
            return "checkmark.circle.fill"
        case .lights:
            return "lightbulb.fill"
        case .outlets:
            return "powerplug.fill"
        case .switches:
            return "lightswitch.on.fill"
        case .windowCoverings:
            return "blinds.horizontal.open"
        case .climate:
            return "thermometer.medium"
        case .air:
            return "air.purifier.fill"
        case .security:
            return "shield.lefthalf.filled"
        }
    }

    var displayOrder: Int {
        switch self {
        case .all: return 0
        case .selected: return 1
        case .lights: return 2
        case .outlets: return 3
        case .switches: return 4
        case .windowCoverings: return 5
        case .climate: return 6
        case .air: return 7
        case .security: return 8
        }
    }
}

private struct SceneDoorLockActionEditorRow: View {
    @Binding var draft: SceneDoorLockActionDraft

    private var accentColor: Color {
        guard draft.isIncluded else { return .secondary }
        return draft.locked ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessHeader(
                accessoryName: draft.accessoryName,
                iconName: draft.locked ? "lock.fill" : "lock.open.fill",
                statusText: statusText,
                accentColor: accentColor,
                isIncluded: draft.isIncluded,
                toggleIncluded: {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                }
            )

            if draft.isIncluded {
                HStack(spacing: 8) {
                    accessModeButton(
                        title: String(localized: "accessory.lock.unlock", defaultValue: "Unlock"),
                        iconName: "lock.open.fill",
                        tint: .orange,
                        isSelected: !draft.locked
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            draft.locked = false
                        }
                    }
                    accessModeButton(
                        title: String(localized: "accessory.lock.lock", defaultValue: "Lock"),
                        iconName: "lock.fill",
                        tint: .green,
                        isSelected: draft.locked
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            draft.locked = true
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(accessCardBackground(isIncluded: draft.isIncluded, accentColor: accentColor))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.locked)
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.lock.notIncluded", defaultValue: "Not in scene")
        }
        return draft.locked
            ? String(localized: "accessory.lock.lock", defaultValue: "Lock")
            : String(localized: "accessory.lock.unlock", defaultValue: "Unlock")
    }
}

private struct SceneGarageDoorActionEditorRow: View {
    @Binding var draft: SceneGarageDoorActionDraft

    private var accentColor: Color {
        guard draft.isIncluded else { return .secondary }
        return draft.open ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessHeader(
                accessoryName: draft.accessoryName,
                iconName: draft.open ? "door.garage.open" : "door.garage.closed",
                statusText: statusText,
                accentColor: accentColor,
                isIncluded: draft.isIncluded,
                toggleIncluded: {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                }
            )

            if draft.isIncluded {
                HStack(spacing: 8) {
                    accessModeButton(
                        title: String(localized: "accessory.door.open", defaultValue: "Open"),
                        iconName: "door.garage.open",
                        tint: .orange,
                        isSelected: draft.open
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            draft.open = true
                        }
                    }
                    accessModeButton(
                        title: String(localized: "accessory.door.close", defaultValue: "Close"),
                        iconName: "door.garage.closed",
                        tint: .green,
                        isSelected: !draft.open
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            draft.open = false
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(accessCardBackground(isIncluded: draft.isIncluded, accentColor: accentColor))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.open)
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.garage.notIncluded", defaultValue: "Not in scene")
        }
        return draft.open
            ? String(localized: "accessory.door.open", defaultValue: "Open")
            : String(localized: "accessory.door.close", defaultValue: "Close")
    }
}

private func accessHeader(
    accessoryName: String,
    iconName: String,
    statusText: String,
    accentColor: Color,
    isIncluded: Bool,
    toggleIncluded: @escaping () -> Void
) -> some View {
    HStack(spacing: 12) {
        Button(action: toggleIncluded) {
            ZStack {
                Circle()
                    .fill(isIncluded ? accentColor : Color(.tertiarySystemFill))
                    .frame(width: 34, height: 34)
                Image(systemName: isIncluded ? "checkmark" : "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isIncluded ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)

        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isIncluded ? accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                .frame(width: 40, height: 40)
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
        }

        VStack(alignment: .leading, spacing: 3) {
            Text(accessoryName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Spacer()
    }
}

private func accessModeButton(
    title: String,
    iconName: String,
    tint: Color,
    isSelected: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isSelected ? .white : tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.10)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.clear : tint.opacity(0.18), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
}

private func accessCardBackground(isIncluded: Bool, accentColor: Color) -> some View {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color(.secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isIncluded ? accentColor.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
        )
}

private struct SceneSecuritySystemActionEditorRow: View {
    @Binding var draft: SceneSecuritySystemActionDraft

    private var accentColor: Color {
        draft.isIncluded ? draft.mode.tintColor : Color.secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? accentColor : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(draft.isIncluded ? accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: draft.mode.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if draft.isIncluded {
                modePills
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? accentColor.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.mode)
    }

    private var modePills: some View {
        HStack(spacing: 8) {
            ForEach(draft.supportedModes) { mode in
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.mode = mode
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(mode.displayName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(draft.mode == mode ? .white : mode.tintColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(draft.mode == mode
                                  ? AnyShapeStyle(mode.tintColor)
                                  : AnyShapeStyle(mode.tintColor.opacity(0.10)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(draft.mode == mode ? Color.clear : mode.tintColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.security.notIncluded", defaultValue: "Not in scene")
        }
        return draft.mode.displayName
    }
}

private struct SceneFilledValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let valueText: String

    private let height: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 1)
            let normalized = (value - range.lowerBound) / span
            let fillWidth = geo.size.width * CGFloat(min(1, max(0, normalized)))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.86))
                    .frame(width: max(0, fillWidth))

                HStack {
                    Spacer()
                    Text(valueText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(fillWidth >= geo.size.width * 0.52 ? .white : .primary)
                        .contentTransition(.numericText())
                    Spacer()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let percent = min(1, max(0, gesture.location.x / geo.size.width))
                        let raw = range.lowerBound + Double(percent) * span
                        value = snapped(raw)
                    }
            )
        }
        .frame(height: height)
    }

    private func snapped(_ raw: Double) -> Double {
        let safeStep = max(step, 1)
        let stepped = (raw / safeStep).rounded() * safeStep
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

private struct SceneHumidifierActionEditorRow: View {
    @Binding var draft: SceneHumidifierActionDraft

    private var accentColor: Color {
        guard draft.isIncluded else { return .secondary }
        return draft.powerOn ? draft.mode.tintColor : .secondary
    }

    private var hasHumidityTarget: Bool {
        draft.humidifierThresholdCharacteristic != nil || draft.dehumidifierThresholdCharacteristic != nil
    }

    private var humidityBinding: Binding<Double> {
        Binding(
            get: { draft.targetHumidity },
            set: { draft.targetHumidity = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? accentColor : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(draft.powerOn ? accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: draft.powerOn ? "humidifier.fill" : "humidifier")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if draft.isIncluded {
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            draft.powerOn.toggle()
                        }
                    } label: {
                        Image(systemName: draft.powerOn ? "power.circle.fill" : "power.circle")
                            .font(.title2)
                            .foregroundStyle(draft.powerOn ? accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if draft.isIncluded && draft.powerOn {
                if draft.supportedModes.count > 1 {
                    modePills
                }

                if hasHumidityTarget {
                    humidityControl
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? accentColor.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.powerOn)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.mode)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.targetHumidity)
    }

    private var modePills: some View {
        HStack(spacing: 8) {
            ForEach(draft.supportedModes) { mode in
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.mode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(draft.mode == mode ? .white : mode.tintColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(draft.mode == mode
                                  ? AnyShapeStyle(mode.tintColor)
                                  : AnyShapeStyle(mode.tintColor.opacity(0.10)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(draft.mode == mode ? Color.clear : mode.tintColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var humidityControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(String(localized: "humidifier.humidity.target", defaultValue: "Target humidity"), systemImage: "humidity.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(draft.targetHumidity.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accentColor)
                    .contentTransition(.numericText())
            }

            SceneFilledValueSlider(
                value: humidityBinding,
                range: draft.targetHumidityRange,
                step: draft.targetHumidityStep,
                tint: accentColor,
                valueText: "\(Int(draft.targetHumidity.rounded()))%"
            )
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.humidifier.notIncluded", defaultValue: "Not in scene")
        }
        guard draft.powerOn else {
            return String(localized: "accessory.state.off", defaultValue: "Off")
        }
        if hasHumidityTarget {
            return "\(draft.mode.displayName) • \(Int(draft.targetHumidity.rounded()))%"
        }
        return draft.mode.displayName
    }
}

private struct SceneAirPurifierActionEditorRow: View {
    @Binding var draft: SceneAirPurifierActionDraft

    private var accentColor: Color {
        guard draft.isIncluded else { return .secondary }
        return draft.powerOn ? draft.mode.tintColor : .secondary
    }

    private var fanBinding: Binding<Double> {
        Binding(
            get: { Double(draft.fanSpeed) },
            set: { draft.fanSpeed = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? accentColor : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(draft.powerOn ? accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: draft.powerOn ? "air.purifier.fill" : "air.purifier")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if draft.isIncluded {
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            draft.powerOn.toggle()
                        }
                    } label: {
                        Image(systemName: draft.powerOn ? "power.circle.fill" : "power.circle")
                            .font(.title2)
                            .foregroundStyle(draft.powerOn ? accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if draft.isIncluded && draft.powerOn {
                modePills

                if draft.mode == .manual && draft.rotationSpeedCharacteristic != nil {
                    fanControl
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? accentColor.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.powerOn)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.mode)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.fanSpeed)
    }

    private var modePills: some View {
        HStack(spacing: 8) {
            ForEach(draft.supportedModes) { mode in
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.mode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(draft.mode == mode ? .white : mode.tintColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(draft.mode == mode
                                  ? AnyShapeStyle(mode.tintColor)
                                  : AnyShapeStyle(mode.tintColor.opacity(0.10)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(draft.mode == mode ? Color.clear : mode.tintColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fanControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(String(localized: "thermostat.fan", defaultValue: "Fan"), systemImage: "fan.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(draft.fanSpeed)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accentColor)
                    .contentTransition(.numericText())
            }

            SceneFilledValueSlider(
                value: fanBinding,
                range: Double(draft.fanRange.lowerBound)...Double(draft.fanRange.upperBound),
                step: Double(draft.fanStep),
                tint: accentColor,
                valueText: "\(draft.fanSpeed)%"
            )
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.airPurifier.notIncluded", defaultValue: "Not in scene")
        }
        guard draft.powerOn else {
            return String(localized: "accessory.state.off", defaultValue: "Off")
        }
        if draft.mode == .manual, draft.rotationSpeedCharacteristic != nil {
            return "\(draft.mode.displayName) • \(draft.fanSpeed)%"
        }
        return draft.mode.displayName
    }
}

private struct SceneThermostatActionEditorRow: View {
    @Binding var draft: SceneThermostatActionDraft

    private var temperatureText: String {
        String(format: "%.1f °C", draft.targetTemperature)
    }

    private var accentColor: Color {
        draft.isIncluded ? draft.mode.tintColor : Color.secondary
    }

    private var fanBinding: Binding<Double> {
        Binding(
            get: { Double(draft.fanSpeed) },
            set: { draft.fanSpeed = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? accentColor : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(draft.isIncluded ? accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: draft.mode.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if draft.isIncluded {
                modePills

                if draft.mode != .off {
                    temperatureStepper
                    if draft.rotationSpeedCharacteristic != nil {
                        fanControl
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? accentColor.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.mode)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.targetTemperature)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.fanSpeed)
    }

    private var modePills: some View {
        HStack(spacing: 8) {
            ForEach(draft.supportedModes) { mode in
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.mode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(draft.mode == mode ? .white : mode.tintColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(draft.mode == mode
                                  ? AnyShapeStyle(mode.tintColor)
                                  : AnyShapeStyle(mode.tintColor.opacity(0.10)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(draft.mode == mode ? Color.clear : mode.tintColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var temperatureStepper: some View {
        HStack(spacing: 12) {
            Button {
                adjustTemperature(by: -draft.temperatureStep)
            } label: {
                Image(systemName: "minus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                Text(temperatureText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accentColor)
                    .contentTransition(.numericText())
                Text(String(localized: "thermostat.target", defaultValue: "Target"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                adjustTemperature(by: draft.temperatureStep)
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fanControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(String(localized: "scene.editor.fanSpeed", defaultValue: "Fan speed"), systemImage: "fan.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(draft.fanSpeed)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accentColor)
                    .contentTransition(.numericText())
            }

            SceneFilledValueSlider(
                value: fanBinding,
                range: Double(draft.fanRange.lowerBound)...Double(draft.fanRange.upperBound),
                step: Double(draft.fanStep),
                tint: accentColor,
                valueText: "\(draft.fanSpeed)%"
            )
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.thermostat.notIncluded", defaultValue: "Not in scene")
        }
        if draft.mode == .off {
            return String(localized: "thermostat.mode.off", defaultValue: "Off")
        }
        if draft.rotationSpeedCharacteristic != nil {
            return "\(draft.mode.displayName) • \(temperatureText) • \(draft.fanSpeed)%"
        }
        return "\(draft.mode.displayName) • \(temperatureText)"
    }

    private func adjustTemperature(by delta: Double) {
        let next = draft.targetTemperature + delta
        draft.targetTemperature = min(max(next, draft.targetRange.lowerBound), draft.targetRange.upperBound)
    }
}

private struct SceneWindowCoveringActionEditorRow: View {
    @Binding var draft: SceneWindowCoveringActionDraft

    private var positionBinding: Binding<Double> {
        Binding(
            get: { Double(draft.position) },
            set: { draft.position = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? Color.brown : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(draft.isIncluded ? Color.brown.opacity(0.16) : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: draft.position <= 10 ? "blinds.horizontal.closed" : "blinds.horizontal.open")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.isIncluded ? Color.brown : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if draft.isIncluded {
                WindowCoveringPositionControl(
                    position: positionBinding,
                    isReachable: true,
                    height: 46,
                    cornerRadius: 14,
                    onDragChanged: { _ in },
                    onEditingEnded: { draft.position = Int($0.rounded()) }
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? Color.brown.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.position)
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.windowCovering.notIncluded", defaultValue: "Not in scene")
        }
        if draft.position <= 10 {
            return String(localized: "windowCovering.closed", defaultValue: "Closed")
        }
        if draft.position >= 90 {
            return String(localized: "windowCovering.open", defaultValue: "Open")
        }
        return String(localized: "windowCovering.partiallyOpen", defaultValue: "Open \(draft.position)%")
    }
}

private struct SceneSwitchActionEditorRow: View {
    @Binding var draft: SceneSwitchActionDraft

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.25)) {
                    draft.isIncluded.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(draft.isIncluded ? Color.indigo : Color(.tertiarySystemFill))
                        .frame(width: 34, height: 34)
                    Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(draft.isIncluded ? .white : .secondary)
                }
            }
            .buttonStyle(.plain)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(draft.powerOn ? Color.indigo.opacity(0.16) : Color(.tertiarySystemFill))
                    .frame(width: 40, height: 40)
                Image(systemName: draft.powerOn ? "lightswitch.on.fill" : "lightswitch.off")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(draft.powerOn ? Color.indigo : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(draft.accessoryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if draft.isIncluded {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.powerOn.toggle()
                    }
                } label: {
                    Image(systemName: draft.powerOn ? "power.circle.fill" : "power.circle")
                        .font(.title2)
                        .foregroundStyle(draft.powerOn ? Color.indigo : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? Color.indigo.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.powerOn)
    }

    private var stateText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.switch.notIncluded", defaultValue: "Not in scene")
        }
        return draft.powerOn
            ? String(localized: "accessory.state.on", defaultValue: "On")
            : String(localized: "accessory.state.off", defaultValue: "Off")
    }
}

private struct SceneOutletActionEditorRow: View {
    @Binding var draft: SceneOutletActionDraft

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.25)) {
                    draft.isIncluded.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(draft.isIncluded ? Color.blue : Color(.tertiarySystemFill))
                        .frame(width: 34, height: 34)
                    Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(draft.isIncluded ? .white : .secondary)
                }
            }
            .buttonStyle(.plain)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(draft.powerOn ? Color.blue.opacity(0.16) : Color(.tertiarySystemFill))
                    .frame(width: 40, height: 40)
                Image(systemName: draft.powerOn ? "powerplug.fill" : "powerplug")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(draft.powerOn ? Color.blue : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(draft.accessoryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if draft.isIncluded {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.powerOn.toggle()
                    }
                } label: {
                    Image(systemName: draft.powerOn ? "power.circle.fill" : "power.circle")
                        .font(.title2)
                        .foregroundStyle(draft.powerOn ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? Color.blue.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.powerOn)
    }

    private var subtitle: String {
        if let parentName = draft.parentName {
            return "\(parentName) • \(stateText)"
        }
        return stateText
    }

    private var stateText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.outlet.notIncluded", defaultValue: "Not in scene")
        }
        return draft.powerOn
            ? String(localized: "outlet.state.on", defaultValue: "Accesa")
            : String(localized: "outlet.state.off", defaultValue: "Spenta")
    }
}

private struct SceneLightActionEditorRow: View {
    @Binding var draft: SceneLightActionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        draft.isIncluded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(draft.isIncluded ? Color.orange : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        Image(systemName: draft.isIncluded ? "checkmark" : "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(draft.isIncluded ? .white : .secondary)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.accessoryName)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if draft.isIncluded {
                    powerButton
                }
            }

            if draft.isIncluded {
                if draft.powerOn {
                    brightnessControl

                    if draft.supportsColor && draft.supportsColorTemperature {
                        Picker(String(localized: "scene.editor.colorMode", defaultValue: "Color Mode"), selection: $draft.colorMode) {
                            ForEach(SceneLightColorMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if shouldShowColorPanel {
                        LightColorControlPanel(
                            supportsColor: draft.supportsColor && draft.colorMode == .color,
                            supportsColorTemperature: draft.supportsColorTemperature && draft.colorMode == .temperature,
                            isReachable: true,
                            temperatureRange: draft.colorTemperatureRange,
                            hueDraft: $draft.hue,
                            saturationDraft: $draft.saturation,
                            temperatureDraft: temperatureBinding,
                            onColorDragChanged: { _ in },
                            onTemperatureDragChanged: { _ in },
                            onColorChanged: { hue, saturation in
                                draft.hue = hue
                                draft.saturation = saturation
                            },
                            onTemperatureChanged: { value in
                                draft.colorTemperature = value
                            }
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(draft.isIncluded ? Color.orange.opacity(0.24) : Color(.separator).opacity(0.35), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.isIncluded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: draft.powerOn)
    }

    private var powerButton: some View {
        Button {
            withAnimation(.spring(response: 0.25)) {
                draft.powerOn.toggle()
            }
        } label: {
            Image(systemName: draft.powerOn ? "power.circle.fill" : "power.circle")
                .font(.title2)
                .foregroundStyle(draft.powerOn ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "scene.editor.light.power", defaultValue: "Turn On"))
    }

    private var brightnessControl: some View {
        LightBrightnessSlider(
            brightness: brightnessBinding,
            isEnabled: true,
            isDimmed: false,
            titleFont: .caption.weight(.medium),
            height: 46,
            cornerRadius: 14,
            onDragChanged: { _ in },
            onEditingEnded: { draft.brightness = Int(max(1, $0).rounded()) }
        )
    }

    private var statusText: String {
        guard draft.isIncluded else {
            return String(localized: "scene.editor.light.notIncluded", defaultValue: "Not in scene")
        }
        guard draft.powerOn else {
            return String(localized: "scene.editor.light.turnOff", defaultValue: "Turn off")
        }
        return "\(draft.brightness)%"
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(draft.brightness) },
            set: { draft.brightness = Int($0.rounded()) }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { Double(draft.colorTemperature) },
            set: { draft.colorTemperature = Int($0.rounded()) }
        )
    }

    private var shouldShowColorPanel: Bool {
        (draft.supportsColor && draft.colorMode == .color) ||
        (draft.supportsColorTemperature && draft.colorMode == .temperature)
    }
}
