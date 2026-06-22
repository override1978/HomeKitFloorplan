import SwiftUI
import HomeKit

/// Vista read-only delle automazioni HomeKit con toggle abilita/disabilita.
struct AutomationsView: View {

    @Environment(HomeKitAutomationsService.self) private var automationsService
    @State private var selectedType: TypeFilter = .all
    @State private var searchText: String = ""
    @State private var toggleError: String?
    @State private var togglingID: String?
    @State private var showAutomationWizard = false
    @State private var selectedAutomation: AutomationItem?
    @State private var editingAutomation: AutomationItem?

    // MARK: - Filtri per tipo

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all        = "all"
        case timer      = "timer"
        case event      = "event"
        case location   = "location"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:      return String(localized: "filter.all",      defaultValue: "All")
            case .timer:    return String(localized: "filter.timer",    defaultValue: "Timer")
            case .event:    return String(localized: "filter.event",    defaultValue: "Event")
            case .location: return String(localized: "filter.location", defaultValue: "Location")
            }
        }

        func matches(_ item: AutomationItem) -> Bool {
            switch self {
            case .all:      return true
            case .timer:    return item.triggerType == .timer
            case .event:    return item.triggerType == .event || item.triggerType == .time
            case .location: return item.triggerType == .location || item.triggerType == .presence
            }
        }
    }

    // MARK: - Computed

    private var filtered: [AutomationItem] {
        let typed = automationsService.automations.filter { selectedType.matches($0) }
        guard !searchText.isEmpty else { return typed }
        let needle = searchText.lowercased()
        return typed.filter {
            $0.name.lowercased().contains(needle) ||
            $0.summary.lowercased().contains(needle) ||
            $0.triggerType.localizedName.lowercased().contains(needle)
        }
    }

    private var enabledCount: Int {
        automationsService.automations.filter(\.isEnabled).count
    }

    private var disabledCount: Int {
        automationsService.automations.count - enabledCount
    }

    private var dominantType: TypeFilter {
        let candidates: [TypeFilter] = [.timer, .event, .location]
        return candidates.max { lhs, rhs in
            automationsService.automations.filter { lhs.matches($0) }.count <
                automationsService.automations.filter { rhs.matches($0) }.count
        } ?? .all
    }

    // MARK: - Body

    var body: some View {
        Group {
            if automationsService.automations.isEmpty {
                emptyState
            } else {
                scrollContent
            }
        }
        .navigationTitle(String(localized: "automations.navigationTitle", defaultValue: "Automations"))
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAutomationWizard = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "automations.create.accessibility", defaultValue: "Create Automation"))
            }
        }
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "automations.search.prompt", defaultValue: "Search automations"))
        .sheet(isPresented: $showAutomationWizard, onDismiss: {
            automationsService.refresh()
        }) {
            AutomationWizardSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedAutomation, onDismiss: {
            automationsService.refresh()
        }) { item in
            ExistingAutomationSheet(item: item) { item in
                selectedAutomation = nil
                DispatchQueue.main.async {
                    editingAutomation = item
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingAutomation, onDismiss: {
            automationsService.refresh()
        }) { item in
            AutomationWizardSheet(editing: item)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            automationsService.refresh()
        }
        .refreshable {
            automationsService.refresh()
        }
        .alert(String(localized: "alert.error.title", defaultValue: "Error"),
               isPresented: Binding(
                get: { toggleError != nil },
                set: { if !$0 { toggleError = nil } }
               ),
               presenting: toggleError) { _ in
            Button("OK") {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "automations.empty.title", defaultValue: "No Automations"), systemImage: "gearshape.2")
        } description: {
            Text(String(localized: "automations.empty.description", defaultValue: "No automations configured in HomeKit. Create a scene-based automation here."))
        } actions: {
            Button {
                showAutomationWizard = true
            } label: {
                Label(String(localized: "automations.empty.create", defaultValue: "Create Automation"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColor.primary)
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if searchText.isEmpty {
                    AutomationsHeroView(
                        totalCount: automationsService.automations.count,
                        enabledCount: enabledCount,
                        disabledCount: disabledCount,
                        dominantType: dominantType.label
                    )
                }

                automationFilterBar

                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText.isEmpty ? selectedType.label : searchText)
                        .padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        automationSectionHeader

                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { item in
                                automationCard(item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .refreshable {
            automationsService.refresh()
        }
    }

    private var automationFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TypeFilter.allCases) { filter in
                    filterPill(filter)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var automationSectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
            Text(String(localized: "automations.section.all", defaultValue: "AUTOMATIONS"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            Text("\(filtered.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private func filterPill(_ filter: TypeFilter) -> some View {
        let isSelected = selectedType == filter
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedType = filter
            }
        } label: {
            Text(filter.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(.regularMaterial))
                )
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func automationCard(_ item: AutomationItem) -> some View {
        HStack(spacing: 12) {
            Button {
                if item.actionSetNames.isEmpty {
                    selectedAutomation = item
                } else {
                    editingAutomation = item
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(typeColor(item.triggerType).opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: item.triggerType.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(typeColor(item.triggerType))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            Text(item.triggerType.localizedName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(typeColor(item.triggerType))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(typeColor(item.triggerType).opacity(0.12), in: Capsule())
                        }

                        Text(item.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if item.actionCount > 0 {
                            Text("\(item.actionCount) \(item.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "action") : String(localized: "count.action.plural", defaultValue: "actions"))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else if item.actionSetNames.isEmpty {
                            Label(String(localized: "automation.existing.openHome.short", defaultValue: "Apri in Apple Home"), systemImage: "arrow.up.forward.app")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(BrandColor.primary)
                        }
                    }

                    Spacer()

                    Image(systemName: item.actionSetNames.isEmpty ? "arrow.up.forward.app" : "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // Toggle con feedback visivo durante aggiornamento
            if togglingID == item.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { newValue in
                        Task {
                            togglingID = item.id
                            defer { togglingID = nil }
                            do {
                                try await automationsService.setEnabled(newValue, for: item)
                            } catch {
                                toggleError = "\(String(localized: "automations.toggleError.prefix", defaultValue: "Cannot change automation:")): \(error.localizedDescription)"
                            }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
        }
        .opacity(item.isEnabled ? 1.0 : 0.65)
    }

    private func typeColor(_ type: AutomationTriggerType) -> Color {
        switch type {
        case .timer:    return .blue
        case .event:    return .orange
        case .location: return .green
        case .presence: return .purple
        case .time:     return .indigo
        case .unknown:  return .secondary
        }
    }
}

private struct AutomationsHeroView: View {
    let totalCount: Int
    let enabledCount: Int
    let disabledCount: Int
    let dominantType: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrandColor.primary)
                        Text(String(localized: "automations.hero.label", defaultValue: "YOUR AUTOMATIONS"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(totalCount)")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())

                        Text(totalCount == 1
                             ? String(localized: "automations.hero.singular", defaultValue: "automation")
                             : String(localized: "automations.hero.plural", defaultValue: "automations"))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(BrandColor.primary.opacity(0.13))
                        .frame(width: 76, height: 76)
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(BrandColor.primary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            HStack(spacing: 0) {
                heroStatCell(
                    icon: "checkmark.circle.fill",
                    iconColor: .green,
                    title: String(localized: "automations.hero.enabled", defaultValue: "Enabled"),
                    value: "\(enabledCount)"
                )

                Divider().frame(height: 36)

                heroStatCell(
                    icon: "pause.circle.fill",
                    iconColor: .secondary,
                    title: String(localized: "automations.hero.paused", defaultValue: "Paused"),
                    value: "\(disabledCount)"
                )

                Divider().frame(height: 36)

                heroStatCell(
                    icon: "chart.bar.fill",
                    iconColor: BrandColor.primary,
                    title: String(localized: "automations.hero.mainType", defaultValue: "Main Type"),
                    value: dominantType
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(BrandColor.primary.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: BrandColor.primary.opacity(0.08), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    private func heroStatCell(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExistingAutomationSheet: View {
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(\.dismiss) private var dismiss

    let item: AutomationItem
    let onEdit: (AutomationItem) -> Void
    @State private var name: String
    @State private var isEnabled: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != item.name || isEnabled != item.isEnabled
    }

    init(item: AutomationItem, onEdit: @escaping (AutomationItem) -> Void) {
        self.item = item
        self.onEdit = onEdit
        _name = State(initialValue: item.name)
        _isEnabled = State(initialValue: item.isEnabled)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionPhrase(
                        keyword: String(localized: "automation.existing.name", defaultValue: "NAME"),
                        text: String(localized: "automation.existing.name.text", defaultValue: "update how this automation appears")
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

                    sectionPhrase(
                        keyword: String(localized: "automation.composer.if", defaultValue: "IF"),
                        text: String(localized: "automation.existing.if.text", defaultValue: "this existing HomeKit automation is triggered by")
                    )

                    summaryCard(
                        icon: item.triggerType.systemImage,
                        title: item.triggerType.localizedName,
                        value: item.summary,
                        tint: typeColor(item.triggerType)
                    )

                    if item.actionSetNames.isEmpty {
                        openAppleHomeCard
                    }

                    sectionPhrase(
                        keyword: String(localized: "automation.composer.conditions.ifNeeded", defaultValue: "AND"),
                        text: String(localized: "automation.existing.conditions.text", defaultValue: "only while these HomeKit checks match")
                    )

                    if !item.conditionSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(item.conditionSummaries.enumerated()), id: \.offset) { _, condition in
                                summaryCard(
                                    icon: "checklist.checked",
                                    title: String(localized: "automation.existing.conditions.title", defaultValue: "Conditions"),
                                    value: condition,
                                    tint: BrandColor.primary
                                )
                            }
                        }
                    } else {
                        summaryCard(
                            icon: "checkmark.circle",
                            title: String(localized: "automation.existing.conditions.none.title", defaultValue: "No conditions"),
                            value: String(localized: "automation.existing.conditions.none.value", defaultValue: "This automation can run whenever the trigger happens."),
                            tint: .secondary
                        )
                    }

                    sectionPhrase(
                        keyword: String(localized: "automation.composer.then", defaultValue: "THEN"),
                        text: String(localized: "automation.existing.then.text", defaultValue: "run these scenes")
                    )

                    if item.actionSetNames.isEmpty {
                        summaryCard(
                            icon: "wand.and.sparkles",
                            title: String(localized: "automation.existing.scenes.none.title", defaultValue: "No scenes"),
                            value: String(localized: "automation.existing.scenes.none.value", defaultValue: "No HomeKit scene is attached to this automation."),
                            tint: .secondary
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(item.actionSetNames, id: \.self) { sceneName in
                                summaryCard(
                                    icon: "wand.and.sparkles",
                                    title: sceneName,
                                    value: String(localized: "automation.existing.scene.actionSet", defaultValue: "HomeKit scene"),
                                    tint: BrandColor.primary
                                )
                            }
                        }
                    }

                    sectionPhrase(
                        keyword: String(localized: "automation.existing.done", defaultValue: "DONE"),
                        text: String(localized: "automation.existing.done.text", defaultValue: "keep it active when saved"),
                        keywordColor: Color(.systemRed)
                    )

                    Toggle(isOn: $isEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "automation.composer.activate", defaultValue: "Activate Automation"))
                                .font(.headline)
                            Text(String(localized: "automation.existing.activate.subtitle", defaultValue: "Disable it to keep the automation saved but paused in HomeKit."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if !item.actionSetNames.isEmpty {
                        Button {
                            onEdit(item)
                        } label: {
                            Label(String(localized: "automation.existing.edit", defaultValue: "Edit Automation"), systemImage: "slider.horizontal.3")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(BrandColor.primary)
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(String(localized: "automation.existing.delete", defaultValue: "Delete Automation"), systemImage: "trash")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "automation.existing.title", defaultValue: "Automation"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                bottomBar
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
            .confirmationDialog(
                String(localized: "automation.existing.delete.confirmTitle", defaultValue: "Delete this automation?"),
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "automation.existing.delete.confirm", defaultValue: "Delete Automation"), role: .destructive) {
                    deleteAutomation()
                }
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "automation.existing.delete.confirmMessage", defaultValue: "This removes the automation from HomeKit."))
            }
        }
    }

    private var openAppleHomeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up.forward.app")
                .font(.headline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 42, height: 42)
                .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "automation.existing.openHome.title", defaultValue: "Apri in Apple Home"))
                    .font(.headline)
                Text(String(localized: "automation.existing.openHome.value", defaultValue: "Questa automazione non e basata su una scena, quindi va modificata da Apple Home."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var bottomBar: some View {
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
                saveChanges()
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
            .disabled(!hasChanges || isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func saveChanges() {
        isSaving = true
        Task {
            do {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != item.name {
                    try await automationsService.rename(trimmed, for: item)
                }
                if isEnabled != item.isEnabled {
                    try await automationsService.setEnabled(isEnabled, for: item)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteAutomation() {
        isSaving = true
        Task {
            do {
                try await automationsService.delete(item)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
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

    private func summaryCard(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func typeColor(_ type: AutomationTriggerType) -> Color {
        switch type {
        case .timer:    return .blue
        case .event:    return .orange
        case .location: return .green
        case .presence: return .purple
        case .time:     return .indigo
        case .unknown:  return .secondary
        }
    }
}
