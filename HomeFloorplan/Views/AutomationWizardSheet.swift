import SwiftUI
import HomeKit
import MapKit
import CoreLocation

private struct AutomationCapabilityAccessoryGroup: Identifiable {
    let id: String
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String
    let capabilities: [AutomationCharacteristicCapability]
}

struct AutomationWizardSheet: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.dismiss) private var dismiss

    @State private var step: AutomationWizardStep = .trigger
    @State private var name: String = ""
    @State private var capabilities: [AutomationCharacteristicCapability] = []

    @State private var triggerSource: AutomationTriggerSourceKind = .accessory
    @State private var triggerPickerSource: AutomationTriggerSourceKind?
    @State private var triggerSelection: AutomationCapabilitySelection?
    @State private var scheduleTrigger = AutomationScheduleTrigger()
    @State private var presenceTrigger = AutomationPresenceTrigger()
    @State private var locationTrigger = AutomationLocationTrigger()
    @State private var startEvents: [AutomationStartEventDraft] = []
    @State private var locationRequestID = 0
    @State private var isChoosingTrigger = true
    @State private var showTriggerTargetPicker = false
    @State private var triggerSearchText = ""
    @State private var triggerRoomFilter: String?
    @State private var triggerCategoryFilter: AutomationCapabilityCategory = .all

    @State private var conditionDrafts: [AutomationConditionDraft] = []
    @State private var timeConditionDrafts: [AutomationTimeCondition] = []
    @State private var presenceConditionDrafts: [AutomationPresenceCondition] = []
    @State private var preservedConditionPredicate: NSPredicate?
    @State private var conditionJoinMode: AutomationConditionJoinMode = .all
    @State private var conditionPickerSource: AutomationTriggerSourceKind?
    @State private var showConditionTargetPicker = false
    @State private var conditionSearchText = ""
    @State private var conditionRoomFilter: String?
    @State private var conditionCategoryFilter: AutomationCapabilityCategory = .all

    @State private var selectedSceneID: UUID?
    @State private var editingSceneFallback: SceneItem?
    @State private var showScenePicker = false
    @State private var showInlineActionPicker = false
    @State private var inlinePowerActions: [AutomationInlinePowerAction] = []
    @State private var inlineActionBundle = SceneActionDraftBundle()
    @State private var activateAutomation = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var externalEditNotice: String?
    @State private var unmanagedActionNotice: String?
    @State private var didLoadInitialContent = false
    private let editingItem: AutomationItem?
    private let proposal: AutomationProposal?
    private let onSaved: ((AutomationItem) -> Void)?

    init(editing item: AutomationItem? = nil, onSaved: ((AutomationItem) -> Void)? = nil) {
        self.editingItem = item
        self.proposal = nil
        self.onSaved = onSaved
        _name = State(initialValue: item?.name ?? "")
        _activateAutomation = State(initialValue: item?.isEnabled ?? true)
    }

    init(proposal: AutomationProposal, onSaved: ((AutomationItem) -> Void)? = nil) {
        self.editingItem = nil
        self.proposal = proposal
        self.onSaved = onSaved
        _name = State(initialValue: proposal.title)
        _activateAutomation = State(initialValue: proposal.shouldEnableAutomation)
    }

    private var selectedScene: SceneItem? {
        editingSceneFallback.flatMap { $0.id == selectedSceneID ? $0 : nil } ??
        scenesService.scenes.first { $0.id == selectedSceneID }
    }

    private var canAdvance: Bool {
        switch step {
        case .trigger:
            return hasConfiguredTrigger
        case .conditions:
            return true
        case .scene:
            return hasThenTarget
        case .summary:
            return canSave
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasConfiguredTrigger &&
        hasThenTarget &&
        externalEditNotice == nil &&
        unmanagedActionNotice == nil
    }

    private var hasThenTarget: Bool {
        selectedScene != nil || !inlinePowerActions.isEmpty || !inlineActionBundle.isEmpty
    }

    private var inlinePowerActionCandidates: [AutomationInlinePowerAction] {
        let selectedIDs = Set(inlinePowerActions.map { $0.characteristic.uniqueIdentifier })
        return homeKit.allAccessories.compactMap { accessory in
            guard let power = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypePowerState)
                    ?? AccessoryAdapterFactory.findCharacteristic(in: accessory, type: HMCharacteristicTypeActive),
                  !selectedIDs.contains(power.uniqueIdentifier) else {
                return nil
            }

            let current = AutomationWizardSheet.boolValue(homeKit.value(for: power) ?? power.value) ?? true
            return AutomationInlinePowerAction(
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room"),
                characteristic: power,
                powerOn: current
            )
        }
        .sorted {
            if $0.roomName != $1.roomName {
                return $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    private var inlineActionBundleSummary: String {
        var parts: [String] = []
        appendIncluded(inlineActionBundle.lightDrafts, to: &parts)
        appendIncluded(inlineActionBundle.outletDrafts, to: &parts)
        appendIncluded(inlineActionBundle.switchDrafts, to: &parts)
        appendIncluded(inlineActionBundle.windowCoveringDrafts, to: &parts)
        appendIncluded(inlineActionBundle.thermostatDrafts, to: &parts)
        appendIncluded(inlineActionBundle.airPurifierDrafts, to: &parts)
        appendIncluded(inlineActionBundle.fanDrafts, to: &parts)
        appendIncluded(inlineActionBundle.humidifierDrafts, to: &parts)
        appendIncluded(inlineActionBundle.securitySystemDrafts, to: &parts)
        appendIncluded(inlineActionBundle.doorLockDrafts, to: &parts)
        appendIncluded(inlineActionBundle.garageDoorDrafts, to: &parts)
        appendIncluded(inlineActionBundle.valveDrafts, to: &parts)

        return parts.prefix(6).joined(separator: " • ") +
        (parts.count > 6 ? " • \(String(localized: "automation.composer.actions.inline.more", defaultValue: "and more"))" : "")
    }

    private func appendIncluded<T: SceneActionDraftDisplayable>(_ drafts: [T], to parts: inout [String]) {
        for draft in drafts where draft.isIncluded {
            parts.append(draft.accessoryName)
        }
    }

    private var hasConfiguredTrigger: Bool {
        !startEvents.isEmpty && startEvents.allSatisfy(\.isValid)
    }

    private var startEventSummary: String {
        guard !startEvents.isEmpty else {
            return String(localized: "automation.wizard.context.missing", defaultValue: "Not set")
        }
        if startEvents.count == 1, let first = startEvents.first {
            return first.summary
        }
        return String(format: String(localized: "automation.wizard.context.startEvents.count",
                                     defaultValue: "%d events"),
                      startEvents.count)
    }

    private var hasConditions: Bool {
        !conditionDrafts.isEmpty || !timeConditionDrafts.isEmpty || !presenceConditionDrafts.isEmpty || preservedConditionPredicate != nil
    }

    private var locationTriggerDisplaySummary: String {
        guard locationTrigger.isValid else {
            return String(localized: "automation.location.needsMapPoint", defaultValue: "Tap the map to set the geofence.")
        }

        return String(format: String(localized: "automation.location.summary.geofence",
                                     defaultValue: "%@ within %d m"),
                      locationTrigger.kind.title,
                      Int(locationTrigger.radius.rounded()))
    }

    private var availableTriggerCapabilities: [AutomationCharacteristicCapability] {
        capabilities.filter { $0.supportedRoles.contains(.trigger) }
    }

    private var availableConditionCapabilities: [AutomationCharacteristicCapability] {
        let lockedIDs = Set(conditionDrafts.map(\.selection.capability.id))

        return capabilities
            .filter { $0.supportedRoles.contains(.condition) }
            .filter { !lockedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    automationComposer
                    .frame(maxWidth: 860, alignment: .center)
                    .padding(16)
                    .padding(.bottom, 88)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground))

                composerBottomBar
            }
            .navigationTitle(editingItem == nil
                             ? (proposal == nil
                                ? String(localized: "automation.wizard.title", defaultValue: "New Automation")
                                : String(localized: "automation.wizard.proposalTitle", defaultValue: "Review Automation"))
                             : String(localized: "automation.wizard.editTitle", defaultValue: "Edit Automation"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                scenesService.refresh()
                if inlineActionBundle.lightDrafts.isEmpty,
                   inlineActionBundle.outletDrafts.isEmpty,
                   inlineActionBundle.switchDrafts.isEmpty,
                   inlineActionBundle.windowCoveringDrafts.isEmpty,
                   inlineActionBundle.thermostatDrafts.isEmpty,
                   inlineActionBundle.airPurifierDrafts.isEmpty,
                   inlineActionBundle.fanDrafts.isEmpty,
                   inlineActionBundle.humidifierDrafts.isEmpty,
                   inlineActionBundle.securitySystemDrafts.isEmpty,
                   inlineActionBundle.doorLockDrafts.isEmpty,
                   inlineActionBundle.garageDoorDrafts.isEmpty {
                    inlineActionBundle = scenesService.actionDraftBundle()
                }
                if let home = homeKit.currentHome {
                    capabilities = AutomationCapabilityCatalog.capabilities(in: home)
                    guard !didLoadInitialContent else { return }
                    didLoadInitialContent = true
                    if let proposal {
                        loadProposal(proposal, capabilities: capabilities, scenes: scenesService.scenes)
                    } else if let editingItem {
                        loadEditingItem(editingItem, capabilities: capabilities, scenes: scenesService.scenes)
                    }
                }
            }
            .alert(String(localized: "alert.error.title", defaultValue: "Error"),
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                   ),
                   presenting: errorMessage) { _ in
                Button(String(localized: "button.ok", defaultValue: "OK")) {}
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $showTriggerTargetPicker) {
                NavigationStack {
                    targetTypePickerPopup(
                        selectedSource: $triggerPickerSource,
                        accessoryContent: {
                            capabilityPickerPopup(
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
                                selectedID: nil,
                                emptyTitle: String(localized: "automation.wizard.trigger.emptyFiltered", defaultValue: "No trigger matches these filters")
                            ) { capability in
                                let selection = AutomationCapabilitySelection(capability: capability)
                                startEvents.append(AutomationStartEventDraft(selection: selection))
                                triggerSource = .accessory
                                triggerSelection = selection
                                isChoosingTrigger = false
                                defaultNameIfNeeded()
                                showTriggerTargetPicker = false
                            }
                        },
                        timeContent: {
                            scheduleSourcePopup
                        },
                        peopleContent: {
                            presenceTriggerSourcePopup
                        },
                        locationContent: {
                            locationTriggerSourcePopup
                        }
                    )
                    .navigationTitle(String(localized: "automation.wizard.targetPicker.title", defaultValue: "Choose Target"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "common.done", defaultValue: "Done")) {
                                showTriggerTargetPicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showConditionTargetPicker) {
                NavigationStack {
                    targetTypePickerPopup(
                        selectedSource: $conditionPickerSource,
                        accessoryContent: {
                            capabilityPickerPopup(
                                title: String(localized: "automation.wizard.conditions.browser.title", defaultValue: "Condition sources"),
                                subtitle: String(localized: "automation.wizard.conditions.browser.subtitle", defaultValue: "Filter by room or type, then choose the value to check."),
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
                                selectedID: nil,
                                emptyTitle: String(localized: "automation.wizard.conditions.emptyFiltered", defaultValue: "No condition matches these filters")
                            ) { capability in
                                conditionDrafts.append(
                                    AutomationConditionDraft(selection: AutomationCapabilitySelection(capability: capability))
                                )
                                showConditionTargetPicker = false
                            }
                        },
                        timeContent: {
                            timeConditionSourcePopup
                        },
                        peopleContent: {
                            presenceConditionSourcePopup
                        },
                        locationContent: {
                            unavailableSourceCard(.location)
                        }
                    )
                    .navigationTitle(String(localized: "automation.wizard.targetPicker.title", defaultValue: "Choose Target"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "common.done", defaultValue: "Done")) {
                                showConditionTargetPicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showScenePicker) {
                NavigationStack {
                    scenePickerPopup
                        .navigationTitle(String(localized: "automation.wizard.scene.pickerTitle", defaultValue: "Choose Scene"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(String(localized: "common.done", defaultValue: "Done")) {
                                    showScenePicker = false
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showInlineActionPicker) {
                SceneActionDraftEditorSheet(
                    actionBundle: $inlineActionBundle,
                    title: String(localized: "automation.wizard.action.title", defaultValue: "Choose an accessory action"),
                    subtitle: String(localized: "automation.wizard.action.subtitle.full", defaultValue: "Select accessories and configure the target state to run when the automation fires."),
                    startWithSelectedFilter: inlineActionBundle.selectedCount > 0
                )
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
        }
    }

    private var automationComposer: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let externalEditNotice {
                openAppleHomeCard(message: externalEditNotice)
            }
            automationNameSection
            ifSection
            conditionsComposerSection
            thenSection
            activationSection
        }
    }

    private var automationNameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPhrase(
                keyword: String(localized: "automation.composer.name", defaultValue: "NAME"),
                text: String(localized: "automation.composer.name.text", defaultValue: "give this automation a clear label")
            )

            TextField(String(localized: "automation.wizard.name.placeholder", defaultValue: "Automation name"), text: $name)
                .font(.headline)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(BrandColor.primary.opacity(0.45), lineWidth: 1.2)
                }
        }
    }

    private var ifSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPhrase(
                keyword: String(localized: "automation.composer.if", defaultValue: "IF"),
                text: String(localized: "automation.composer.if.text", defaultValue: "when any of these events happens")
            )

            if startEvents.isEmpty {
                emptyComposerCard(
                    icon: "sensor.tag.radiowaves.forward",
                    title: String(localized: "automation.composer.trigger.empty.title", defaultValue: "No start event"),
                    subtitle: String(localized: "automation.composer.trigger.empty.subtitle", defaultValue: "Choose at least one event that can start this automation.")
                )
            } else {
                ForEach($startEvents) { $event in
                    VStack(alignment: .leading, spacing: 10) {
                        startEventEditorCard($event)
                        if event.id != startEvents.last?.id {
                            Text(String(localized: "automation.composer.trigger.or", defaultValue: "OR"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(BrandColor.primary)
                                .padding(.leading, 8)
                        }
                    }
                }
            }

            composerActionButton(
                title: String(localized: "automation.composer.trigger.add", defaultValue: "Add Start Event")
            ) {
                triggerPickerSource = nil
                showTriggerTargetPicker = true
            }
        }
    }

    private var conditionsComposerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPhrase(
                keyword: hasConditions ? conditionJoinMode.composerKeyword : String(localized: "automation.composer.conditions.ifNeeded", defaultValue: "AND"),
                text: String(localized: "automation.composer.conditions.text", defaultValue: "only while these checks match")
            )

            VStack(alignment: .leading, spacing: 14) {
                Picker(String(localized: "automation.wizard.conditions.logic", defaultValue: "Condition logic"), selection: $conditionJoinMode) {
                    ForEach(AutomationConditionJoinMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if !hasConditions {
                    Text(String(localized: "automation.wizard.conditions.none", defaultValue: "The automation will run whenever the trigger happens."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ForEach($conditionDrafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            conditionEditorCard($draft)
                            if !isLastCondition(id: draft.id) {
                                Text(conditionJoinMode.composerKeyword)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(BrandColor.primary)
                                    .padding(.leading, 8)
                            }
                        }
                    }

                    ForEach($timeConditionDrafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            timeConditionEditorCard($draft)
                            if !isLastCondition(id: draft.id) {
                                Text(conditionJoinMode.composerKeyword)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(BrandColor.primary)
                                    .padding(.leading, 8)
                            }
                        }
                    }

                    ForEach($presenceConditionDrafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            presenceConditionEditorCard($draft)
                            if !isLastCondition(id: draft.id) {
                                Text(conditionJoinMode.composerKeyword)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(BrandColor.primary)
                                    .padding(.leading, 8)
                            }
                        }
                    }

                    if preservedConditionPredicate != nil {
                        preservedConditionCard
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            composerActionButton(
                title: String(localized: "automation.wizard.conditions.add", defaultValue: "Add condition")
            ) {
                conditionPickerSource = nil
                startAddingCondition()
            }
        }
    }

    private var preservedConditionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist.checked")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "automation.conditions.preserved.title", defaultValue: "HomeKit condition preserved"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "automation.conditions.preserved.subtitle", defaultValue: "This condition exists in Apple Home and will be kept when saving."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                preservedConditionPredicate = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var scheduleSourcePopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.schedule.popup.title", defaultValue: "Schedule"),
                subtitle: String(localized: "automation.schedule.popup.subtitle", defaultValue: "Use a fixed time, sunrise, or sunset as the start event.")
            )

            scheduleSummaryCard

            Button {
                startEvents.append(AutomationStartEventDraft(schedule: scheduleTrigger))
                triggerSource = .time
                triggerSelection = nil
                defaultNameIfNeeded()
                showTriggerTargetPicker = false
            } label: {
                Label(String(localized: "automation.schedule.use", defaultValue: "Use Schedule"), systemImage: "clock.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var timeConditionSourcePopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.timeCondition.popup.title", defaultValue: "Time condition"),
                subtitle: String(localized: "automation.timeCondition.popup.subtitle", defaultValue: "Limit the automation to before or after a time, sunrise, or sunset.")
            )

            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.timeCondition.default.title", defaultValue: "After a time"))
                        .font(.headline)
                    Text(String(localized: "automation.timeCondition.default.subtitle", defaultValue: "Add it now, then configure the exact time in the conditions list."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                timeConditionDrafts.append(AutomationTimeCondition())
                showConditionTargetPicker = false
            } label: {
                Label(String(localized: "automation.timeCondition.add", defaultValue: "Add Time Condition"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var presenceTriggerSourcePopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.presence.popup.trigger.title", defaultValue: "People trigger"),
                subtitle: String(localized: "automation.presence.popup.trigger.subtitle", defaultValue: "Start the automation when people arrive or leave home.")
            )

            presenceSummaryCard(
                iconName: presenceTrigger.kind.iconName,
                title: presenceTrigger.kind.title,
                subtitle: presenceTrigger.summary
            )

            Button {
                startEvents.append(AutomationStartEventDraft(presence: presenceTrigger))
                triggerSource = .people
                triggerSelection = nil
                defaultNameIfNeeded()
                showTriggerTargetPicker = false
            } label: {
                Label(String(localized: "automation.presence.use", defaultValue: "Use People"), systemImage: "person.2.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var presenceConditionSourcePopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.presence.popup.condition.title", defaultValue: "People condition"),
                subtitle: String(localized: "automation.presence.popup.condition.subtitle", defaultValue: "Limit execution based on whether people are home.")
            )

            presenceSummaryCard(
                iconName: "house.fill",
                title: String(localized: "automation.presence.condition.default.title", defaultValue: "Presence at home"),
                subtitle: String(localized: "automation.presence.condition.default.subtitle", defaultValue: "Add it now, then configure the exact presence check in the conditions list.")
            )

            Button {
                presenceConditionDrafts.append(AutomationPresenceCondition())
                showConditionTargetPicker = false
            } label: {
                Label(String(localized: "automation.presence.condition.add", defaultValue: "Add People Condition"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var locationTriggerSourcePopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.location.popup.trigger.title", defaultValue: "Location trigger"),
                subtitle: String(localized: "automation.location.popup.trigger.subtitle", defaultValue: "Start the automation when entering or leaving a geofence.")
            )

            presenceSummaryCard(
                iconName: locationTrigger.kind.iconName,
                title: locationTrigger.kind.title,
                subtitle: locationTriggerDisplaySummary
            )

            Button {
                startEvents.append(AutomationStartEventDraft(location: locationTrigger))
                triggerSource = .location
                triggerSelection = nil
                defaultNameIfNeeded()
                showTriggerTargetPicker = false
            } label: {
                Label(String(localized: "automation.location.use", defaultValue: "Use Location"), systemImage: "location.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private func presenceSummaryCard(iconName: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var presenceTriggerConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.presence.configure.trigger.title", defaultValue: "Configured people trigger"),
                subtitle: presenceTrigger.summary
            )

            Picker(String(localized: "automation.presence.trigger.kind", defaultValue: "Presence event"), selection: $presenceTrigger.kind) {
                ForEach(AutomationPresenceTriggerKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker(String(localized: "automation.presence.userScope", defaultValue: "People"), selection: $presenceTrigger.userScope) {
                ForEach(AutomationPresenceUserScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var locationTriggerConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.location.configure.title", defaultValue: "Configured location"),
                subtitle: locationTriggerDisplaySummary
            )

            Picker(String(localized: "automation.location.trigger.kind", defaultValue: "Location event"), selection: $locationTrigger.kind) {
                ForEach(AutomationLocationTriggerKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    AutomationLocationMapPicker(
                        trigger: $locationTrigger,
                        userLocationRequestID: locationRequestID
                    )
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(locationTrigger.isValid ? BrandColor.primary.opacity(0.35) : Color.secondary.opacity(0.16), lineWidth: 1)
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            locationRequestID += 1
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(BrandColor.primary)
                                .frame(width: 42, height: 42)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "automation.location.currentLocation", defaultValue: "Use current location"))

                        if locationTrigger.isValid {
                            Label("\(Int(locationTrigger.radius.rounded())) m", systemImage: "circle.dashed")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .padding(12)
                }

                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(BrandColor.primary)
                    Text(locationTriggerDisplaySummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(locationTrigger.isValid ? .secondary : BrandColor.primary)
                    Spacer()
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "automation.location.radius", defaultValue: "Radius"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(locationTrigger.radius.rounded())) m")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BrandColor.primary)
                    }
                    Slider(value: $locationTrigger.radius, in: 50...1000, step: 10)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scheduleConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                String(localized: "automation.schedule.configure.title", defaultValue: "Configured schedule"),
                subtitle: scheduleTrigger.summary
            )

            Picker(String(localized: "automation.schedule.kind", defaultValue: "Schedule type"), selection: $scheduleTrigger.kind) {
                ForEach(AutomationScheduleKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch scheduleTrigger.kind {
            case .fixedTime:
                DatePicker(
                    String(localized: "automation.schedule.time", defaultValue: "Time"),
                    selection: $scheduleTrigger.time,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)

            case .sunrise, .sunset:
                Stepper(value: $scheduleTrigger.offsetMinutes, in: -120...120, step: 5) {
                    HStack {
                        Label(String(localized: "automation.schedule.offset", defaultValue: "Offset"), systemImage: "plusminus")
                        Spacer()
                        Text(scheduleTrigger.offsetSummary)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BrandColor.primary)
                    }
                }
            }

            scheduleWeekdayPicker
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scheduleSummaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: scheduleTrigger.kind.iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(scheduleTrigger.kind.title)
                    .font(.headline)
                Text(scheduleTrigger.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var scheduleWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "automation.schedule.days", defaultValue: "Days"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ForEach(AutomationScheduleWeekday.allCases) { day in
                    let isSelected = scheduleTrigger.weekdays.contains(day)
                    Button {
                        toggleScheduleWeekday(day)
                    } label: {
                        Text(day.shortTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(width: 36, height: 34)
                            .background(
                                Capsule().fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func startEventEditorCard(_ event: Binding<AutomationStartEventDraft>) -> some View {
        switch event.wrappedValue.kind {
        case .accessory:
            if let selection = Binding(event.selection) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        selectedCapabilityConfiguration(
                            title: String(localized: "automation.wizard.trigger.configured", defaultValue: "Configured trigger"),
                            selection: selection,
                            primaryTitle: nil,
                            primaryIcon: nil,
                            primaryAction: nil
                        )
                    }
                    removeStartEventButton(id: event.wrappedValue.id)
                }
            }
        case .time:
            scheduleStartEventCard(event)
        case .people:
            presenceStartEventCard(event)
        case .location:
            locationStartEventCard(event)
        }
    }

    private func scheduleStartEventCard(_ event: Binding<AutomationStartEventDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            startEventCardHeader(
                iconName: event.wrappedValue.iconName,
                title: String(localized: "automation.schedule.configure.title", defaultValue: "Configured schedule"),
                subtitle: event.wrappedValue.schedule.summary,
                id: event.wrappedValue.id
            )

            Picker(String(localized: "automation.schedule.kind", defaultValue: "Schedule type"), selection: event.schedule.kind) {
                ForEach(AutomationScheduleKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch event.wrappedValue.schedule.kind {
            case .fixedTime:
                DatePicker(
                    String(localized: "automation.schedule.time", defaultValue: "Time"),
                    selection: event.schedule.time,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)

            case .sunrise, .sunset:
                Stepper(value: event.schedule.offsetMinutes, in: -120...120, step: 5) {
                    HStack {
                        Label(String(localized: "automation.schedule.offset", defaultValue: "Offset"), systemImage: "plusminus")
                        Spacer()
                        Text(event.wrappedValue.schedule.offsetSummary)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BrandColor.primary)
                    }
                }
            }

            scheduleWeekdayPicker(for: event)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func presenceStartEventCard(_ event: Binding<AutomationStartEventDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            startEventCardHeader(
                iconName: event.wrappedValue.iconName,
                title: String(localized: "automation.presence.configure.trigger.title", defaultValue: "Configured people trigger"),
                subtitle: event.wrappedValue.presence.summary,
                id: event.wrappedValue.id
            )

            Picker(String(localized: "automation.presence.trigger.kind", defaultValue: "Presence event"), selection: event.presence.kind) {
                ForEach(AutomationPresenceTriggerKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker(String(localized: "automation.presence.userScope", defaultValue: "People"), selection: event.presence.userScope) {
                ForEach(AutomationPresenceUserScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func locationStartEventCard(_ event: Binding<AutomationStartEventDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            startEventCardHeader(
                iconName: event.wrappedValue.iconName,
                title: String(localized: "automation.location.configure.title", defaultValue: "Configured location"),
                subtitle: event.wrappedValue.locationDisplaySummary,
                id: event.wrappedValue.id
            )

            Picker(String(localized: "automation.location.trigger.kind", defaultValue: "Location event"), selection: event.location.kind) {
                ForEach(AutomationLocationTriggerKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    AutomationLocationMapPicker(
                        trigger: event.location,
                        userLocationRequestID: locationRequestID
                    )
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(event.wrappedValue.location.isValid ? BrandColor.primary.opacity(0.35) : Color.secondary.opacity(0.16), lineWidth: 1)
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            locationRequestID += 1
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(BrandColor.primary)
                                .frame(width: 42, height: 42)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "automation.location.currentLocation", defaultValue: "Use current location"))

                        if event.wrappedValue.location.isValid {
                            Label("\(Int(event.wrappedValue.location.radius.rounded())) m", systemImage: "circle.dashed")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .padding(12)
                }

                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(BrandColor.primary)
                    Text(event.wrappedValue.locationDisplaySummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(event.wrappedValue.location.isValid ? .secondary : BrandColor.primary)
                    Spacer()
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "automation.location.radius", defaultValue: "Radius"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(event.wrappedValue.location.radius.rounded())) m")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BrandColor.primary)
                    }
                    Slider(value: event.location.radius, in: 50...1000, step: 10)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func startEventCardHeader(iconName: String, title: String, subtitle: String, id: UUID) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                removeStartEvent(id: id)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func removeStartEventButton(id: UUID) -> some View {
        Button {
            removeStartEvent(id: id)
        } label: {
            Label(String(localized: "automation.composer.trigger.remove", defaultValue: "Remove Start Event"), systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func scheduleWeekdayPicker(for event: Binding<AutomationStartEventDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "automation.schedule.days", defaultValue: "Days"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ForEach(AutomationScheduleWeekday.allCases) { day in
                    let isSelected = event.wrappedValue.schedule.weekdays.contains(day)
                    Button {
                        toggleScheduleWeekday(day, for: event)
                    } label: {
                        Text(day.shortTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(width: 36, height: 34)
                            .background(
                                Capsule().fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var thenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPhrase(
                keyword: String(localized: "automation.composer.then", defaultValue: "THEN"),
                text: String(localized: "automation.composer.then.text", defaultValue: "run a scene or set accessories")
            )

            if let unmanagedActionNotice {
                openAppleHomeCard(message: unmanagedActionNotice)
            } else if let selectedScene {
                selectedSceneCard(selectedScene)
            } else if !inlineActionBundle.isEmpty {
                inlineActionBundleCard
            } else if !inlinePowerActions.isEmpty {
                inlinePowerActionsCard
            } else {
                emptyComposerCard(
                    icon: "wand.and.sparkles",
                    title: String(localized: "automation.composer.action.empty.title", defaultValue: "No action selected"),
                    subtitle: String(localized: "automation.composer.action.empty.subtitle", defaultValue: "Choose a scene or add an accessory action.")
                )
            }

            HStack(spacing: 10) {
                composerInlineActionButton(
                    title: selectedScene == nil
                    ? String(localized: "automation.composer.scene.add", defaultValue: "Choose Scene")
                    : String(localized: "automation.composer.scene.change", defaultValue: "Change Scene"),
                    icon: "wand.and.sparkles"
                ) {
                    showScenePicker = true
                }

                composerInlineActionButton(
                    title: String(localized: "automation.composer.action.addAccessory", defaultValue: "Add Accessory"),
                    icon: inlineActionBundle.isEmpty ? "plus.circle.fill" : "slider.horizontal.3"
                ) {
                    selectedSceneID = nil
                    editingSceneFallback = nil
                    inlinePowerActions = []
                    showInlineActionPicker = true
                }
            }
            .disabled(unmanagedActionNotice != nil)
            .opacity(unmanagedActionNotice == nil ? 1 : 0.5)
        }
    }

    private func openAppleHomeCard(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up.forward.app")
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "automation.existing.openHome.title", defaultValue: "Apri in Apple Home"))
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = URL(string: "x-apple-homekit://"), UIApplication.shared.canOpenURL(url) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label(String(localized: "automation.existing.openHome.short", defaultValue: "Apri in Apple Home"), systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(BrandColor.primary.opacity(0.28), lineWidth: 1)
        }
    }

    private var inlineActionBundleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.composer.actions.inline.title", defaultValue: "Accessory actions"))
                        .font(.headline)
                    Text(String(format: String(localized: "automation.composer.actions.inline.count",
                                               defaultValue: "%d selected"),
                                inlineActionBundle.selectedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showInlineActionPicker = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    clearInlineActionBundleSelection()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(inlineActionBundleSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var inlinePowerActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($inlinePowerActions) { $action in
                HStack(spacing: 12) {
                    Image(systemName: "power")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .frame(width: 42, height: 42)
                        .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.accessoryName)
                            .font(.headline)
                        Text(action.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $action.powerOn)
                        .labelsHidden()
                        .tint(BrandColor.primary)

                    Button {
                        inlinePowerActions.removeAll { $0.id == action.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 34, height: 34)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPhrase(
                keyword: String(localized: "automation.composer.done", defaultValue: "DONE"),
                text: String(localized: "automation.composer.done.text", defaultValue: "activate it when ready, then save"),
                keywordColor: Color(.systemRed)
            )

            Toggle(isOn: $activateAutomation) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.composer.activate", defaultValue: "Activate Automation"))
                        .font(.headline)
                    Text(String(localized: "automation.composer.activate.subtitle", defaultValue: "When enabled, HomeKit can run this automation as soon as it is saved."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var composerBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text(String(localized: "common.cancel", defaultValue: "Cancel"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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
                    Text(String(localized: "common.save", defaultValue: "Save"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(BrandColor.primary)
            .disabled(!canSave || isSaving)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func composerActionButton(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 210)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(BrandColor.primary)
        }
    }

    private func composerInlineActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(BrandColor.primary)
    }

    private func sectionPhrase(keyword: String, text: String, keywordColor: Color = BrandColor.primary) -> some View {
        HStack(spacing: 6) {
            Text(keyword)
                .font(.headline.weight(.bold))
                .foregroundStyle(keywordColor)
            Text(text)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyComposerCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

            contextStrip
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var contextStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                contextChip(
                    title: String(localized: "automation.wizard.context.trigger", defaultValue: "Trigger"),
                    value: startEventSummary,
                    iconName: "sensor.tag.radiowaves.forward",
                    isComplete: hasConfiguredTrigger,
                    isCurrent: step == .trigger
                )

                contextChip(
                    title: String(localized: "automation.wizard.context.conditions", defaultValue: "Conditions"),
                    value: !hasConditions
                    ? String(localized: "automation.wizard.context.optional", defaultValue: "Optional")
                    : "\(conditionDrafts.count + timeConditionDrafts.count + presenceConditionDrafts.count + (preservedConditionPredicate == nil ? 0 : 1)) - \(conditionJoinMode.shortTitle)",
                    iconName: "checklist",
                    isComplete: hasConditions,
                    isCurrent: step == .conditions
                )

                contextChip(
                    title: String(localized: "automation.wizard.context.scene", defaultValue: "Scene"),
                    value: selectedScene?.name ??
                    (!inlineActionBundle.isEmpty
                     ? "\(inlineActionBundle.selectedCount) \(String(localized: "automation.wizard.summary.accessoryActions", defaultValue: "accessory actions"))"
                     : (!inlinePowerActions.isEmpty ? "\(inlinePowerActions.count) actions" : String(localized: "automation.wizard.context.missing", defaultValue: "Not set"))),
                    iconName: "wand.and.sparkles",
                    isComplete: hasThenTarget,
                    isCurrent: step == .scene
                )

                contextChip(
                    title: String(localized: "automation.wizard.context.review", defaultValue: "Review"),
                    value: canSave
                    ? String(localized: "automation.wizard.context.ready", defaultValue: "Ready")
                    : String(localized: "automation.wizard.context.pending", defaultValue: "Pending"),
                    iconName: "checkmark.seal",
                    isComplete: canSave,
                    isCurrent: step == .summary
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var triggerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(
                String(localized: "automation.wizard.trigger.source.title", defaultValue: "Choose what starts the automation"),
                subtitle: String(localized: "automation.wizard.trigger.source.subtitle", defaultValue: "The wizard is structured by trigger source, so more HomeKit trigger types can fit here later.")
            )

            HStack(alignment: .top, spacing: 16) {
                sourceSidebar(selectedSource: $triggerSource)
                    .frame(width: 260)

                triggerDetailContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var triggerDetailContent: some View {
        if triggerSource != .accessory {
            unavailableSourceCard(triggerSource)
        } else if capabilities.isEmpty {
            ContentUnavailableView(
                String(localized: "automation.wizard.noCapabilities.title", defaultValue: "No compatible triggers"),
                systemImage: "sensor.tag.radiowaves.forward",
                description: Text(String(localized: "automation.wizard.noCapabilities.description", defaultValue: "No readable HomeKit characteristics are available for automation triggers."))
            )
        } else {
            capabilityPickerPanel(
                title: String(localized: "automation.wizard.trigger.browser.title", defaultValue: "Accessory triggers"),
                subtitle: String(localized: "automation.wizard.trigger.browser.subtitle", defaultValue: "Choose the accessory state, then configure the operator and value."),
                selection: $triggerSelection,
                configuredTitle: String(localized: "automation.wizard.trigger.configured", defaultValue: "Configured trigger"),
                chooseAction: { showTriggerTargetPicker = true }
            )
        }
    }

    private var conditionsStep: some View {
        conditionsOverview
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

                    ForEach($conditionDrafts) { $draft in
                        conditionEditorCard($draft)
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
                value: startEvents.isEmpty ? "-" : startEvents.map(\.summary).joined(separator: "\n")
            )

            summaryCard(
                icon: "checklist",
                title: String(localized: "automation.wizard.summary.conditions", defaultValue: "Conditions"),
                value: !hasConditions
                    ? String(localized: "automation.wizard.summary.noConditions", defaultValue: "No conditions")
                    : "\(conditionJoinMode.summaryTitle)\n\((conditionDrafts.map { selectionSummary($0.selection) } + timeConditionDrafts.map(\.summary) + presenceConditionDrafts.map(\.summary) + (preservedConditionPredicate == nil ? [] : [String(localized: "automation.conditions.preserved.title", defaultValue: "HomeKit condition preserved")])).joined(separator: "\n"))"
            )

            summaryCard(
                icon: "wand.and.sparkles",
                title: String(localized: "automation.wizard.summary.scene", defaultValue: "Action"),
                value: selectedScene?.name ??
                (!inlineActionBundle.isEmpty
                 ? "\(inlineActionBundle.selectedCount) \(String(localized: "automation.wizard.summary.accessoryActions", defaultValue: "accessory actions"))\n\(inlineActionBundleSummary)"
                 : inlinePowerActions.map { "\($0.accessoryName) - \($0.powerOn ? "On" : "Off")" }.joined(separator: "\n"))
            )
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    step = step.previous ?? step
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

    private func contextChip(
        title: String,
        value: String,
        iconName: String,
        isComplete: Bool,
        isCurrent: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isComplete ? .green : (isCurrent ? BrandColor.primary : Color.secondary))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isCurrent ? AnyShapeStyle(BrandColor.primary.opacity(0.12)) : AnyShapeStyle(Color(.secondarySystemFill)))
        )
        .overlay {
            Capsule()
                .strokeBorder(isCurrent ? BrandColor.primary.opacity(0.35) : Color.secondary.opacity(0.12), lineWidth: 1)
        }
    }

    private func sourceSidebar(selectedSource: Binding<AutomationTriggerSourceKind>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "automation.wizard.sources.title", defaultValue: "Sources"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(AutomationTriggerSourceKind.allCases) { source in
                let isSelected = selectedSource.wrappedValue == source
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedSource.wrappedValue = source
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: source.iconName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : BrandColor.primary)
                            .frame(width: 34, height: 34)
                            .background(
                                isSelected
                                ? AnyShapeStyle(BrandColor.heroGradient)
                                : AnyShapeStyle(BrandColor.primary.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if !source.isAvailable {
                                    Text(String(localized: "automation.wizard.source.future", defaultValue: "Soon"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                            }

                            Text(source.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(BrandColor.primary.opacity(0.10)) : AnyShapeStyle(.regularMaterial))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? BrandColor.primary.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func unavailableSourceCard(_ source: AutomationTriggerSourceKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(source.title, systemImage: source.iconName)
                .font(.headline)
            Text(String(localized: "automation.wizard.source.unavailable", defaultValue: "This source is reserved in the flow, but creation is not implemented yet. Accessory events are available now."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func targetTypePickerPopup<AccessoryContent: View, TimeContent: View, PeopleContent: View, LocationContent: View>(
        selectedSource: Binding<AutomationTriggerSourceKind?>,
        @ViewBuilder accessoryContent: () -> AccessoryContent,
        @ViewBuilder timeContent: () -> TimeContent,
        @ViewBuilder peopleContent: () -> PeopleContent,
        @ViewBuilder locationContent: () -> LocationContent
    ) -> some View {
        Group {
            if let source = selectedSource.wrappedValue {
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedSource.wrappedValue = nil
                        }
                    } label: {
                        Label(String(localized: "common.back", defaultValue: "Back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .tint(BrandColor.primary)

                    if source == .accessory {
                        accessoryContent()
                    } else if source == .time {
                        timeContent()
                    } else if source == .people {
                        peopleContent()
                    } else if source == .location {
                        locationContent()
                    } else {
                        unavailableSourceCard(source)
                    }
                }
                .padding(16)
            } else {
                targetTypeSelectionGrid(selectedSource: selectedSource)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func targetTypeSelectionGrid(selectedSource: Binding<AutomationTriggerSourceKind?>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(
                    String(localized: "automation.wizard.targetType.title", defaultValue: "Choose type"),
                    subtitle: String(localized: "automation.wizard.targetType.subtitle", defaultValue: "Select the kind of trigger or condition you want to configure.")
                )

                LazyVStack(spacing: 10) {
                    ForEach(AutomationTriggerSourceKind.allCases) { source in
                        targetTypeRow(source, selectedSource: selectedSource)
                    }
                }
            }
            .padding(16)
        }
    }

    private func targetTypeRow(
        _ source: AutomationTriggerSourceKind,
        selectedSource: Binding<AutomationTriggerSourceKind?>
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedSource.wrappedValue = source
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: source.iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(source.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !source.isAvailable {
                            Text(String(localized: "automation.wizard.source.future", defaultValue: "Soon"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }

                    Text(source.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var scenePickerPopup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    String(localized: "automation.wizard.scene.title", defaultValue: "Choose the scene to run"),
                    subtitle: String(localized: "automation.wizard.scene.subtitle", defaultValue: "Select one scene. The automation will execute it when the IF and AND sections match.")
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
                            scenePickerRow(scene)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var inlineActionPickerPopup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    String(localized: "automation.wizard.action.title", defaultValue: "Choose an accessory action"),
                    subtitle: String(localized: "automation.wizard.action.subtitle", defaultValue: "First version supports On/Off actions.")
                )

                if inlinePowerActionCandidates.isEmpty {
                    ContentUnavailableView(
                        String(localized: "automation.wizard.action.empty", defaultValue: "No On/Off accessories"),
                        systemImage: "power",
                        description: Text(String(localized: "automation.wizard.action.empty.description", defaultValue: "All compatible accessories are already included, or none are available."))
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(inlinePowerActionCandidates) { action in
                            inlineActionPickerRow(action)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func inlineActionPickerRow(_ action: AutomationInlinePowerAction) -> some View {
        Button {
            selectedSceneID = nil
            editingSceneFallback = nil
            inlinePowerActions.append(action)
            clearInlineActionBundleSelection()
            showInlineActionPicker = false
            defaultNameIfNeeded()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(action.roomName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func capabilityPickerPanel(
        title: String,
        subtitle: String,
        selection: Binding<AutomationCapabilitySelection?>,
        configuredTitle: String,
        primaryTitle: String? = nil,
        primaryIcon: String? = nil,
        primaryAction: (() -> Void)? = nil,
        chooseAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title, subtitle: subtitle)

            selectionStatusCard(selection: selection.wrappedValue)

            Button(action: chooseAction) {
                Label(
                    selection.wrappedValue == nil
                    ? String(localized: "automation.wizard.target.choose", defaultValue: "Choose target")
                    : String(localized: "automation.wizard.target.change", defaultValue: "Change target"),
                    systemImage: "square.grid.2x2"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)

            if let binding = concreteSelectionBinding(selection) {
                selectedCapabilityConfiguration(
                    title: configuredTitle,
                    selection: binding,
                    primaryTitle: primaryTitle,
                    primaryIcon: primaryIcon,
                    primaryAction: primaryAction
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "automation.wizard.accessoryPicker.emptySelection.title", defaultValue: "Choose an accessory state"), systemImage: "hand.tap")
                        .font(.headline)
                    Text(String(localized: "automation.wizard.accessoryPicker.emptySelection.subtitle", defaultValue: "Open the target picker, filter the available accessories, then configure the selected value here."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func capabilityPickerPopup(
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
        ScrollView {
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
                    capabilityChoiceBoard(
                        items: items,
                        selectedID: selectedID,
                        onSelect: onSelect
                    )
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func selectionStatusCard(selection: AutomationCapabilitySelection?) -> some View {
        HStack(spacing: 12) {
            if let selection {
                capabilityIcon(selection.capability, isSelected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.wizard.selection.current", defaultValue: "Current selection"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(selection.capability.accessoryName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(selection.capability.roomName) - \(selection.capability.title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "hand.tap")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.wizard.selection.current", defaultValue: "Current selection"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(String(localized: "automation.wizard.selection.empty", defaultValue: "Choose a target"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "automation.wizard.selection.emptySubtitle", defaultValue: "Use the filters below, then select one of the available options."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(BrandColor.primary.opacity(selection == nil ? 0.12 : 0.35), lineWidth: 1)
        }
    }

    private func capabilityChoiceBoard(
        items: [AutomationCharacteristicCapability],
        selectedID: String?,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "automation.wizard.selection.options", defaultValue: "Available options"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(roomNames(from: items), id: \.self) { room in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(room)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        ForEach(accessoryGroups(in: room, from: items)) { group in
                            capabilityAccessoryGroupCard(
                                group,
                                selectedID: selectedID,
                                onSelect: onSelect
                            )
                        }
                    }
                }
            }
        }
    }

    private func capabilityChoiceCard(
        _ capability: AutomationCharacteristicCapability,
        isSelected: Bool,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        Button {
            onSelect(capability)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    capabilityIcon(capability, isSelected: isSelected)

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? BrandColor.primary : Color.secondary.opacity(0.45))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(capability.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(capability.roomName) - \(capability.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(AutomationCapabilityCategory.category(for: capability).title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? BrandColor.primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isSelected ? BrandColor.primary.opacity(0.12) : Color(.tertiarySystemFill))
                    )
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(BrandColor.primary.opacity(0.10)) : AnyShapeStyle(.regularMaterial))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? BrandColor.primary.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectedCapabilityConfiguration(
        title: String,
        selection: Binding<AutomationCapabilitySelection>,
        primaryTitle: String?,
        primaryIcon: String?,
        primaryAction: (() -> Void)?
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

                if let primaryTitle, let primaryIcon, let primaryAction {
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

                            ForEach(accessoryGroups(in: room, from: items)) { group in
                                capabilityAccessoryGroupCard(
                                    group,
                                    selectedID: selectedID,
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

    private func accessoryGroups(
        in room: String,
        from items: [AutomationCharacteristicCapability]
    ) -> [AutomationCapabilityAccessoryGroup] {
        let roomItems = items.filter { $0.roomName == room }
        let grouped = Dictionary(grouping: roomItems) { capability in
            capability.accessoryID
        }

        return grouped.compactMap { accessoryID, capabilities in
            guard let first = capabilities.first else { return nil }
            return AutomationCapabilityAccessoryGroup(
                id: "\(room)-\(accessoryID.uuidString)",
                accessoryID: accessoryID,
                accessoryName: first.accessoryName,
                roomName: first.roomName,
                capabilities: capabilities.sorted {
                    if $0.title == $1.title {
                        return $0.id < $1.id
                    }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted {
            if $0.accessoryName == $1.accessoryName {
                return $0.id < $1.id
            }
            return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
        }
    }

    private func capabilityAccessoryGroupCard(
        _ group: AutomationCapabilityAccessoryGroup,
        selectedID: String?,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.accessoryName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if group.capabilities.count > 1 {
                    Text(String(format: String(localized: "automation.wizard.accessoryGroup.capabilitiesCount",
                                               defaultValue: "%d options"),
                                group.capabilities.count))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }

            ForEach(group.capabilities) { capability in
                capabilityRowButton(
                    capability,
                    isSelected: selectedID == capability.id,
                    showsAccessoryName: false,
                    onSelect: onSelect
                )
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(group.capabilities.contains { $0.id == selectedID } ? BrandColor.primary.opacity(0.35) : Color.secondary.opacity(0.10), lineWidth: 1)
        }
    }

    private func capabilityRowButton(
        _ capability: AutomationCharacteristicCapability,
        isSelected: Bool,
        showsAccessoryName: Bool = true,
        onSelect: @escaping (AutomationCharacteristicCapability) -> Void
    ) -> some View {
        Button {
            onSelect(capability)
        } label: {
            HStack(spacing: 12) {
                capabilityIcon(capability, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 4) {
                    if showsAccessoryName {
                        Text(capability.accessoryName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(capability.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(capability.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
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
                    .foregroundStyle(isSelected ? BrandColor.primary : Color.secondary.opacity(0.55))
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

    private func conditionEditorCard(_ draft: Binding<AutomationConditionDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                capabilityIcon(draft.wrappedValue.selection.capability, isSelected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.wrappedValue.selection.capability.accessoryName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(draft.wrappedValue.selection.capability.roomName) - \(draft.wrappedValue.selection.capability.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(role: .destructive) {
                    conditionDrafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            capabilityValueEditor(selection: draft.selection)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func timeConditionEditorCard(_ draft: Binding<AutomationTimeCondition>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: draft.wrappedValue.kind.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.heroGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.timeCondition.title", defaultValue: "Time condition"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(draft.wrappedValue.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(role: .destructive) {
                    timeConditionDrafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            Picker(
                String(localized: "automation.timeCondition.relation", defaultValue: "Relation"),
                selection: Binding {
                    draft.wrappedValue.relation
                } set: { newValue in
                    draft.wrappedValue.relation = newValue
                    if newValue == .between {
                        normalizeBetweenTimeCondition(draft)
                    }
                }
            ) {
                ForEach(AutomationTimeConditionRelation.allCases) { relation in
                    Text(relation.title).tag(relation)
                }
            }
            .pickerStyle(.segmented)

            if draft.wrappedValue.relation == .between {
                betweenTimePicker(
                    title: String(localized: "automation.timeCondition.boundary.start", defaultValue: "Start"),
                    selection: draft.time
                )

                betweenTimePicker(
                    title: String(localized: "automation.timeCondition.boundary.end", defaultValue: "End"),
                    selection: draft.endTime
                )
            } else {
                Picker(String(localized: "automation.timeCondition.kind", defaultValue: "Time source"), selection: draft.kind) {
                    ForEach(AutomationTimeConditionKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.iconName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                timeBoundaryEditor(
                    title: String(localized: "automation.schedule.time", defaultValue: "Time"),
                    kind: draft.kind,
                    time: draft.time,
                    offsetMinutes: draft.offsetMinutes
                )
            }
        }
        .onAppear {
            normalizeBetweenTimeCondition(draft)
        }
        .onChange(of: draft.wrappedValue.relation) { _, relation in
            if relation == .between {
                normalizeBetweenTimeCondition(draft)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func betweenTimePicker(title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            DatePicker(
                title,
                selection: selection,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .clipped()
        }
    }

    private func normalizeBetweenTimeCondition(_ draft: Binding<AutomationTimeCondition>) {
        guard draft.wrappedValue.relation == .between else { return }
        draft.wrappedValue.kind = .fixedTime
        draft.wrappedValue.endKind = .fixedTime
        draft.wrappedValue.offsetMinutes = 0
        draft.wrappedValue.endOffsetMinutes = 0
    }

    @ViewBuilder
    private func timeBoundaryEditor(
        title: String,
        kind: Binding<AutomationTimeConditionKind>,
        time: Binding<Date>,
        offsetMinutes: Binding<Int>
    ) -> some View {
        switch kind.wrappedValue {
        case .fixedTime:
            DatePicker(
                title,
                selection: time,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)

        case .sunrise, .sunset:
            Stepper(value: offsetMinutes, in: -120...120, step: 5) {
                HStack {
                    Label(title, systemImage: "plusminus")
                    Spacer()
                    Text(offsetText(for: offsetMinutes.wrappedValue))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(BrandColor.primary)
                }
            }
        }
    }

    private func offsetText(for offsetMinutes: Int) -> String {
        if offsetMinutes == 0 {
            return String(localized: "automation.schedule.offset.none", defaultValue: "No offset")
        }

        let absolute = abs(offsetMinutes)
        if offsetMinutes < 0 {
            return String(format: String(localized: "automation.schedule.offset.before", defaultValue: "%d min before"), absolute)
        }
        return String(format: String(localized: "automation.schedule.offset.after", defaultValue: "%d min after"), absolute)
    }

    private func presenceConditionEditorCard(_ draft: Binding<AutomationPresenceCondition>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: draft.wrappedValue.kind.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(BrandColor.heroGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "automation.presence.condition.title", defaultValue: "People condition"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(draft.wrappedValue.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(role: .destructive) {
                    presenceConditionDrafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            Picker(String(localized: "automation.presence.condition.kind", defaultValue: "Presence state"), selection: draft.kind) {
                ForEach(AutomationPresenceConditionKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.iconName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker(String(localized: "automation.presence.userScope", defaultValue: "People"), selection: draft.userScope) {
                ForEach(AutomationPresenceUserScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
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
                booleanValueEditor(
                    selection: selection,
                    activeLabel: activeLabel,
                    inactiveLabel: inactiveLabel
                )

            case .numeric(let unit, let range, let step):
                numericEditor(selection: selection, unit: unit, range: range, step: step)

            case .state(let options):
                stateValueEditor(selection: selection, options: options)
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
            if isBrightnessCapability(selection.wrappedValue.capability, unit: unit, range: allowedRange) {
                LightBrightnessSlider(
                    brightness: numericBinding(selection),
                    isEnabled: true,
                    isDimmed: false,
                    titleFont: .caption.weight(.semibold),
                    height: 54,
                    cornerRadius: 15,
                    onDragChanged: { _ in },
                    onEditingEnded: { value in
                        selection.wrappedValue.targetValue = .number(value)
                    }
                )
            } else {
                automationNumericSlider(
                    title: String(localized: "automation.wizard.threshold", defaultValue: "Threshold"),
                    value: numericBinding(selection),
                    range: allowedRange,
                    step: increment,
                    unit: unit
                )
            }
        }
    }

    private func booleanValueEditor(
        selection: Binding<AutomationCapabilitySelection>,
        activeLabel: String,
        inactiveLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "automation.wizard.value", defaultValue: "Value"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                booleanValueButton(
                    title: activeLabel,
                    iconName: "checkmark.circle.fill",
                    isSelected: boolBinding(selection).wrappedValue
                ) {
                    selection.wrappedValue.targetValue = .bool(true)
                }

                booleanValueButton(
                    title: inactiveLabel,
                    iconName: "circle",
                    isSelected: !boolBinding(selection).wrappedValue
                ) {
                    selection.wrappedValue.targetValue = .bool(false)
                }
            }
        }
    }

    private func booleanValueButton(
        title: String,
        iconName: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(.regularMaterial))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? BrandColor.primary.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func stateValueEditor(
        selection: Binding<AutomationCapabilitySelection>,
        options: [AutomationCapabilityStateOption]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "automation.wizard.value", defaultValue: "Value"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 8) {
                ForEach(options) { option in
                    stateValueRow(
                        option,
                        isSelected: stateBinding(selection).wrappedValue == option.rawValue
                    ) {
                        selection.wrappedValue.targetValue = .state(option.rawValue)
                    }
                }
            }
        }
    }

    private func stateValueRow(
        _ option: AutomationCapabilityStateOption,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: option.iconName ?? "circle.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : BrandColor.primary)
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected
                        ? AnyShapeStyle(BrandColor.heroGradient)
                        : AnyShapeStyle(BrandColor.primary.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? BrandColor.primary : Color.secondary.opacity(0.45))
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? BrandColor.primary.opacity(0.45) : Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func automationNumericSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedNumericValue(value.wrappedValue, unit: unit))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }

            GeometryReader { geo in
                let normalized = normalizedValue(value.wrappedValue, in: range)
                let fillWidth = geo.size.width * normalized

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.thinMaterial)

                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(BrandColor.primary.opacity(0.78))
                        .frame(width: max(0, fillWidth))
                        .animation(.spring(response: 0.35), value: fillWidth)

                    HStack {
                        Spacer()
                        Text(formattedNumericValue(value.wrappedValue, unit: unit))
                            .font(.headline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(fillWidth > geo.size.width / 2 ? .white : .primary)
                            .contentTransition(.numericText())
                        Spacer()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let raw = range.lowerBound + (drag.location.x / geo.size.width) * (range.upperBound - range.lowerBound)
                            let stepped = (raw / step).rounded() * step
                            value.wrappedValue = min(range.upperBound, max(range.lowerBound, stepped))
                        }
                )
            }
            .frame(height: 54)

            HStack {
                Text(formattedNumericValue(range.lowerBound, unit: unit))
                Spacer()
                Text(formattedNumericValue(range.upperBound, unit: unit))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func isBrightnessCapability(
        _ capability: AutomationCharacteristicCapability,
        unit: String,
        range: ClosedRange<Double>
    ) -> Bool {
        capability.title.localizedCaseInsensitiveContains("brightness") &&
        unit == "%" &&
        range.lowerBound <= 0 &&
        range.upperBound >= 100
    }

    private func normalizedValue(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func formattedNumericValue(_ value: Double, unit: String) -> String {
        if value.rounded() == value {
            return "\(Int(value))\(unit)"
        }
        return "\(String(format: "%.1f", value))\(unit)"
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func sceneRow(_ scene: SceneItem) -> some View {
        Button {
            selectedSceneID = scene.id
            inlinePowerActions = []
            clearInlineActionBundleSelection()
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
                    .foregroundStyle(selectedSceneID == scene.id ? BrandColor.primary : Color.secondary.opacity(0.55))
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

    private func selectedSceneCard(_ scene: SceneItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AnyShapeStyle(BrandColor.heroGradient))
                    .frame(width: 42, height: 42)
                Image(systemName: scene.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "action") : String(localized: "count.action.plural", defaultValue: "actions"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func scenePickerRow(_ scene: SceneItem) -> some View {
        Button {
            selectedSceneID = scene.id
            inlinePowerActions = []
            clearInlineActionBundleSelection()
            defaultNameIfNeeded()
            showScenePicker = false
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
                    .foregroundStyle(selectedSceneID == scene.id ? BrandColor.primary : Color.secondary.opacity(0.55))
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

    private func concreteSelectionBinding(
        _ selection: Binding<AutomationCapabilitySelection?>
    ) -> Binding<AutomationCapabilitySelection>? {
        guard let fallback = selection.wrappedValue else { return nil }
        return Binding {
            selection.wrappedValue ?? fallback
        } set: { newValue in
            selection.wrappedValue = newValue
        }
    }

    private func roomNames(from items: [AutomationCharacteristicCapability]) -> [String] {
        Array(Set(items.map(\.roomName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func startAddingCondition() {
        showConditionTargetPicker = true
    }

    private func clearInlineActionBundleSelection() {
        for index in inlineActionBundle.lightDrafts.indices {
            inlineActionBundle.lightDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.outletDrafts.indices {
            inlineActionBundle.outletDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.switchDrafts.indices {
            inlineActionBundle.switchDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.windowCoveringDrafts.indices {
            inlineActionBundle.windowCoveringDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.thermostatDrafts.indices {
            inlineActionBundle.thermostatDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.airPurifierDrafts.indices {
            inlineActionBundle.airPurifierDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.fanDrafts.indices {
            inlineActionBundle.fanDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.humidifierDrafts.indices {
            inlineActionBundle.humidifierDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.securitySystemDrafts.indices {
            inlineActionBundle.securitySystemDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.doorLockDrafts.indices {
            inlineActionBundle.doorLockDrafts[index].isIncluded = false
        }
        for index in inlineActionBundle.garageDoorDrafts.indices {
            inlineActionBundle.garageDoorDrafts[index].isIncluded = false
        }
    }

    private func save() {
        guard hasThenTarget else { return }
        isSaving = true
        Task {
            do {
                let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let creationName = editingItem == nil
                    ? finalName
                    : "__HomeFloorplan_Edit_\(UUID().uuidString.prefix(8))"
                let createdItem = try await automationsService.createSceneAutomation(
                    name: creationName,
                    startEvents: startEvents.compactMap(\.startEvent),
                    conditions: conditionDrafts.map(\.selection),
                    timeConditions: timeConditionDrafts,
                    presenceConditions: presenceConditionDrafts,
                    conditionJoinMode: conditionJoinMode,
                    scene: selectedScene,
                    inlinePowerActions: selectedScene == nil && inlineActionBundle.isEmpty ? inlinePowerActions : [],
                    inlineActions: selectedScene == nil ? scenesService.makeActions(from: inlineActionBundle) : [],
                    preservedConditionPredicate: preservedConditionPredicate,
                    enabled: activateAutomation
                )
                if let editingItem, createdItem.id != editingItem.id {
                    try await automationsService.delete(editingItem)
                    try await automationsService.rename(finalName, for: createdItem)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onSaved?(createdItem)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isSaving = false
        }
    }

    private func loadProposal(
        _ proposal: AutomationProposal,
        capabilities: [AutomationCharacteristicCapability],
        scenes: [SceneItem]
    ) {
        externalEditNotice = proposal.unsupportedReason
        unmanagedActionNotice = nil
        name = proposal.title
        activateAutomation = proposal.shouldEnableAutomation
        conditionJoinMode = proposal.conditionJoinMode.wizardValue

        var unresolved: [String] = []

        startEvents = proposal.startEvents.compactMap { event in
            switch event {
            case .accessory(let selection):
                guard let resolved = resolveSelection(selection, capabilities: capabilities) else {
                    unresolved.append(String(localized: "automation.proposal.unresolved.trigger", defaultValue: "A trigger accessory is no longer available."))
                    return nil
                }
                return AutomationStartEventDraft(selection: resolved)
            case .schedule(let schedule):
                return AutomationStartEventDraft(schedule: schedule.wizardValue)
            case .presence(let presence):
                return AutomationStartEventDraft(presence: presence.wizardValue)
            case .location(let location):
                return AutomationStartEventDraft(location: location.wizardValue)
            }
        }

        conditionDrafts = []
        timeConditionDrafts = []
        presenceConditionDrafts = []
        for condition in proposal.conditions {
            switch condition {
            case .accessory(let selection):
                guard let resolved = resolveSelection(selection, capabilities: capabilities) else {
                    unresolved.append(String(localized: "automation.proposal.unresolved.condition", defaultValue: "A condition accessory is no longer available."))
                    continue
                }
                conditionDrafts.append(AutomationConditionDraft(selection: resolved))
            case .time(let time):
                timeConditionDrafts.append(time.wizardValue)
            case .presence(let presence):
                presenceConditionDrafts.append(presence.wizardValue)
            }
        }
        preservedConditionPredicate = nil

        selectedSceneID = nil
        editingSceneFallback = nil
        inlinePowerActions = []
        clearInlineActionBundleSelection()

        for action in proposal.actions {
            switch action {
            case .scene(let reference):
                guard let scene = resolveScene(reference, scenes: scenes) else {
                    unresolved.append(String(localized: "automation.proposal.unresolved.scene", defaultValue: "The proposed scene is no longer available."))
                    continue
                }
                selectedSceneID = scene.id
                inlinePowerActions = []
                clearInlineActionBundleSelection()
            case .accessoryPower(let powerAction):
                guard selectedSceneID == nil,
                      let action = resolvePowerAction(powerAction, capabilities: capabilities)
                else {
                    unresolved.append(String(localized: "automation.proposal.unresolved.action", defaultValue: "A proposed accessory action is no longer available."))
                    continue
                }
                inlinePowerActions.append(action)
            case .accessory(let accessoryAction):
                guard selectedSceneID == nil,
                      applyProposalAccessoryAction(accessoryAction)
                else {
                    unresolved.append(String(localized: "automation.proposal.unresolved.action", defaultValue: "A proposed accessory action is no longer available."))
                    continue
                }
                inlinePowerActions = []
            }
        }

        if !proposal.limitations.isEmpty || !unresolved.isEmpty {
            let details = (proposal.limitations + unresolved).joined(separator: "\n")
            externalEditNotice = details.isEmpty
                ? String(localized: "automation.proposal.reviewRequired", defaultValue: "Review this automation before saving.")
                : details
        }

        if let firstEvent = startEvents.first {
            triggerSource = firstEvent.kind
            triggerSelection = firstEvent.selection
            scheduleTrigger = firstEvent.schedule
            presenceTrigger = firstEvent.presence
            locationTrigger = firstEvent.location
        }
        isChoosingTrigger = startEvents.isEmpty
    }

    private func resolveSelection(
        _ proposalSelection: AutomationProposalCapabilitySelection,
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationCapabilitySelection? {
        guard let capability = resolveCapability(
            capabilityID: proposalSelection.capabilityID,
            accessoryID: proposalSelection.accessoryID,
            characteristicID: proposalSelection.characteristicID,
            capabilities: capabilities
        ) else { return nil }

        return AutomationCapabilitySelection(
            capability: capability,
            comparisonOperator: proposalSelection.comparisonOperator.wizardValue,
            targetValue: proposalSelection.targetValue.wizardValue
        )
    }

    private func resolveCapability(
        capabilityID: String?,
        accessoryID: UUID?,
        characteristicID: UUID?,
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationCharacteristicCapability? {
        if let capabilityID,
           let capability = capabilities.first(where: { $0.id == capabilityID }) {
            return capability
        }

        if let characteristicID,
           let capability = capabilities.first(where: { $0.characteristic.uniqueIdentifier == characteristicID }) {
            return capability
        }

        if let accessoryID,
           let capability = capabilities.first(where: { $0.accessoryID == accessoryID }) {
            return capability
        }

        return nil
    }

    private func resolveScene(
        _ reference: AutomationProposalSceneReference,
        scenes: [SceneItem]
    ) -> SceneItem? {
        if let sceneID = reference.sceneID,
           let scene = scenes.first(where: { $0.id == sceneID }) {
            return scene
        }

        let trimmedName = reference.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedName, !trimmedName.isEmpty else { return nil }
        return scenes.first { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    private func resolvePowerAction(
        _ action: AutomationProposalPowerAction,
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationInlinePowerAction? {
        guard let capability = resolveCapability(
            capabilityID: action.capabilityID,
            accessoryID: action.accessoryID,
            characteristicID: action.characteristicID,
            capabilities: capabilities
        ) else { return nil }

        guard capability.characteristic.characteristicType == HMCharacteristicTypePowerState ||
                capability.characteristic.characteristicType == HMCharacteristicTypeActive else {
            return nil
        }

        return AutomationInlinePowerAction(
            accessoryName: capability.accessoryName,
            roomName: capability.roomName,
            characteristic: capability.characteristic,
            powerOn: action.powerOn
        )
    }

    @discardableResult
    private func applyProposalAccessoryAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        switch action.kind {
        case .turnOn, .turnOff, .activate, .deactivate:
            let powerOn = action.kind == .turnOn || action.kind == .activate
            return applyPowerLikeProposalAction(action, powerOn: powerOn)
        case .dim:
            return applyDimProposalAction(action)
        case .setMode:
            return applyModeProposalAction(action)
        case .setTemperature:
            return applyTemperatureProposalAction(action)
        case .setFanSpeed:
            return applyFanSpeedProposalAction(action)
        case .setHumidity:
            return applyHumidityProposalAction(action)
        case .open:
            return applyOpenCloseProposalAction(action, open: true)
        case .close:
            return applyOpenCloseProposalAction(action, open: false)
        case .lock:
            return applyLockProposalAction(action, locked: true)
        case .unlock:
            return applyLockProposalAction(action, locked: false)
        }
    }

    private func applyPowerLikeProposalAction(
        _ action: AutomationProposalAccessoryAction,
        powerOn: Bool
    ) -> Bool {
        if let index = inlineActionBundle.lightDrafts.firstIndex(where: { $0.accessoryID == action.accessoryID }) {
            inlineActionBundle.lightDrafts[index].isIncluded = true
            inlineActionBundle.lightDrafts[index].powerOn = powerOn
            return true
        }

        if let index = inlineActionBundle.outletDrafts.firstIndex(where: { $0.accessoryID == action.accessoryID || $0.id == action.accessoryID }) {
            inlineActionBundle.outletDrafts[index].isIncluded = true
            inlineActionBundle.outletDrafts[index].powerOn = powerOn
            return true
        }

        if let index = inlineActionBundle.switchDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.switchDrafts[index].isIncluded = true
            inlineActionBundle.switchDrafts[index].powerOn = powerOn
            return true
        }

        if let index = inlineActionBundle.airPurifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.airPurifierDrafts[index].isIncluded = true
            inlineActionBundle.airPurifierDrafts[index].powerOn = powerOn
            return true
        }

        if let index = inlineActionBundle.fanDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.fanDrafts[index].isIncluded = true
            inlineActionBundle.fanDrafts[index].powerOn = powerOn
            return true
        }

        if let index = inlineActionBundle.humidifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.humidifierDrafts[index].isIncluded = true
            inlineActionBundle.humidifierDrafts[index].powerOn = powerOn
            return true
        }

        if !powerOn,
           let index = inlineActionBundle.thermostatDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.thermostatDrafts[index].isIncluded = true
            inlineActionBundle.thermostatDrafts[index].mode = .off
            return true
        }

        if powerOn,
           let index = inlineActionBundle.thermostatDrafts.firstIndex(where: { $0.id == action.accessoryID }),
           let mode = inlineActionBundle.thermostatDrafts[index].supportedModes.first(where: { $0 != .off }) {
            inlineActionBundle.thermostatDrafts[index].isIncluded = true
            inlineActionBundle.thermostatDrafts[index].mode = mode
            return true
        }

        return false
    }

    private func applyModeProposalAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        if let index = inlineActionBundle.thermostatDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            let requested = action.value.flatMap { HeaterCoolerMode(rawValue: Int($0.rounded())) } ?? .auto
            let mode = inlineActionBundle.thermostatDrafts[index].supportedModes.contains(requested)
                ? requested
                : inlineActionBundle.thermostatDrafts[index].supportedModes.first(where: { $0 != .off }) ?? .auto
            inlineActionBundle.thermostatDrafts[index].isIncluded = true
            inlineActionBundle.thermostatDrafts[index].mode = mode
            if let targetTemperature = action.secondaryValue ?? action.value, mode != .off {
                inlineActionBundle.thermostatDrafts[index].targetTemperature = clamped(
                    targetTemperature,
                    in: inlineActionBundle.thermostatDrafts[index].targetRange
                )
            }
            return true
        }

        if let index = inlineActionBundle.securitySystemDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            let requested = action.value.flatMap { SecurityMode(rawValue: Int($0.rounded())) } ?? .away
            let mode = inlineActionBundle.securitySystemDrafts[index].supportedModes.contains(requested)
                ? requested
                : inlineActionBundle.securitySystemDrafts[index].supportedModes.first ?? .away
            inlineActionBundle.securitySystemDrafts[index].isIncluded = true
            inlineActionBundle.securitySystemDrafts[index].mode = mode
            return true
        }

        if let index = inlineActionBundle.airPurifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            let requested = action.value.flatMap { AirPurifierMode(rawValue: Int($0.rounded())) } ?? .auto
            let mode = inlineActionBundle.airPurifierDrafts[index].supportedModes.contains(requested)
                ? requested
                : inlineActionBundle.airPurifierDrafts[index].supportedModes.first ?? .auto
            inlineActionBundle.airPurifierDrafts[index].isIncluded = true
            inlineActionBundle.airPurifierDrafts[index].powerOn = true
            inlineActionBundle.airPurifierDrafts[index].mode = mode
            return true
        }

        if let index = inlineActionBundle.humidifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            let requested = action.value.flatMap { HumidifierMode(rawValue: Int($0.rounded())) } ?? .auto
            let mode = inlineActionBundle.humidifierDrafts[index].supportedModes.contains(requested)
                ? requested
                : inlineActionBundle.humidifierDrafts[index].supportedModes.first ?? .auto
            inlineActionBundle.humidifierDrafts[index].isIncluded = true
            inlineActionBundle.humidifierDrafts[index].powerOn = true
            inlineActionBundle.humidifierDrafts[index].mode = mode
            return true
        }

        return false
    }

    private func applyTemperatureProposalAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        guard let value = action.value,
              let index = inlineActionBundle.thermostatDrafts.firstIndex(where: { $0.id == action.accessoryID }) else {
            return false
        }

        inlineActionBundle.thermostatDrafts[index].isIncluded = true
        if inlineActionBundle.thermostatDrafts[index].mode == .off {
            inlineActionBundle.thermostatDrafts[index].mode = inlineActionBundle.thermostatDrafts[index].supportedModes.first(where: { $0 != .off }) ?? .auto
        }
        inlineActionBundle.thermostatDrafts[index].targetTemperature = clamped(
            value,
            in: inlineActionBundle.thermostatDrafts[index].targetRange
        )
        return true
    }

    private func applyFanSpeedProposalAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        guard let value = action.value else {
            return false
        }

        if let index = inlineActionBundle.thermostatDrafts.firstIndex(where: { $0.id == action.accessoryID }),
           inlineActionBundle.thermostatDrafts[index].rotationSpeedCharacteristic != nil {
            let percent = normalizedPercent(value, defaultValue: inlineActionBundle.thermostatDrafts[index].fanSpeed)
            inlineActionBundle.thermostatDrafts[index].isIncluded = true
            if inlineActionBundle.thermostatDrafts[index].mode == .off {
                inlineActionBundle.thermostatDrafts[index].mode = inlineActionBundle.thermostatDrafts[index].supportedModes.first(where: { $0 != .off }) ?? .auto
            }
            inlineActionBundle.thermostatDrafts[index].fanSpeed = max(
                inlineActionBundle.thermostatDrafts[index].fanRange.lowerBound,
                min(inlineActionBundle.thermostatDrafts[index].fanRange.upperBound, percent)
            )
            return true
        }

        if let index = inlineActionBundle.airPurifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            let percent = normalizedPercent(value, defaultValue: inlineActionBundle.airPurifierDrafts[index].fanSpeed)
            inlineActionBundle.airPurifierDrafts[index].isIncluded = true
            inlineActionBundle.airPurifierDrafts[index].powerOn = true
            inlineActionBundle.airPurifierDrafts[index].mode = .manual
            inlineActionBundle.airPurifierDrafts[index].fanSpeed = max(
                inlineActionBundle.airPurifierDrafts[index].fanRange.lowerBound,
                min(inlineActionBundle.airPurifierDrafts[index].fanRange.upperBound, percent)
            )
            return true
        }

        guard let index = inlineActionBundle.fanDrafts.firstIndex(where: { $0.id == action.accessoryID }) else {
            return false
        }
        let percent = normalizedPercent(value, defaultValue: inlineActionBundle.fanDrafts[index].speed)
        inlineActionBundle.fanDrafts[index].isIncluded = true
        inlineActionBundle.fanDrafts[index].powerOn = true
        inlineActionBundle.fanDrafts[index].speed = max(
            inlineActionBundle.fanDrafts[index].speedRange.lowerBound,
            min(inlineActionBundle.fanDrafts[index].speedRange.upperBound, percent)
        )
        return true
    }

    private func applyHumidityProposalAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        guard let value = action.value,
              let index = inlineActionBundle.humidifierDrafts.firstIndex(where: { $0.id == action.accessoryID }) else {
            return false
        }

        inlineActionBundle.humidifierDrafts[index].isIncluded = true
        inlineActionBundle.humidifierDrafts[index].powerOn = true
        inlineActionBundle.humidifierDrafts[index].targetHumidity = clamped(
            value,
            in: inlineActionBundle.humidifierDrafts[index].targetHumidityRange
        )
        return true
    }

    private func applyDimProposalAction(_ action: AutomationProposalAccessoryAction) -> Bool {
        guard let index = inlineActionBundle.lightDrafts.firstIndex(where: { $0.accessoryID == action.accessoryID }) else {
            return false
        }

        inlineActionBundle.lightDrafts[index].isIncluded = true
        inlineActionBundle.lightDrafts[index].powerOn = true
        inlineActionBundle.lightDrafts[index].brightness = normalizedPercent(action.value, defaultValue: inlineActionBundle.lightDrafts[index].brightness)
        return true
    }

    private func applyOpenCloseProposalAction(
        _ action: AutomationProposalAccessoryAction,
        open: Bool
    ) -> Bool {
        if let index = inlineActionBundle.windowCoveringDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.windowCoveringDrafts[index].isIncluded = true
            inlineActionBundle.windowCoveringDrafts[index].position = open ? 100 : 0
            return true
        }

        if let index = inlineActionBundle.garageDoorDrafts.firstIndex(where: { $0.id == action.accessoryID }) {
            inlineActionBundle.garageDoorDrafts[index].isIncluded = true
            inlineActionBundle.garageDoorDrafts[index].open = open
            return true
        }

        return false
    }

    private func applyLockProposalAction(
        _ action: AutomationProposalAccessoryAction,
        locked: Bool
    ) -> Bool {
        guard let index = inlineActionBundle.doorLockDrafts.firstIndex(where: { $0.id == action.accessoryID }) else {
            return false
        }

        inlineActionBundle.doorLockDrafts[index].isIncluded = true
        inlineActionBundle.doorLockDrafts[index].locked = locked
        return true
    }

    private func normalizedPercent(_ value: Double?, defaultValue: Int) -> Int {
        guard let value else { return max(1, min(100, defaultValue)) }
        let percent = value <= 1 ? value * 100 : value
        return max(1, min(100, Int(percent.rounded())))
    }

    private func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func loadEditingItem(
        _ item: AutomationItem,
        capabilities: [AutomationCharacteristicCapability],
        scenes: [SceneItem]
    ) {
        guard let draft = AutomationWizardEditDraft(item: item, capabilities: capabilities) else {
            externalEditNotice = String(
                localized: "automation.editor.openHome.unsupported",
                defaultValue: "Questa automazione usa elementi HomeKit che l'app non riesce ancora a caricare completamente. Puoi continuare a gestirla da Apple Home."
            )
            return
        }

        externalEditNotice = nil
        unmanagedActionNotice = nil
        startEvents = draft.startEvents
        if let firstEvent = draft.startEvents.first {
            triggerSource = firstEvent.kind
            triggerSelection = firstEvent.selection
            scheduleTrigger = firstEvent.schedule
            presenceTrigger = firstEvent.presence
            locationTrigger = firstEvent.location
        }
        conditionDrafts = draft.conditionSelections.map { AutomationConditionDraft(selection: $0) }
        timeConditionDrafts = draft.timeConditions
        presenceConditionDrafts = draft.presenceConditions
        conditionJoinMode = draft.conditionJoinMode
        preservedConditionPredicate = draft.preservedConditionPredicate
        if let actionSet = item.trigger.actionSets.first {
            let matchedScene = scenes.first { $0.actionSet.uniqueIdentifier == actionSet.uniqueIdentifier }
            if isInlineActionSet(actionSet, matchedScene: matchedScene) {
                selectedSceneID = nil
                editingSceneFallback = nil
                inlineActionBundle = scenesService.actionDraftBundle(for: SceneItem(actionSet: actionSet))
                inlinePowerActions = inlinePowerActions(from: actionSet)
                if hasUnmanagedActions(in: actionSet) {
                    unmanagedActionNotice = String(
                        localized: "automation.editor.openHome.unmanagedActions",
                        defaultValue: "Questa automazione contiene azioni HomeKit non gestibili dall'app, come shortcut o comandi speciali. Per non perderle, modificala da Apple Home."
                    )
                }
            } else {
                selectedSceneID = actionSet.uniqueIdentifier
                editingSceneFallback = SceneItem(
                    actionSet: actionSet,
                    displayNameOverride: sceneDisplayName(
                        actionSet: actionSet,
                        matchedScene: matchedScene
                    )
                )
            }
        }
        isChoosingTrigger = false
    }

    private func hasUnmanagedActions(in actionSet: HMActionSet) -> Bool {
        actionSet.actions.contains { $0.homeFloorplanCharacteristicWrite == nil }
    }

    private func isInlineActionSet(_ actionSet: HMActionSet, matchedScene: SceneItem?) -> Bool {
        if actionSet.actionSetType == HMActionSetTypeTriggerOwned {
            return true
        }
        if actionSet.name.hasPrefix("HF Actions - ") {
            return true
        }
        return matchedScene == nil && scenesService.actionDraftBundle(for: SceneItem(actionSet: actionSet)).selectedCount > 0
    }

    private func inlinePowerActions(from actionSet: HMActionSet) -> [AutomationInlinePowerAction] {
        actionSet.actions.compactMap { action in
            guard let write = action.homeFloorplanCharacteristicWrite,
                  write.characteristic.characteristicType == HMCharacteristicTypePowerState ||
                    write.characteristic.characteristicType == HMCharacteristicTypeActive,
                  let accessory = write.characteristic.service?.accessory,
                  let powerOn = Self.boolValue(write.targetValue) else {
                return nil
            }
            return AutomationInlinePowerAction(
                accessoryName: accessory.name,
                roomName: accessory.room?.name ?? String(localized: "room.none", defaultValue: "No room"),
                characteristic: write.characteristic,
                powerOn: powerOn
            )
        }
    }

    private func sceneDisplayName(
        actionSet: HMActionSet,
        matchedScene: SceneItem?
    ) -> String {
        if let matchedScene {
            let matchedName = matchedScene.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !matchedName.isEmpty, !matchedScene.hasGenericDisplayName {
                return matchedName
            }
        }

        let directName = actionSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directName.isEmpty {
            return directName
        }

        let actionSetScene = SceneItem(actionSet: actionSet)
        return actionSetScene.hasGenericDisplayName
            ? String(localized: "scene.systemLinked", defaultValue: "System Scene")
            : actionSetScene.name
    }

    private func defaultNameIfNeeded() {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let selectedScene {
            name = String(localized: "automation.wizard.defaultName", defaultValue: "Run \(selectedScene.name)")
        } else if let firstEvent = startEvents.first {
            switch firstEvent.kind {
            case .time:
                name = String(localized: "automation.wizard.defaultName.schedule", defaultValue: "Scheduled automation")
            case .people:
                name = String(localized: "automation.wizard.defaultName.presence", defaultValue: "People automation")
            case .location:
                name = String(localized: "automation.wizard.defaultName.location", defaultValue: "Location automation")
            case .accessory:
                if let selection = firstEvent.selection {
                    name = String(format: String(localized: "automation.wizard.defaultName.trigger",
                                                 defaultValue: "%@ automation"),
                                  selection.capability.accessoryName)
                }
            }
        }
    }

    private func toggleScheduleWeekday(_ day: AutomationScheduleWeekday) {
        if scheduleTrigger.weekdays.contains(day), scheduleTrigger.weekdays.count > 1 {
            scheduleTrigger.weekdays.remove(day)
        } else {
            scheduleTrigger.weekdays.insert(day)
        }
    }

    private func toggleScheduleWeekday(_ day: AutomationScheduleWeekday, for event: Binding<AutomationStartEventDraft>) {
        if event.wrappedValue.schedule.weekdays.contains(day), event.wrappedValue.schedule.weekdays.count > 1 {
            event.wrappedValue.schedule.weekdays.remove(day)
        } else {
            event.wrappedValue.schedule.weekdays.insert(day)
        }
    }

    private func removeStartEvent(id: UUID) {
        startEvents.removeAll { $0.id == id }
    }

    private func isLastCondition(id: UUID) -> Bool {
        if let lastPresenceID = presenceConditionDrafts.last?.id {
            return id == lastPresenceID
        }
        if let lastTimeID = timeConditionDrafts.last?.id {
            return id == lastTimeID
        }
        return id == conditionDrafts.last?.id
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
        true
    }
}

private struct AutomationWizardEditDraft {
    var startEvents: [AutomationStartEventDraft]
    var conditionSelections: [AutomationCapabilitySelection]
    var timeConditions: [AutomationTimeCondition]
    var presenceConditions: [AutomationPresenceCondition]
    var preservedConditionPredicate: NSPredicate?
    var conditionJoinMode: AutomationConditionJoinMode
    var sceneID: UUID?

    init?(
        item: AutomationItem,
        capabilities: [AutomationCharacteristicCapability]
    ) {
        let trigger = item.trigger
        let sceneID = trigger.actionSets.first?.uniqueIdentifier

        if let timer = trigger as? HMTimerTrigger {
            self.startEvents = [AutomationStartEventDraft(schedule: Self.scheduleTrigger(from: timer))]
            self.conditionSelections = []
            self.timeConditions = []
            self.presenceConditions = []
            self.preservedConditionPredicate = nil
            self.conditionJoinMode = .all
            self.sceneID = sceneID
            return
        }

        guard let eventTrigger = trigger as? HMEventTrigger else {
            return nil
        }

        let decodedSelections = Self.selections(in: eventTrigger.predicate, capabilities: capabilities)
        self.sceneID = sceneID

        self.startEvents = eventTrigger.events.compactMap { event in
            Self.startEventDraft(
                from: event,
                recurrences: eventTrigger.recurrences,
                decodedSelections: decodedSelections,
                capabilities: capabilities
            )
        }

        let triggerPredicates = Self.triggerPredicates(
            startEvents: startEvents,
            triggerPresenceEvents: eventTrigger.events.compactMap { $0 as? HMPresenceEvent },
            triggerTimeEvents: eventTrigger.events.filter { $0 is HMCalendarEvent || $0 is HMSignificantTimeEvent }
        )
        guard !startEvents.isEmpty else { return nil }
        self.conditionSelections = decodedSelections.filter { selection in
            !triggerPredicates.contains { Self.predicatesMatch($0, selection.predicate) }
        }
        self.timeConditions = Self.timeConditions(
            in: eventTrigger.predicate,
            triggerPredicates: triggerPredicates
        )
        self.presenceConditions = Self.presenceConditions(
            in: eventTrigger.predicate,
            triggerPredicates: triggerPredicates
        )
        let preservedPredicate = Self.conditionPredicate(
            in: eventTrigger.predicate,
            triggerPredicates: triggerPredicates,
            handledConditionSelections: conditionSelections,
            handledTimeConditions: timeConditions,
            handledPresenceConditions: presenceConditions
        )
        let visibleConditionCount = conditionSelections.count + timeConditions.count + presenceConditions.count
        let needsFallbackPredicate = !item.conditionSummaries.isEmpty && visibleConditionCount < item.conditionSummaries.count
        let fallbackPredicate = needsFallbackPredicate ? eventTrigger.predicate : nil
        self.preservedConditionPredicate = visibleConditionCount == 0
            ? preservedPredicate ?? fallbackPredicate
            : nil
        self.conditionJoinMode = Self.conditionJoinMode(
            in: eventTrigger.predicate,
            triggerPredicates: triggerPredicates
        )
    }

    private static func startEventDraft(
        from event: HMEvent,
        recurrences: [DateComponents]?,
        decodedSelections: [AutomationCapabilitySelection],
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationStartEventDraft? {
        if let characteristicEvent = event as? HMCharacteristicEvent<NSCopying>,
           let capability = capabilities.first(where: { $0.characteristic.uniqueIdentifier == characteristicEvent.characteristic.uniqueIdentifier }) {
            if let triggerValue = characteristicEvent.triggerValue as? NSNumber {
                return AutomationStartEventDraft(
                    selection: AutomationCapabilitySelection(
                        capability: capability,
                        comparisonOperator: .equals,
                        targetValue: .state(triggerValue.intValue)
                    )
                )
            }

            return AutomationStartEventDraft(selection: AutomationCapabilitySelection(capability: capability))
        }

        if let calendarEvent = event as? HMCalendarEvent {
            return AutomationStartEventDraft(schedule: scheduleTrigger(from: calendarEvent, recurrences: recurrences))
        }

        if let significantEvent = event as? HMSignificantTimeEvent {
            return AutomationStartEventDraft(schedule: scheduleTrigger(from: significantEvent, recurrences: recurrences))
        }

        if let presenceEvent = event as? HMPresenceEvent {
            return AutomationStartEventDraft(presence: presenceTrigger(from: presenceEvent))
        }

        if let locationEvent = event as? HMLocationEvent,
           let region = locationEvent.region as? CLCircularRegion {
            return AutomationStartEventDraft(
                location: AutomationLocationTrigger(
                    kind: region.notifyOnExit && !region.notifyOnEntry ? .leave : .arrive,
                    latitude: region.center.latitude,
                    longitude: region.center.longitude,
                    radius: region.radius
                )
            )
        }

        return nil
    }

    private static func scheduleTrigger(from timer: HMTimerTrigger) -> AutomationScheduleTrigger {
        var trigger = AutomationScheduleTrigger()
        trigger.kind = .fixedTime
        trigger.time = timer.fireDate
        return trigger
    }

    private static func scheduleTrigger(from event: HMCalendarEvent, recurrences: [DateComponents]?) -> AutomationScheduleTrigger {
        var trigger = AutomationScheduleTrigger()
        trigger.kind = .fixedTime
        trigger.time = Calendar.current.date(from: event.fireDateComponents) ?? Date()
        trigger.weekdays = weekdays(from: recurrences)
        return trigger
    }

    private static func scheduleTrigger(from event: HMSignificantTimeEvent, recurrences: [DateComponents]?) -> AutomationScheduleTrigger {
        var trigger = AutomationScheduleTrigger()
        trigger.kind = event.significantEvent == HMSignificantEvent.sunrise ? .sunrise : .sunset
        trigger.offsetMinutes = event.offset?.minute ?? 0
        trigger.weekdays = weekdays(from: recurrences)
        return trigger
    }

    private static func weekdays(from recurrences: [DateComponents]?) -> Set<AutomationScheduleWeekday> {
        guard let recurrences, !recurrences.isEmpty else {
            return Set(AutomationScheduleWeekday.allCases)
        }

        let weekdays = recurrences.compactMap(\.weekday).compactMap(AutomationScheduleWeekday.init(rawValue:))
        return weekdays.isEmpty ? Set(AutomationScheduleWeekday.allCases) : Set(weekdays)
    }

    private static func presenceTrigger(from event: HMPresenceEvent) -> AutomationPresenceTrigger {
        AutomationPresenceTrigger(
            kind: AutomationPresenceTriggerKind(homeKitValue: event.presenceEventType),
            userScope: AutomationPresenceUserScope(homeKitValue: event.presenceUserType)
        )
    }

    private static func triggerPredicates(
        startEvents: [AutomationStartEventDraft],
        triggerPresenceEvents: [HMPresenceEvent],
        triggerTimeEvents: [HMEvent]
    ) -> [NSPredicate] {
        let accessoryPredicates = startEvents.compactMap { draft -> NSPredicate? in
            guard let selection = draft.selection else { return nil }
            return selection.triggerPredicate
        }

        let presencePredicates = triggerPresenceEvents.map { event in
            HMEventTrigger.predicateForEvaluatingTrigger(withPresence: event)
        }

        let timePredicates = triggerTimeEvents.compactMap(timeTriggerPredicate)

        return accessoryPredicates + presencePredicates + timePredicates
    }

    nonisolated private static func timeTriggerPredicate(for event: HMEvent) -> NSPredicate? {
        if let calendarEvent = event as? HMCalendarEvent {
            return HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: calendarEvent.fireDateComponents)
        }

        if let significantEvent = event as? HMSignificantTimeEvent {
            return HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: significantEvent)
        }

        return nil
    }

    private static func selections(
        in predicate: NSPredicate?,
        capabilities: [AutomationCharacteristicCapability]
    ) -> [AutomationCapabilitySelection] {
        guard let predicate else { return [] }

        if let selection = selection(fromGroupedPredicate: predicate, capabilities: capabilities) {
            return [selection]
        }

        guard let compound = predicate as? NSCompoundPredicate else {
            return []
        }

        return compound.subpredicates.flatMap { subpredicate -> [AutomationCapabilitySelection] in
            guard let predicate = subpredicate as? NSPredicate else { return [] }
            return selections(in: predicate, capabilities: capabilities)
        }
    }

    private static func conditionPredicate(
        in predicate: NSPredicate?,
        triggerPredicates: [NSPredicate],
        handledConditionSelections: [AutomationCapabilitySelection],
        handledTimeConditions: [AutomationTimeCondition],
        handledPresenceConditions: [AutomationPresenceCondition]
    ) -> NSPredicate? {
        guard let predicate else { return nil }
        if triggerPredicates.contains(where: { predicatesMatch($0, predicate) }) {
            return nil
        }

        if let compound = predicate as? NSCompoundPredicate {
            let filtered = compound.subpredicates.compactMap { subpredicate -> NSPredicate? in
                guard let predicate = subpredicate as? NSPredicate else { return nil }
                return conditionPredicate(
                    in: predicate,
                    triggerPredicates: triggerPredicates,
                    handledConditionSelections: handledConditionSelections,
                    handledTimeConditions: handledTimeConditions,
                    handledPresenceConditions: handledPresenceConditions
                )
            }

            guard !filtered.isEmpty else { return nil }
            guard filtered.count > 1 else { return filtered[0] }

            switch compound.compoundPredicateType {
            case .and:
                return NSCompoundPredicate(andPredicateWithSubpredicates: filtered)
            case .or:
                return NSCompoundPredicate(orPredicateWithSubpredicates: filtered)
            case .not:
                return NSCompoundPredicate(notPredicateWithSubpredicate: filtered[0])
            @unknown default:
                return NSCompoundPredicate(andPredicateWithSubpredicates: filtered)
            }
        }

        if handledConditionSelections.contains(where: { isHandledAccessoryConditionPredicate(predicate, by: $0) }) {
            return nil
        }
        if let timeCondition = timeCondition(in: predicate),
           handledTimeConditions.contains(where: { $0.matches(timeCondition) || $0.kind == timeCondition.kind }) {
            return nil
        }
        if let presenceEvent = presenceEvent(in: predicate),
           handledPresenceConditions.contains(where: { $0.matches(presenceEvent) }) {
            return nil
        }

        return predicate
    }

    private static func shouldPreserveResidualPredicate(_ predicate: NSPredicate?) -> Bool {
        guard let predicate else { return false }

        if let compound = predicate as? NSCompoundPredicate {
            return compound.subpredicates.contains { subpredicate in
                guard let predicate = subpredicate as? NSPredicate else { return false }
                return shouldPreserveResidualPredicate(predicate)
            }
        }

        if !allCharacteristics(in: predicate).isEmpty {
            return false
        }
        if timeCondition(in: predicate) != nil {
            return false
        }
        if presenceEvent(in: predicate) != nil {
            return false
        }

        return true
    }

    private static func timeConditions(
        in predicate: NSPredicate?,
        triggerPredicates: [NSPredicate]
    ) -> [AutomationTimeCondition] {
        guard let predicate else { return [] }
        if let compound = predicate as? NSCompoundPredicate {
            let conditionPredicates = compound.subpredicates.compactMap { subpredicate -> NSPredicate? in
                guard let predicate = subpredicate as? NSPredicate,
                      !triggerPredicates.contains(where: { predicatesMatch($0, predicate) }) else {
                    return nil
                }
                return predicate
            }

            if compound.compoundPredicateType == .and,
               let betweenCondition = betweenTimeCondition(in: conditionPredicates) {
                return [betweenCondition]
            }

            return conditionPredicates.flatMap { predicate -> [AutomationTimeCondition] in
                return timeConditions(in: predicate, triggerPredicates: triggerPredicates)
            }
            .uniquedBy(timeConditionIdentity)
        }

        if let condition = timeCondition(in: predicate),
           !triggerPredicates.contains(where: { predicatesMatch($0, predicate) }) {
            return [condition]
        }

        return []
    }

    private static func timeCondition(in predicate: NSPredicate) -> AutomationTimeCondition? {
        let constants = constantValues(in: predicate)
        if let comparison = predicate as? NSComparisonPredicate,
           comparison.predicateOperatorType == .between,
           let condition = betweenTimeCondition(in: [comparison]) {
            return condition
        }

        if let significantEvent = constants.compactMap({ $0 as? HMSignificantTimeEvent }).first {
            var condition = AutomationTimeCondition()
            condition.kind = significantEvent.significantEvent == HMSignificantEvent.sunrise ? .sunrise : .sunset
            condition.relation = timeRelation(from: predicate)
            condition.offsetMinutes = significantEvent.offset?.minute ?? offsetMinutes(in: constants)
            return condition
        }

        if let components = constants.compactMap({ $0 as? DateComponents }).first,
           components.hour != nil || components.minute != nil {
            var condition = AutomationTimeCondition()
            condition.kind = .fixedTime
            condition.relation = timeRelation(from: predicate)
            var dateComponents = DateComponents()
            dateComponents.hour = components.hour ?? 0
            dateComponents.minute = components.minute ?? 0
            condition.time = Calendar.current.date(from: dateComponents) ?? Date()
            return condition
        }

        return nil
    }

    private static func betweenTimeCondition(in predicates: [NSPredicate]) -> AutomationTimeCondition? {
        let directComparisons = predicates.flatMap(directComparisonPredicates)
        let constants = directComparisons.flatMap(constantValues)

        let significantEvents = constants.compactMap { $0 as? HMSignificantTimeEvent }
        if significantEvents.count >= 2 {
            var condition = AutomationTimeCondition()
            condition.kind = timeConditionKind(for: significantEvents[0])
            condition.relation = .between
            condition.offsetMinutes = significantEvents[0].offset?.minute ?? 0
            condition.endKind = timeConditionKind(for: significantEvents[1])
            condition.endOffsetMinutes = significantEvents[1].offset?.minute ?? 0
            return condition
        }

        let dateComponents = constants.compactMap { $0 as? DateComponents }
            .filter { $0.hour != nil }
        if dateComponents.count >= 2 {
            var condition = AutomationTimeCondition()
            condition.kind = .fixedTime
            condition.relation = .between
            condition.time = date(from: dateComponents[0])
            condition.endKind = .fixedTime
            condition.endTime = date(from: dateComponents[1])
            return condition
        }

        guard directComparisons.count == 2,
              let start = directComparisons.first(where: { timeRelation(from: $0) == .after }),
              let end = directComparisons.first(where: { timeRelation(from: $0) == .before }),
              var condition = timeCondition(in: start),
              let endCondition = timeCondition(in: end) else {
            return nil
        }

        condition.relation = .between
        condition.endKind = endCondition.kind
        condition.endTime = endCondition.time
        condition.endOffsetMinutes = endCondition.offsetMinutes
        return condition
    }

    private static func date(from components: DateComponents) -> Date {
        var dateComponents = DateComponents()
        dateComponents.hour = components.hour ?? 0
        dateComponents.minute = components.minute ?? 0
        return Calendar.current.date(from: dateComponents) ?? Date()
    }

    private static func timeConditionKind(for event: HMSignificantTimeEvent) -> AutomationTimeConditionKind {
        event.significantEvent == HMSignificantEvent.sunrise ? .sunrise : .sunset
    }

    nonisolated private static func timeConditionIdentity(_ condition: AutomationTimeCondition) -> String {
        [
            condition.kind.rawValue,
            condition.relation.rawValue,
            "\(condition.offsetMinutes)",
            "\(Calendar.current.component(.hour, from: condition.time))",
            "\(Calendar.current.component(.minute, from: condition.time))",
            condition.endKind.rawValue,
            "\(condition.endOffsetMinutes)",
            "\(Calendar.current.component(.hour, from: condition.endTime))",
            "\(Calendar.current.component(.minute, from: condition.endTime))"
        ].joined(separator: "-")
    }

    private static func timeRelation(from predicate: NSPredicate) -> AutomationTimeConditionRelation {
        guard let comparison = predicate as? NSComparisonPredicate else {
            return .after
        }

        switch normalizedOperator(for: comparison) {
        case .lessThan, .lessThanOrEqualTo:
            return .before
        default:
            return .after
        }
    }

    private static func offsetMinutes(in constants: [Any]) -> Int {
        constants
            .compactMap { $0 as? DateComponents }
            .first(where: { $0.minute != nil })?
            .minute ?? 0
    }

    private static func timeEvent(_ event: HMEvent, matches condition: AutomationTimeCondition) -> Bool {
        if let calendarEvent = event as? HMCalendarEvent,
           condition.kind == .fixedTime {
            return calendarEvent.fireDateComponents.hour == Calendar.current.component(.hour, from: condition.time) &&
            calendarEvent.fireDateComponents.minute == Calendar.current.component(.minute, from: condition.time)
        }

        if let significantEvent = event as? HMSignificantTimeEvent {
            let kind: AutomationTimeConditionKind = significantEvent.significantEvent == HMSignificantEvent.sunrise ? .sunrise : .sunset
            return kind == condition.kind && (significantEvent.offset?.minute ?? 0) == condition.offsetMinutes
        }

        return false
    }

    private static func presenceConditions(
        in predicate: NSPredicate?,
        triggerPredicates: [NSPredicate]
    ) -> [AutomationPresenceCondition] {
        guard let predicate else { return [] }
        if let compound = predicate as? NSCompoundPredicate {
            return compound.subpredicates.flatMap { subpredicate -> [AutomationPresenceCondition] in
                guard let predicate = subpredicate as? NSPredicate else { return [] }
                return presenceConditions(in: predicate, triggerPredicates: triggerPredicates)
            }
            .uniquedBy { "\($0.kind.rawValue)-\($0.userScope.rawValue)" }
        }

        if let event = presenceEvent(in: predicate),
           !triggerPredicates.contains(where: { predicatesMatch($0, predicate) }),
           let condition = AutomationPresenceCondition(homeKitEvent: event) {
            return [condition]
        }

        return []
    }

    nonisolated private static func presenceEvent(in predicate: NSPredicate) -> HMPresenceEvent? {
        if let comparison = predicate as? NSComparisonPredicate {
            return [comparison.leftExpression, comparison.rightExpression]
                .compactMap(constantExpressionValue)
                .compactMap { $0 as? HMPresenceEvent }
                .first
        }

        guard let compound = predicate as? NSCompoundPredicate else { return nil }
        return compound.subpredicates.compactMap { subpredicate -> HMPresenceEvent? in
            guard let predicate = subpredicate as? NSPredicate else { return nil }
            return presenceEvent(in: predicate)
        }
        .first
    }

    nonisolated private static func constantValues(in predicate: NSPredicate) -> [Any] {
        if let comparison = predicate as? NSComparisonPredicate {
            return [comparison.leftExpression, comparison.rightExpression]
                .compactMap(constantExpressionValue)
        }

        guard let compound = predicate as? NSCompoundPredicate else { return [] }
        return compound.subpredicates.flatMap { subpredicate -> [Any] in
            guard let predicate = subpredicate as? NSPredicate else { return [] }
            return constantValues(in: predicate)
        }
    }

    private static func isTriggerPredicate(
        _ predicate: NSPredicate,
        triggerCharacteristicIDs: Set<UUID>
    ) -> Bool {
        let characteristics = allCharacteristics(in: predicate)
        return !characteristics.isEmpty &&
        characteristics.allSatisfy { triggerCharacteristicIDs.contains($0.uniqueIdentifier) }
    }

    nonisolated private static func predicatesMatch(_ lhs: NSPredicate, _ rhs: NSPredicate) -> Bool {
        if let lhsPresence = presenceEvent(in: lhs),
           let rhsPresence = presenceEvent(in: rhs) {
            return lhsPresence.matches(rhsPresence)
        }

        let lhsCharacteristics = allCharacteristics(in: lhs).map(\.uniqueIdentifier)
        let rhsCharacteristics = allCharacteristics(in: rhs).map(\.uniqueIdentifier)
        guard !lhsCharacteristics.isEmpty,
              lhsCharacteristics == rhsCharacteristics else {
            return false
        }

        let lhsValues = constantValues(in: lhs).filter { !($0 is HMCharacteristic) }.map(describeConstant)
        let rhsValues = constantValues(in: rhs).filter { !($0 is HMCharacteristic) }.map(describeConstant)
        return lhsValues == rhsValues
    }

    private static func isHandledAccessoryConditionPredicate(
        _ predicate: NSPredicate,
        by selection: AutomationCapabilitySelection
    ) -> Bool {
        let characteristics = allCharacteristics(in: predicate)
        guard characteristics.contains(where: { $0.uniqueIdentifier == selection.capability.characteristic.uniqueIdentifier }) else {
            return false
        }

        if predicatesMatch(selection.predicate, predicate) {
            return true
        }

        // HomeKit can reserialize comparison predicates differently from the one we create.
        // If the leaf targets the same characteristic and has a comparison value, it is the
        // same accessory condition already represented by the editable card.
        return constantValues(in: predicate).contains { value in
            !(value is HMCharacteristic) &&
            !(value is HMPresenceEvent) &&
            !(value is HMSignificantTimeEvent) &&
            !(value is DateComponents)
        }
    }

    nonisolated private static func describeConstant(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let dateComponents = value as? DateComponents {
            return "\(dateComponents.hour ?? -1):\(dateComponents.minute ?? -1)"
        }
        if let presence = value as? HMPresenceEvent {
            return "presence-\(presence.presenceEventType.rawValue)-\(presence.presenceUserType.rawValue)"
        }
        if let significant = value as? HMSignificantTimeEvent {
            return "significant-\(significant.significantEvent)-\(significant.offset?.minute ?? 0)"
        }
        return String(describing: value)
    }

    nonisolated private static func allCharacteristics(in predicate: NSPredicate) -> [HMCharacteristic] {
        if let comparison = predicate as? NSComparisonPredicate {
            return [comparison.leftExpression, comparison.rightExpression]
                .compactMap(constantExpressionValue)
                .compactMap { $0 as? HMCharacteristic }
        }

        guard let compound = predicate as? NSCompoundPredicate else { return [] }
        return compound.subpredicates.flatMap { subpredicate -> [HMCharacteristic] in
            guard let predicate = subpredicate as? NSPredicate else { return [] }
            return allCharacteristics(in: predicate)
        }
    }

    private static func conditionJoinMode(
        in predicate: NSPredicate?,
        triggerPredicates: [NSPredicate]
    ) -> AutomationConditionJoinMode {
        guard let predicate else {
            return .all
        }

        if triggerPredicates.contains(where: { predicatesMatch($0, predicate) }) {
            return .all
        }

        guard let compound = predicate as? NSCompoundPredicate else {
            return .all
        }

        switch compound.compoundPredicateType {
        case .or:
            let conditionPredicates = compound.subpredicates.compactMap { subpredicate -> NSPredicate? in
                guard let predicate = subpredicate as? NSPredicate,
                      !triggerPredicates.contains(where: { predicatesMatch($0, predicate) }) else {
                    return nil
                }
                return predicate
            }
            return conditionPredicates.count > 1 ? .any : .all

        case .and:
            let containsNestedAny = compound.subpredicates.contains { subpredicate in
                guard let predicate = subpredicate as? NSPredicate else { return false }
                return conditionJoinMode(in: predicate, triggerPredicates: triggerPredicates) == .any
            }
            return containsNestedAny ? .any : .all

        case .not:
            return .all

        @unknown default:
            return .all
        }
    }

    private static func selection(
        fromGroupedPredicate predicate: NSPredicate,
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationCapabilitySelection? {
        let comparisons = directComparisonPredicates(in: predicate)
        guard !comparisons.isEmpty else { return nil }

        let characteristics = comparisons
            .compactMap(characteristic)
            .uniquedBy(\.uniqueIdentifier)
        guard characteristics.count == 1,
              let characteristic = characteristics.first,
              let capability = capabilities.first(where: { $0.characteristic.uniqueIdentifier == characteristic.uniqueIdentifier }) else {
            return nil
        }

        let valueComparison = comparisons.first { comparison in
            comparisonValue(in: comparison) != nil
        }

        guard let valueComparison else {
            return AutomationCapabilitySelection(capability: capability)
        }

        return AutomationCapabilitySelection(
            capability: capability,
            comparisonOperator: automationOperator(for: valueComparison, valueKind: capability.valueKind),
            targetValue: targetValue(for: valueComparison, valueKind: capability.valueKind)
        )
    }

    nonisolated private static func directComparisonPredicates(in predicate: NSPredicate) -> [NSComparisonPredicate] {
        if let comparison = predicate as? NSComparisonPredicate {
            return [comparison]
        }

        guard let compound = predicate as? NSCompoundPredicate,
              compound.compoundPredicateType == .and else {
            return []
        }

        return compound.subpredicates.compactMap { $0 as? NSComparisonPredicate }
    }

    nonisolated private static func characteristic(in predicate: NSComparisonPredicate) -> HMCharacteristic? {
        [predicate.leftExpression, predicate.rightExpression]
            .compactMap(constantExpressionValue)
            .compactMap { $0 as? HMCharacteristic }
            .first
    }

    nonisolated private static func targetValue(
        for predicate: NSComparisonPredicate,
        valueKind: AutomationCapabilityValueKind
    ) -> AutomationCapabilityTargetValue {
        let value = comparisonValue(in: predicate)

        switch valueKind {
        case .boolean:
            return .bool((value as? NSNumber)?.boolValue ?? true)
        case .numeric:
            return .number((value as? NSNumber)?.doubleValue ?? 0)
        case .state:
            return .state((value as? NSNumber)?.intValue ?? 0)
        }
    }

    nonisolated private static func automationOperator(
        for predicate: NSComparisonPredicate,
        valueKind: AutomationCapabilityValueKind
    ) -> AutomationCapabilityOperator {
        switch normalizedOperator(for: predicate) {
        case .greaterThan, .greaterThanOrEqualTo:
            return .greaterThan
        case .lessThan, .lessThanOrEqualTo:
            return .lessThan
        case .equalTo:
            if case .boolean = valueKind {
                return .equals
            }
            return .equals
        default:
            return .equals
        }
    }

    nonisolated private static func comparisonValue(in predicate: NSComparisonPredicate) -> Any? {
        [predicate.leftExpression, predicate.rightExpression]
            .compactMap(constantExpressionValue)
            .first { !($0 is HMCharacteristic) }
    }

    nonisolated private static func normalizedOperator(for predicate: NSComparisonPredicate) -> NSComparisonPredicate.Operator {
        let leftHasValue = constantExpressionValue(predicate.leftExpression).map { !($0 is HMCharacteristic) } ?? false
        let rightHasCharacteristic = (constantExpressionValue(predicate.rightExpression) as? HMCharacteristic) != nil

        guard leftHasValue && rightHasCharacteristic else {
            return predicate.predicateOperatorType
        }

        switch predicate.predicateOperatorType {
        case .greaterThan:
            return .lessThan
        case .greaterThanOrEqualTo:
            return .lessThanOrEqualTo
        case .lessThan:
            return .greaterThan
        case .lessThanOrEqualTo:
            return .greaterThanOrEqualTo
        default:
            return predicate.predicateOperatorType
        }
    }

    nonisolated private static func constantExpressionValue(_ expression: NSExpression) -> Any? {
        guard expression.expressionType == .constantValue else {
            return nil
        }
        return expression.constantValue
    }
}

private extension AutomationPresenceTriggerKind {
    init(homeKitValue: HMPresenceEventType) {
        switch homeKitValue {
        case .everyExit:
            self = .everyExit
        case .firstEntry:
            self = .firstEntry
        case .lastExit:
            self = .lastExit
        default:
            self = .everyEntry
        }
    }
}

private extension AutomationPresenceConditionKind {
    init?(homeKitValue: HMPresenceEventType) {
        switch homeKitValue {
        case .atHome:
            self = .atHome
        case .notAtHome:
            self = .notAtHome
        default:
            return nil
        }
    }
}

private extension AutomationPresenceUserScope {
    init(homeKitValue: HMPresenceEventUserType) {
        switch homeKitValue {
        case .currentUser:
            self = .currentUser
        default:
            self = .homeUsers
        }
    }
}

private extension AutomationPresenceCondition {
    init?(homeKitEvent event: HMPresenceEvent) {
        guard let kind = AutomationPresenceConditionKind(homeKitValue: event.presenceEventType) else {
            return nil
        }
        self.init(
            kind: kind,
            userScope: AutomationPresenceUserScope(homeKitValue: event.presenceUserType)
        )
    }

    func matches(_ event: HMPresenceEvent) -> Bool {
        kind.homeKitValue == event.presenceEventType &&
        userScope.homeKitValue == event.presenceUserType
    }
}

private extension AutomationTimeCondition {
    func matches(_ other: AutomationTimeCondition) -> Bool {
        kind == other.kind &&
        relation == other.relation &&
        offsetMinutes == other.offsetMinutes &&
        Calendar.current.component(.hour, from: time) == Calendar.current.component(.hour, from: other.time) &&
        Calendar.current.component(.minute, from: time) == Calendar.current.component(.minute, from: other.time) &&
        endKind == other.endKind &&
        endOffsetMinutes == other.endOffsetMinutes &&
        Calendar.current.component(.hour, from: endTime) == Calendar.current.component(.hour, from: other.endTime) &&
        Calendar.current.component(.minute, from: endTime) == Calendar.current.component(.minute, from: other.endTime)
    }
}

private extension HMPresenceEvent {
    nonisolated func matches(_ other: HMPresenceEvent) -> Bool {
        presenceEventType == other.presenceEventType &&
        presenceUserType == other.presenceUserType
    }
}

private extension Sequence {
    func uniquedBy<ID: Hashable>(_ id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        return filter { element in
            seen.insert(id(element)).inserted
        }
    }
}

private struct AutomationLocationMapPicker: UIViewRepresentable {
    @Binding var trigger: AutomationLocationTrigger
    let userLocationRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(trigger: $trigger)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapRecognizer.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tapRecognizer)

        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.trigger = $trigger
        context.coordinator.handleUserLocationRequestIfNeeded(userLocationRequestID)
        context.coordinator.render(on: mapView)
    }

    final class Coordinator: NSObject, CLLocationManagerDelegate, MKMapViewDelegate {
        var trigger: Binding<AutomationLocationTrigger>
        weak var mapView: MKMapView?
        private let locationManager = CLLocationManager()
        private var didSetInitialRegion = false
        private var lastHandledUserLocationRequestID = 0

        init(trigger: Binding<AutomationLocationTrigger>) {
            self.trigger = trigger
            super.init()
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView else { return }

            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            trigger.wrappedValue.latitude = coordinate.latitude
            trigger.wrappedValue.longitude = coordinate.longitude
            didSetInitialRegion = true
            render(on: mapView)
            fitVisibleRadius(on: mapView, animated: true)
        }

        func handleUserLocationRequestIfNeeded(_ requestID: Int) {
            guard requestID != lastHandledUserLocationRequestID else { return }
            lastHandledUserLocationRequestID = requestID

            mapView?.showsUserLocation = true

            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.requestLocation()
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        }

        func render(on mapView: MKMapView) {
            mapView.removeAnnotations(mapView.annotations)
            mapView.removeOverlays(mapView.overlays)

            guard trigger.wrappedValue.isValid else {
                if !didSetInitialRegion {
                    let region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964),
                        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
                    )
                    mapView.setRegion(region, animated: false)
                    didSetInitialRegion = true
                }
                return
            }

            let coordinate = CLLocationCoordinate2D(
                latitude: trigger.wrappedValue.latitude,
                longitude: trigger.wrappedValue.longitude
            )
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = trigger.wrappedValue.kind.title
            mapView.addAnnotation(annotation)

            let circle = MKCircle(center: coordinate, radius: trigger.wrappedValue.radius)
            mapView.addOverlay(circle)

            if !didSetInitialRegion {
                fitVisibleRadius(on: mapView, animated: false)
                didSetInitialRegion = true
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                break
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last, let mapView else { return }

            trigger.wrappedValue.latitude = location.coordinate.latitude
            trigger.wrappedValue.longitude = location.coordinate.longitude
            didSetInitialRegion = true
            render(on: mapView)
            fitVisibleRadius(on: mapView, animated: true)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        }

        private func fitVisibleRadius(on mapView: MKMapView, animated: Bool) {
            guard trigger.wrappedValue.isValid else { return }

            let coordinate = CLLocationCoordinate2D(
                latitude: trigger.wrappedValue.latitude,
                longitude: trigger.wrappedValue.longitude
            )
            let circle = MKCircle(center: coordinate, radius: trigger.wrappedValue.radius)
            mapView.setVisibleMapRect(
                circle.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 44, left: 44, bottom: 44, right: 44),
                animated: animated
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.20)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            renderer.lineWidth = 3
            return renderer
        }
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

private struct AutomationStartEventDraft: Identifiable {
    let id: UUID
    var kind: AutomationTriggerSourceKind
    var selection: AutomationCapabilitySelection?
    var schedule: AutomationScheduleTrigger
    var presence: AutomationPresenceTrigger
    var location: AutomationLocationTrigger

    init(
        id: UUID = UUID(),
        kind: AutomationTriggerSourceKind = .accessory,
        selection: AutomationCapabilitySelection? = nil,
        schedule: AutomationScheduleTrigger = AutomationScheduleTrigger(),
        presence: AutomationPresenceTrigger = AutomationPresenceTrigger(),
        location: AutomationLocationTrigger = AutomationLocationTrigger()
    ) {
        self.id = id
        self.kind = kind
        self.selection = selection
        self.schedule = schedule
        self.presence = presence
        self.location = location
    }

    init(selection: AutomationCapabilitySelection) {
        self.init(kind: .accessory, selection: selection)
    }

    init(schedule: AutomationScheduleTrigger) {
        self.init(kind: .time, schedule: schedule)
    }

    init(presence: AutomationPresenceTrigger) {
        self.init(kind: .people, presence: presence)
    }

    init(location: AutomationLocationTrigger) {
        self.init(kind: .location, location: location)
    }

    var isValid: Bool {
        switch kind {
        case .accessory:
            return selection != nil
        case .time, .people:
            return true
        case .location:
            return location.isValid
        }
    }

    var summary: String {
        switch kind {
        case .accessory:
            guard let selection else {
                return String(localized: "automation.wizard.context.missing", defaultValue: "Not set")
            }
            return "\(selection.capability.accessoryName) - \(selection.capability.title)"
        case .time:
            return schedule.summary
        case .people:
            return presence.summary
        case .location:
            return locationDisplaySummary
        }
    }

    var iconName: String {
        switch kind {
        case .accessory:
            return selection?.capability.iconName ?? kind.iconName
        case .time:
            return schedule.kind.iconName
        case .people:
            return presence.kind.iconName
        case .location:
            return location.kind.iconName
        }
    }

    var locationDisplaySummary: String {
        guard location.isValid else {
            return String(localized: "automation.location.needsMapPoint", defaultValue: "Tap the map to set the geofence.")
        }
        return String(format: String(localized: "automation.location.summary.geofence",
                                     defaultValue: "%@ within %d m"),
                      location.kind.title,
                      Int(location.radius.rounded()))
    }

    var startEvent: AutomationStartEvent? {
        switch kind {
        case .accessory:
            guard let selection else { return nil }
            return .accessory(selection)
        case .time:
            return .schedule(schedule)
        case .people:
            return .presence(presence)
        case .location:
            guard location.isValid else { return nil }
            return .location(location)
        }
    }
}

private extension AutomationProposalConditionJoinMode {
    var wizardValue: AutomationConditionJoinMode {
        switch self {
        case .all: return .all
        case .any: return .any
        }
    }
}

private extension AutomationProposalOperator {
    var wizardValue: AutomationCapabilityOperator {
        switch self {
        case .becomesActive: return .becomesActive
        case .becomesInactive: return .becomesInactive
        case .equals: return .equals
        case .greaterThan: return .greaterThan
        case .lessThan: return .lessThan
        }
    }
}

private extension AutomationProposalTargetValue {
    var wizardValue: AutomationCapabilityTargetValue {
        switch self {
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .state(let value): return .state(value)
        }
    }
}

private extension AutomationProposalSchedule {
    var wizardValue: AutomationScheduleTrigger {
        var trigger = AutomationScheduleTrigger()
        trigger.kind = kind.wizardScheduleKind
        trigger.time = Calendar.current.date(
            bySettingHour: max(0, min(hour, 23)),
            minute: max(0, min(minute, 59)),
            second: 0,
            of: Date()
        ) ?? trigger.time
        trigger.offsetMinutes = offsetMinutes
        let resolvedWeekdays = weekdays.compactMap(AutomationScheduleWeekday.init(rawValue:))
        trigger.weekdays = resolvedWeekdays.isEmpty ? Set(AutomationScheduleWeekday.allCases) : Set(resolvedWeekdays)
        return trigger
    }
}

private extension AutomationProposalTimeCondition {
    var wizardValue: AutomationTimeCondition {
        var condition = AutomationTimeCondition()
        condition.kind = kind.wizardTimeConditionKind
        condition.relation = relation.wizardValue
        condition.time = Calendar.current.date(
            bySettingHour: max(0, min(hour, 23)),
            minute: max(0, min(minute, 59)),
            second: 0,
            of: Date()
        ) ?? condition.time
        condition.offsetMinutes = offsetMinutes
        condition.endKind = endKind.wizardTimeConditionKind
        condition.endTime = Calendar.current.date(
            bySettingHour: max(0, min(endHour, 23)),
            minute: max(0, min(endMinute, 59)),
            second: 0,
            of: Date()
        ) ?? condition.endTime
        condition.endOffsetMinutes = endOffsetMinutes
        return condition
    }
}

private extension AutomationProposalScheduleKind {
    var wizardScheduleKind: AutomationScheduleKind {
        switch self {
        case .fixedTime: return .fixedTime
        case .sunrise: return .sunrise
        case .sunset: return .sunset
        }
    }

    var wizardTimeConditionKind: AutomationTimeConditionKind {
        switch self {
        case .fixedTime: return .fixedTime
        case .sunrise: return .sunrise
        case .sunset: return .sunset
        }
    }
}

private extension AutomationProposalTimeRelation {
    var wizardValue: AutomationTimeConditionRelation {
        switch self {
        case .after: return .after
        case .before: return .before
        case .between: return .between
        }
    }
}

private extension AutomationProposalPresenceTrigger {
    var wizardValue: AutomationPresenceTrigger {
        AutomationPresenceTrigger(kind: kind.wizardValue, userScope: userScope.wizardValue)
    }
}

private extension AutomationProposalPresenceTriggerKind {
    var wizardValue: AutomationPresenceTriggerKind {
        switch self {
        case .everyEntry: return .everyEntry
        case .everyExit: return .everyExit
        case .firstEntry: return .firstEntry
        case .lastExit: return .lastExit
        }
    }
}

private extension AutomationProposalPresenceCondition {
    var wizardValue: AutomationPresenceCondition {
        AutomationPresenceCondition(kind: kind.wizardValue, userScope: userScope.wizardValue)
    }
}

private extension AutomationProposalPresenceConditionKind {
    var wizardValue: AutomationPresenceConditionKind {
        switch self {
        case .atHome: return .atHome
        case .notAtHome: return .notAtHome
        }
    }
}

private extension AutomationProposalPresenceUserScope {
    var wizardValue: AutomationPresenceUserScope {
        switch self {
        case .currentUser: return .currentUser
        case .homeUsers: return .homeUsers
        }
    }
}

private extension AutomationProposalLocationTrigger {
    var wizardValue: AutomationLocationTrigger {
        AutomationLocationTrigger(
            kind: kind.wizardValue,
            latitude: latitude,
            longitude: longitude,
            radius: radius
        )
    }
}

private extension AutomationProposalLocationKind {
    var wizardValue: AutomationLocationTriggerKind {
        switch self {
        case .arrive: return .arrive
        case .leave: return .leave
        }
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

    var composerKeyword: String {
        switch self {
        case .all:
            return String(localized: "automation.conditionJoin.all.keyword", defaultValue: "AND")
        case .any:
            return String(localized: "automation.conditionJoin.any.keyword", defaultValue: "OR")
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
