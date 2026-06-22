import SwiftUI
import HomeKit

struct AutomationWizardSheet: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss

    @State private var step: AutomationWizardStep = .trigger
    @State private var name: String = ""
    @State private var capabilities: [AutomationCharacteristicCapability] = []

    @State private var triggerSource: AutomationTriggerSourceKind = .accessory
    @State private var triggerSelection: AutomationCapabilitySelection?
    @State private var isChoosingTrigger = true
    @State private var triggerSearchText = ""
    @State private var triggerRoomFilter: String?
    @State private var triggerCategoryFilter: AutomationCapabilityCategory = .all

    @State private var conditionSource: AutomationTriggerSourceKind = .accessory
    @State private var conditionDrafts: [AutomationConditionDraft] = []
    @State private var conditionJoinMode: AutomationConditionJoinMode = .all
    @State private var isAddingCondition = false
    @State private var editingConditionID: UUID?
    @State private var conditionBuilderSelection: AutomationCapabilitySelection?
    @State private var conditionSearchText = ""
    @State private var conditionRoomFilter: String?
    @State private var conditionCategoryFilter: AutomationCapabilityCategory = .all

    @State private var selectedSceneID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var selectedScene: SceneItem? {
        scenesService.scenes.first { $0.id == selectedSceneID }
    }

    private var canAdvance: Bool {
        switch step {
        case .trigger:
            return triggerSource == .accessory && triggerSelection != nil
        case .conditions:
            return true
        case .scene:
            return selectedScene != nil
        case .summary:
            return canSave
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        triggerSelection != nil &&
        selectedScene != nil
    }

    private var availableTriggerCapabilities: [AutomationCharacteristicCapability] {
        capabilities.filter { $0.supportedRoles.contains(.trigger) }
    }

    private var availableConditionCapabilities: [AutomationCharacteristicCapability] {
        let lockedIDs = Set(conditionDrafts
            .filter { $0.id != editingConditionID }
            .map(\.selection.capability.id))

        return capabilities
            .filter { $0.supportedRoles.contains(.condition) }
            .filter { !lockedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch step {
                        case .trigger:
                            triggerStep
                        case .conditions:
                            conditionsStep
                        case .scene:
                            sceneStep
                        case .summary:
                            summaryStep
                        }
                    }
                    .frame(maxWidth: 820, alignment: .center)
                    .padding(16)
                    .padding(.bottom, 88)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground))
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .navigationTitle(String(localized: "automation.wizard.title", defaultValue: "New Automation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .task {
                scenesService.refresh()
                if let home = homeKit.currentHome {
                    capabilities = AutomationCapabilityCatalog.capabilities(in: home)
                }
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
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(AutomationWizardStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? BrandColor.primary : Color(.tertiarySystemFill))
                        .frame(height: 5)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: step.iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 32, height: 32)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(step.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var triggerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(
                String(localized: "automation.wizard.trigger.source.title", defaultValue: "Choose what starts the automation"),
                subtitle: String(localized: "automation.wizard.trigger.source.subtitle", defaultValue: "The wizard is structured by trigger source, so more HomeKit trigger types can fit here later.")
            )

            sourcePicker(selectedSource: $triggerSource)

            if triggerSource != .accessory {
                unavailableSourceCard(triggerSource)
            } else if capabilities.isEmpty {
                ContentUnavailableView(
                    String(localized: "automation.wizard.noCapabilities.title", defaultValue: "No compatible triggers"),
                    systemImage: "sensor.tag.radiowaves.forward",
                    description: Text(String(localized: "automation.wizard.noCapabilities.description", defaultValue: "No readable HomeKit characteristics are available for automation triggers."))
                )
            } else if let binding = Binding($triggerSelection), !isChoosingTrigger {
                configuredSelectionPanel(
                    title: String(localized: "automation.wizard.trigger.configured", defaultValue: "Configured trigger"),
                    selection: binding,
                    primaryTitle: String(localized: "automation.wizard.trigger.change", defaultValue: "Change trigger"),
                    primaryIcon: "list.bullet",
                    primaryAction: {
                        withAnimation(.spring(response: 0.3)) {
                            isChoosingTrigger = true
                        }
                    }
                )
            } else {
                capabilityBrowser(
                    title: String(localized: "automation.wizard.trigger.browser.title", defaultValue: "Accessory triggers"),
                    subtitle: String(localized: "automation.wizard.trigger.browser.subtitle", defaultValue: "Filter by room or type, then choose the value to observe."),
                    items: filteredCapabilities(
                        availableTriggerCapabilities,
                        query: triggerSearchText,
                        room: triggerRoomFilter,
                        category: triggerCategoryFilter
                    ),
                    allItems: availableTriggerCapabilities,
                    searchText: $triggerSearchText,
                    roomFilter: $triggerRoomFilter,
                    categoryFilter: $triggerCategoryFilter,
                    selectedID: triggerSelection?.capability.id,
                    emptyTitle: String(localized: "automation.wizard.trigger.emptyFiltered", defaultValue: "No trigger matches these filters")
                ) { capability in
                    triggerSelection = AutomationCapabilitySelection(capability: capability)
                    isChoosingTrigger = false
                    defaultNameIfNeeded()
                }
            }
        }
    }

    private var conditionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isAddingCondition {
                conditionBuilder
            } else {
                conditionsOverview
            }
        }
    }

    private var conditionsOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(
                String(localized: "automation.wizard.conditions.overview.title", defaultValue: "Optional checks"),
                subtitle: String(localized: "automation.wizard.conditions.overview.subtitle", defaultValue: "Conditions do not start the automation. They decide whether the scene is allowed to run after the trigger happens.")
            )

            if conditionDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "automation.wizard.conditions.none.title", defaultValue: "No conditions"), systemImage: "checklist.unchecked")
                        .font(.headline)
                    Text(String(localized: "automation.wizard.conditions.none", defaultValue: "The automation will run whenever the trigger happens."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                conditionLogicCard

                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "automation.wizard.conditions.selected", defaultValue: "Selected conditions"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(conditionDrafts) { draft in
                        conditionSummaryRow(draft)
                    }
                }
            }

            Button {
                startAddingCondition()
            } label: {
                Label(String(localized: "automation.wizard.conditions.add", defaultValue: "Add condition"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var conditionBuilder: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                sectionTitle(
                    editingConditionID == nil
                    ? String(localized: "automation.wizard.conditions.builder.addTitle", defaultValue: "Add condition")
                    : String(localized: "automation.wizard.conditions.builder.editTitle", defaultValue: "Edit condition"),
                    subtitle: String(localized: "automation.wizard.conditions.builder.subtitle", defaultValue: "Pick a source, then configure the operator and target value.")
                )

                Spacer()

                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    cancelConditionBuilder()
                }
                .buttonStyle(.bordered)
                .tint(BrandColor.primary)
            }

            sourcePicker(selectedSource: $conditionSource)

            if conditionSource != .accessory {
                unavailableSourceCard(conditionSource)
            } else if let binding = Binding($conditionBuilderSelection) {
                configuredSelectionPanel(
                    title: String(localized: "automation.wizard.conditions.builder.configured", defaultValue: "Configure condition"),
                    selection: binding,
                    primaryTitle: editingConditionID == nil
                    ? String(localized: "automation.wizard.conditions.builder.add", defaultValue: "Add condition")
                    : String(localized: "automation.wizard.conditions.builder.update", defaultValue: "Update condition"),
                    primaryIcon: "checkmark.circle.fill",
                    primaryAction: commitConditionDraft,
                    secondaryTitle: String(localized: "automation.wizard.conditions.builder.chooseAnother", defaultValue: "Choose another"),
                    secondaryIcon: "list.bullet",
                    secondaryAction: {
                        withAnimation(.spring(response: 0.3)) {
                            conditionBuilderSelection = nil
                        }
                    }
                )
            } else {
                capabilityBrowser(
                    title: String(localized: "automation.wizard.conditions.browser.title", defaultValue: "Condition sources"),
                    subtitle: String(localized: "automation.wizard.conditions.browser.subtitle", defaultValue: "Select the accessory state that must be true."),
                    items: filteredCapabilities(
                        availableConditionCapabilities,
                        query: conditionSearchText,
                        room: conditionRoomFilter,
                        category: conditionCategoryFilter
                    ),
                    allItems: availableConditionCapabilities,
                    searchText: $conditionSearchText,
                    roomFilter: $conditionRoomFilter,
                    categoryFilter: $conditionCategoryFilter,
                    selectedID: conditionBuilderSelection?.capability.id,
                    emptyTitle: String(localized: "automation.wizard.conditions.emptyFiltered", defaultValue: "No condition matches these filters")
                ) { capability in
                    withAnimation(.spring(response: 0.3)) {
                        conditionBuilderSelection = AutomationCapabilitySelection(capability: capability)
                    }
                }
            }
        }
    }

    private var conditionLogicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "switch.2")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "automation.wizard.conditions.logic.title", defaultValue: "How conditions are grouped"))
                        .font(.headline)
                    Text(conditionJoinMode.helpText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(String(localized: "automation.wizard.conditions.logic", defaultValue: "Condition logic"), selection: $conditionJoinMode) {
                ForEach(AutomationConditionJoinMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sceneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.wizard.scene.title", defaultValue: "Choose the scene to run"),
                subtitle: String(localized: "automation.wizard.scene.subtitle", defaultValue: "For now this wizard creates scene-based automations. Direct accessory actions can be added later without changing the earlier steps.")
            )

            if scenesService.scenes.isEmpty {
                ContentUnavailableView(
                    String(localized: "automation.wizard.noScenes.title", defaultValue: "No scenes"),
                    systemImage: "wand.and.sparkles",
                    description: Text(String(localized: "automation.wizard.noScenes.description", defaultValue: "Create a scene first, then attach it to an automation."))
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(scenesService.scenes) { scene in
                        sceneRow(scene)
                    }
                }
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(
                String(localized: "automation.wizard.summary.title", defaultValue: "Review automation"),
                subtitle: String(localized: "automation.wizard.summary.subtitle", defaultValue: "Give it a name and confirm the trigger, conditions, and scene.")
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "automation.wizard.name", defaultValue: "Name"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                TextField(String(localized: "automation.wizard.name.placeholder", defaultValue: "Automation name"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            summaryCard(
                icon: "sensor.tag.radiowaves.forward",
                title: String(localized: "automation.wizard.summary.trigger", defaultValue: "Trigger"),
                value: triggerSelection.map(selectionSummary) ?? "-"
            )

            summaryCard(
                icon: "checklist",
                title: String(localized: "automation.wizard.summary.conditions", defaultValue: "Conditions"),
                value: conditionDrafts.isEmpty
                    ? String(localized: "automation.wizard.summary.noConditions", defaultValue: "No conditions")
                    : "\(conditionJoinMode.summaryTitle)\n\(conditionDrafts.map { selectionSummary($0.selection) }.joined(separator: "\n"))"
            )

            summaryCard(
                icon: "wand.and.sparkles",
                title: String(localized: "automation.wizard.summary.scene", defaultValue: "Scene"),
                value: selectedScene?.name ?? "-"
            )
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    step = step.previous ?? step
                    if step != .conditions {
                        cancelConditionBuilder()
                    }
                }
            } label: {
                Text(String(localized: "common.back", defaultValue: "Back"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(BrandColor.primary)
            .disabled(step.previous == nil || isSaving)

            Button {
                if step == .summary {
                    save()
                } else if let next = step.next {
                    withAnimation(.spring(response: 0.3)) {
                        if step == .conditions {
                            cancelConditionBuilder()
                        }
                        step = next
                    }
                }
            } label: {
                HStack {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(step == .summary
                         ? String(localized: "common.save", defaultValue: "Save")
                         : String(localized: "common.next", defaultValue: "Next"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
            .disabled(!canAdvance || isSaving)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func sourcePicker(selectedSource: Binding<AutomationTriggerSourceKind>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(AutomationTriggerSourceKind.allCases) { source in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedSource.wrappedValue = source
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: source.iconName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(selectedSource.wrappedValue == source ? .white : BrandColor.primary)
                                .frame(width: 34, height: 34)
                                .background(
                                    selectedSource.wrappedValue == source
                                    ? AnyShapeStyle(BrandColor.heroGradient)
                                    : AnyShapeStyle(BrandColor.primary.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            Spacer()

                            if !source.isAvailable {
                                Text(String(localized: "automation.wizard.source.future", defaultValue: "Soon"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                        }

                        Text(source.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(source.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(minHeight: 34, alignment: .topLeading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selectedSource.wrappedValue == source ? BrandColor.primary.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func unavailableSourceCard(_ source: AutomationTriggerSourceKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(source.title, systemImage: source.iconName)
                .font(.headline)
            Text(String(localized: "automation.wizard.source.unavailable", defaultValue: "This source is reserved in the flow, but creation is not implemented yet. Accessory events are available now."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                withAnimation(.spring(response: 0.3)) {
                    triggerSource = .accessory
                    conditionSource = .accessory
                }
            } label: {
                Label(String(localized: "automation.wizard.source.useAccessories", defaultValue: "Use accessories"), systemImage: "switch.2")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func capabilityBrowser(
        title: String,
        subtitle: String,
        items: [AutomationCharacteristicCapability],
        allItems: [AutomationCharacteristicCapability],
        searchText: Binding<String>,
        roomFilter: Binding<String?>,
        categoryFilter: Binding<AutomationCapabilityCategory>,
        selectedID: String?,
        emptyTitle: String,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title, subtitle: subtitle)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "automation.wizard.search.placeholder", defaultValue: "Search accessory, room, or capability"), text: searchText)
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                filterPills(
                    rooms: roomNames(from: allItems),
                    roomFilter: roomFilter,
                    categoryFilter: categoryFilter
                )
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(String(localized: "automation.wizard.emptyFiltered.description", defaultValue: "Try changing search, room, or type filters."))
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(roomNames(from: items), id: \.self) { room in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(room)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            ForEach(items.filter { $0.roomName == room }) { capability in
                                capabilityRowButton(
                                    capability,
                                    isSelected: selectedID == capability.id,
                                    onSelect: onSelect
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterPills(
        rooms: [String],
        roomFilter: Binding<String?>,
        categoryFilter: Binding<AutomationCapabilityCategory>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pillButton(
                        title: String(localized: "automation.wizard.filter.allRooms", defaultValue: "All rooms"),
                        isSelected: roomFilter.wrappedValue == nil
                    ) {
                        roomFilter.wrappedValue = nil
                    }

                    ForEach(rooms, id: \.self) { room in
                        pillButton(title: room, isSelected: roomFilter.wrappedValue == room) {
                            roomFilter.wrappedValue = room
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AutomationCapabilityCategory.allCases) { category in
                        pillButton(
                            title: category.title,
                            iconName: category.iconName,
                            isSelected: categoryFilter.wrappedValue == category
                        ) {
                            categoryFilter.wrappedValue = category
                        }
                    }
                }
            }
        }
    }

    private func pillButton(
        title: String,
        iconName: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName {
                    Image(systemName: iconName)
                }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
            )
        }
        .buttonStyle(.plain)
    }

    private func capabilityRowButton(
        _ capability: AutomationCharacteristicCapability,
        isSelected: Bool,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        Button {
            onSelect(capability)
        } label: {
            HStack(spacing: 12) {
                capabilityIcon(capability, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 4) {
                    Text(capability.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(capability.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(AutomationCapabilityCategory.category(for: capability).title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())

                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? BrandColor.primary : .tertiary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? BrandColor.primary.opacity(0.5) : Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func configuredSelectionPanel(
        title: String,
        selection: Binding<AutomationCapabilitySelection>,
        primaryTitle: String,
        primaryIcon: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryIcon: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    capabilityIcon(selection.wrappedValue.capability, isSelected: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.wrappedValue.capability.accessoryName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(selection.wrappedValue.capability.roomName) - \(selection.wrappedValue.capability.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Divider()

                capabilityValueEditor(selection: selection)

                HStack(spacing: 10) {
                    if let secondaryTitle, let secondaryIcon, let secondaryAction {
                        Button(action: secondaryAction) {
                            Label(secondaryTitle, systemImage: secondaryIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(BrandColor.primary)
                    }

                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primaryIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.primary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func conditionSummaryRow(_ draft: AutomationConditionDraft) -> some View {
        HStack(spacing: 12) {
            capabilityIcon(draft.selection.capability, isSelected: false)

            VStack(alignment: .leading, spacing: 3) {
                Text(draft.selection.capability.accessoryName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(selectionSummary(draft.selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                editCondition(draft)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .tint(BrandColor.primary)

            Button(role: .destructive) {
                conditionDrafts.removeAll { $0.id == draft.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func capabilityIcon(_ capability: AutomationCharacteristicCapability, isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(BrandColor.primary.opacity(0.12)))
                .frame(width: 42, height: 42)
            Image(systemName: capability.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : BrandColor.primary)
        }
    }

    private func capabilityValueEditor(selection: Binding<AutomationCapabilitySelection>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "automation.wizard.operator", defaultValue: "Operator"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                operatorPicker(selection: selection)
            }

            switch selection.wrappedValue.capability.valueKind {
            case .boolean(let activeLabel, let inactiveLabel):
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "automation.wizard.value", defaultValue: "Value"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: boolBinding(selection)) {
                        Text(activeLabel).tag(true)
                        Text(inactiveLabel).tag(false)
                    }
                    .pickerStyle(.segmented)
                }

            case .numeric(let unit, let range, let step):
                numericEditor(selection: selection, unit: unit, range: range, step: step)

            case .state(let options):
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "automation.wizard.value", defaultValue: "Value"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: stateBinding(selection)) {
                        ForEach(options) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func operatorPicker(selection: Binding<AutomationCapabilitySelection>) -> some View {
        Picker(String(localized: "automation.wizard.operator", defaultValue: "Operator"), selection: operatorBinding(selection)) {
            ForEach(operators(for: selection.wrappedValue.capability), id: \.self) { op in
                Text(op.displayName).tag(op)
            }
        }
        .pickerStyle(.segmented)
    }

    private func numericEditor(
        selection: Binding<AutomationCapabilitySelection>,
        unit: String,
        range: ClosedRange<Double>?,
        step: Double?
    ) -> some View {
        let allowedRange = range ?? 0...100
        let increment = step ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "automation.wizard.threshold", defaultValue: "Threshold"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(numericBinding(selection).wrappedValue, specifier: "%.1f")\(unit)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            Slider(value: numericBinding(selection), in: allowedRange, step: increment)
            HStack {
                Text("\(allowedRange.lowerBound, specifier: "%.1f")\(unit)")
                Spacer()
                Text("\(allowedRange.upperBound, specifier: "%.1f")\(unit)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func sceneRow(_ scene: SceneItem) -> some View {
        Button {
            selectedSceneID = scene.id
            defaultNameIfNeeded()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedSceneID == scene.id ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                        .frame(width: 42, height: 42)
                    Image(systemName: scene.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedSceneID == scene.id ? .white : BrandColor.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "action") : String(localized: "count.action.plural", defaultValue: "actions"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: selectedSceneID == scene.id ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selectedSceneID == scene.id ? BrandColor.primary : .tertiary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selectedSceneID == scene.id ? BrandColor.primary.opacity(0.5) : Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func summaryCard(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func filteredCapabilities(
        _ items: [AutomationCharacteristicCapability],
        query: String,
        room: String?,
        category: AutomationCapabilityCategory
    ) -> [AutomationCharacteristicCapability] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items.filter { capability in
            let matchesRoom = room == nil || capability.roomName == room
            let matchesCategory = category == .all || AutomationCapabilityCategory.category(for: capability) == category
            let matchesQuery = normalizedQuery.isEmpty ||
                capability.accessoryName.lowercased().contains(normalizedQuery) ||
                capability.roomName.lowercased().contains(normalizedQuery) ||
                capability.title.lowercased().contains(normalizedQuery)

            return matchesRoom && matchesCategory && matchesQuery
        }
    }

    private func roomNames(from items: [AutomationCharacteristicCapability]) -> [String] {
        Array(Set(items.map(\.roomName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func startAddingCondition() {
        withAnimation(.spring(response: 0.3)) {
            isAddingCondition = true
            editingConditionID = nil
            conditionBuilderSelection = nil
            conditionSource = .accessory
        }
    }

    private func editCondition(_ draft: AutomationConditionDraft) {
        withAnimation(.spring(response: 0.3)) {
            isAddingCondition = true
            editingConditionID = draft.id
            conditionBuilderSelection = draft.selection
            conditionSource = .accessory
        }
    }

    private func cancelConditionBuilder() {
        isAddingCondition = false
        editingConditionID = nil
        conditionBuilderSelection = nil
    }

    private func commitConditionDraft() {
        guard let selection = conditionBuilderSelection else { return }

        if let editingConditionID,
           let index = conditionDrafts.firstIndex(where: { $0.id == editingConditionID }) {
            conditionDrafts[index].selection = selection
        } else {
            conditionDrafts.append(AutomationConditionDraft(selection: selection))
        }

        withAnimation(.spring(response: 0.3)) {
            cancelConditionBuilder()
        }
    }

    private func save() {
        guard let triggerSelection, let selectedScene else { return }
        isSaving = true
        Task {
            do {
                _ = try await automationsService.createSceneAutomation(
                    name: name,
                    trigger: triggerSelection,
                    conditions: conditionDrafts.map(\.selection),
                    conditionJoinMode: conditionJoinMode,
                    scene: selectedScene,
                    enabled: true
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

    private func defaultNameIfNeeded() {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let selectedScene {
            name = String(localized: "automation.wizard.defaultName", defaultValue: "Run \(selectedScene.name)")
        } else if let triggerSelection {
            name = String(localized: "automation.wizard.defaultName.trigger", defaultValue: "\(triggerSelection.capability.accessoryName) automation")
        }
    }

    private func selectionSummary(_ selection: AutomationCapabilitySelection) -> String {
        "\(selection.capability.accessoryName) - \(selection.capability.title) \(selection.comparisonOperator.displayName) \(selection.targetValue.displayText(for: selection.capability.valueKind))"
    }

    private func operators(for capability: AutomationCharacteristicCapability) -> [AutomationCapabilityOperator] {
        switch capability.valueKind {
        case .boolean:
            return [.equals]
        case .numeric:
            return [.greaterThan, .lessThan, .equals]
        case .state:
            return [.equals]
        }
    }

    private func operatorBinding(_ selection: Binding<AutomationCapabilitySelection>) -> Binding<AutomationCapabilityOperator> {
        Binding {
            selection.wrappedValue.comparisonOperator
        } set: { newValue in
            selection.wrappedValue.comparisonOperator = newValue
        }
    }

    private func boolBinding(_ selection: Binding<AutomationCapabilitySelection>) -> Binding<Bool> {
        Binding {
            if case .bool(let value) = selection.wrappedValue.targetValue { return value }
            return true
        } set: { newValue in
            selection.wrappedValue.targetValue = .bool(newValue)
        }
    }

    private func numericBinding(_ selection: Binding<AutomationCapabilitySelection>) -> Binding<Double> {
        Binding {
            if case .number(let value) = selection.wrappedValue.targetValue { return value }
            return 0
        } set: { newValue in
            selection.wrappedValue.targetValue = .number(newValue)
        }
    }

    private func stateBinding(_ selection: Binding<AutomationCapabilitySelection>) -> Binding<Int> {
        Binding {
            if case .state(let value) = selection.wrappedValue.targetValue { return value }
            return 0
        } set: { newValue in
            selection.wrappedValue.targetValue = .state(newValue)
        }
    }
}

private enum AutomationWizardStep: Int, CaseIterable, Identifiable {
    case trigger = 0
    case conditions = 1
    case scene = 2
    case summary = 3

    var id: Int { rawValue }

    var next: AutomationWizardStep? {
        AutomationWizardStep(rawValue: rawValue + 1)
    }

    var previous: AutomationWizardStep? {
        AutomationWizardStep(rawValue: rawValue - 1)
    }

    var title: String {
        switch self {
        case .trigger:
            return String(localized: "automation.wizard.step.trigger", defaultValue: "When")
        case .conditions:
            return String(localized: "automation.wizard.step.conditions", defaultValue: "Only if")
        case .scene:
            return String(localized: "automation.wizard.step.scene", defaultValue: "Run")
        case .summary:
            return String(localized: "automation.wizard.step.summary", defaultValue: "Review")
        }
    }

    var subtitle: String {
        switch self {
        case .trigger:
            return String(localized: "automation.wizard.step.trigger.subtitle", defaultValue: "Choose the event that starts this automation.")
        case .conditions:
            return String(localized: "automation.wizard.step.conditions.subtitle", defaultValue: "Add optional checks that must be true.")
        case .scene:
            return String(localized: "automation.wizard.step.scene.subtitle", defaultValue: "Choose the scene to execute.")
        case .summary:
            return String(localized: "automation.wizard.step.summary.subtitle", defaultValue: "Confirm the automation before saving.")
        }
    }

    var iconName: String {
        switch self {
        case .trigger: return "sensor.tag.radiowaves.forward"
        case .conditions: return "checklist"
        case .scene: return "wand.and.sparkles"
        case .summary: return "checkmark.seal"
        }
    }
}

private enum AutomationTriggerSourceKind: String, CaseIterable, Identifiable {
    case accessory
    case time
    case people
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessory:
            return String(localized: "automation.source.accessory.title", defaultValue: "Accessory")
        case .time:
            return String(localized: "automation.source.time.title", defaultValue: "Time")
        case .people:
            return String(localized: "automation.source.people.title", defaultValue: "People")
        case .location:
            return String(localized: "automation.source.location.title", defaultValue: "Location")
        }
    }

    var subtitle: String {
        switch self {
        case .accessory:
            return String(localized: "automation.source.accessory.subtitle", defaultValue: "Sensors and device states")
        case .time:
            return String(localized: "automation.source.time.subtitle", defaultValue: "At a time or sun event")
        case .people:
            return String(localized: "automation.source.people.subtitle", defaultValue: "Presence at home")
        case .location:
            return String(localized: "automation.source.location.subtitle", defaultValue: "Arrive or leave a place")
        }
    }

    var iconName: String {
        switch self {
        case .accessory: return "switch.2"
        case .time: return "clock"
        case .people: return "person.2.fill"
        case .location: return "location.fill"
        }
    }

    var isAvailable: Bool {
        self == .accessory
    }
}

private enum AutomationCapabilityCategory: String, CaseIterable, Identifiable {
    case all
    case sensors
    case lights
    case climate
    case security
    case openings
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return String(localized: "automation.capabilityCategory.all", defaultValue: "All")
        case .sensors:
            return String(localized: "automation.capabilityCategory.sensors", defaultValue: "Sensors")
        case .lights:
            return String(localized: "automation.capabilityCategory.lights", defaultValue: "Lights")
        case .climate:
            return String(localized: "automation.capabilityCategory.climate", defaultValue: "Climate")
        case .security:
            return String(localized: "automation.capabilityCategory.security", defaultValue: "Security")
        case .openings:
            return String(localized: "automation.capabilityCategory.openings", defaultValue: "Openings")
        case .other:
            return String(localized: "automation.capabilityCategory.other", defaultValue: "Other")
        }
    }

    var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .sensors: return "sensor.tag.radiowaves.forward"
        case .lights: return "lightbulb.fill"
        case .climate: return "thermometer.medium"
        case .security: return "lock.shield.fill"
        case .openings: return "door.left.hand.open"
        case .other: return "ellipsis.circle"
        }
    }

    static func category(for capability: AutomationCharacteristicCapability) -> AutomationCapabilityCategory {
        let icon = capability.iconName.lowercased()
        let title = capability.title.lowercased()

        if icon.contains("lightbulb") || icon.contains("sun") || title.contains("brightness") {
            return .lights
        }
        if icon.contains("thermometer") || icon.contains("humidity") || icon.contains("aqi") ||
            title.contains("temperature") || title.contains("humidity") || title.contains("air") {
            return .climate
        }
        if icon.contains("lock") || icon.contains("shield") || title.contains("security") || title.contains("lock") {
            return .security
        }
        if icon.contains("door") || icon.contains("window") || icon.contains("blinds") ||
            title.contains("door") || title.contains("position") || title.contains("contact") {
            return .openings
        }
        if icon.contains("sensor") || icon.contains("smoke") || icon.contains("drop") ||
            title.contains("motion") || title.contains("occupancy") || title.contains("leak") {
            return .sensors
        }
        return .other
    }
}

private struct AutomationConditionDraft: Identifiable {
    let id = UUID()
    var selection: AutomationCapabilitySelection
}

private extension AutomationCapabilityOperator {
    var displayName: String {
        switch self {
        case .becomesActive:
            return String(localized: "automation.operator.becomesActive", defaultValue: "Becomes active")
        case .becomesInactive:
            return String(localized: "automation.operator.becomesInactive", defaultValue: "Becomes inactive")
        case .equals:
            return String(localized: "automation.operator.equals", defaultValue: "Is")
        case .greaterThan:
            return String(localized: "automation.operator.greaterThan", defaultValue: "Above")
        case .lessThan:
            return String(localized: "automation.operator.lessThan", defaultValue: "Below")
        }
    }
}

private extension AutomationConditionJoinMode {
    var shortTitle: String {
        switch self {
        case .all:
            return String(localized: "automation.conditionJoin.all.short", defaultValue: "All")
        case .any:
            return String(localized: "automation.conditionJoin.any.short", defaultValue: "Any")
        }
    }

    var helpText: String {
        switch self {
        case .all:
            return String(localized: "automation.conditionJoin.all.help", defaultValue: "The scene runs only when every condition is true.")
        case .any:
            return String(localized: "automation.conditionJoin.any.help", defaultValue: "The scene runs when at least one condition is true.")
        }
    }

    var summaryTitle: String {
        switch self {
        case .all:
            return String(localized: "automation.conditionJoin.all.summary", defaultValue: "All conditions must be true")
        case .any:
            return String(localized: "automation.conditionJoin.any.summary", defaultValue: "At least one condition must be true")
        }
    }
}

private extension AutomationCapabilityTargetValue {
    func displayText(for valueKind: AutomationCapabilityValueKind) -> String {
        switch (self, valueKind) {
        case (.bool(let value), .boolean(let activeLabel, let inactiveLabel)):
            return value ? activeLabel : inactiveLabel
        case (.number(let value), .numeric(let unit, _, _)):
            return String(format: "%.1f%@", value, unit)
        case (.state(let rawValue), .state(let options)):
            return options.first { $0.rawValue == rawValue }?.title ?? "\(rawValue)"
        default:
            return "\(numberValue)"
        }
    }
}
