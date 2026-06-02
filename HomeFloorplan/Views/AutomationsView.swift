import SwiftUI
import HomeKit

/// Vista read-only delle automazioni HomeKit con toggle abilita/disabilita.
struct AutomationsView: View {

    @Environment(HomeKitAutomationsService.self) private var automationsService
    @State private var selectedType: TypeFilter = .all
    @State private var toggleError: String?
    @State private var togglingID: String?

    // MARK: - Filtri per tipo

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all        = "all"
        case timer      = "timer"
        case event      = "event"
        case location   = "location"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:      return String(localized: "filter.all",      defaultValue: "Tutte")
            case .timer:    return String(localized: "filter.timer",    defaultValue: "Timer")
            case .event:    return String(localized: "filter.event",    defaultValue: "Evento")
            case .location: return String(localized: "filter.location", defaultValue: "Posizione")
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
        automationsService.automations.filter { selectedType.matches($0) }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if automationsService.automations.isEmpty {
                emptyState
            } else {
                automationsList
            }
        }
        .navigationTitle(String(localized: "automations.navigationTitle", defaultValue: "Automazioni"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            automationsService.refresh()
        }
        .refreshable {
            automationsService.refresh()
        }
        .alert(String(localized: "alert.error.title", defaultValue: "Errore"),
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
            Label(String(localized: "automations.empty.title", defaultValue: "Nessuna automazione"), systemImage: "gearshape.2")
        } description: {
            Text(String(localized: "automations.empty.description", defaultValue: "Non hai configurato automazioni in HomeKit. Puoi crearle dall'app Casa di Apple."))
        }
    }

    private var automationsList: some View {
        List {
            // Filtro tipo
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TypeFilter.allCases) { filter in
                            filterPill(filter)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)

            // Automazioni
            Section {
                ForEach(filtered) { item in
                    automationRow(item)
                }
            } footer: {
                Text("\(filtered.count) \(String(localized: "automations.footer.count", defaultValue: "automazioni"))")
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
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
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(.regularMaterial))
                )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func automationRow(_ item: AutomationItem) -> some View {
        HStack(spacing: 12) {
            // Icona tipo
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(typeColor(item.triggerType).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: item.triggerType.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(typeColor(item.triggerType))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)

                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if item.actionCount > 0 {
                    Text("\(item.actionCount) \(item.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "azione") : String(localized: "count.action.plural", defaultValue: "azioni"))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

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
                                toggleError = "\(String(localized: "automations.toggleError.prefix", defaultValue: "Impossibile modificare l'automazione:")): \(error.localizedDescription)"
                            }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
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
