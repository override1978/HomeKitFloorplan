import SwiftUI
import SwiftData

/// Vista che mostra il log cronologico delle attività HomeKit dell'app.
/// Gli eventi sono caricati da SwiftData e raggruppati per giorno.
struct ActivityLogView: View {

    @Query(sort: \ActivityEvent.timestamp, order: .reverse)
    private var allEvents: [ActivityEvent]

    @State private var selectedCategory: CategoryFilter = .all
    @State private var showClearConfirm = false
    @Environment(ActivityLoggerService.self) private var logger

    // MARK: - Filtri categoria

    enum CategoryFilter: String, CaseIterable, Identifiable {
        case all        = "all"
        case scenes     = "scenes"
        case writes     = "writes"
        case external   = "external"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:      return String(localized: "log.filter.all",      defaultValue: "All")
            case .scenes:   return String(localized: "log.filter.scenes",   defaultValue: "Scenes")
            case .writes:   return String(localized: "log.filter.writes",   defaultValue: "Toggle")
            case .external: return String(localized: "log.filter.external", defaultValue: "External")
            }
        }

        func matches(_ event: ActivityEvent) -> Bool {
            switch self {
            case .all:      return true
            case .scenes:   return event.category == .sceneExecution
            case .writes:   return event.category == .write
            case .external: return event.category == .externalChange
            }
        }

        var systemImage: String {
            switch self {
            case .all:      return "list.bullet"
            case .scenes:   return "play.fill"
            case .writes:   return "slider.horizontal.3"
            case .external: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    // MARK: - Computed

    private var filteredEvents: [ActivityEvent] {
        allEvents.filter { selectedCategory.matches($0) }
    }

    /// Raggruppa gli eventi per giorno (startOfDay).
    private var groupedByDay: [(date: Date, events: [ActivityEvent])] {
        let grouped = Dictionary(grouping: filteredEvents, by: { $0.sectionDate })
        return grouped
            .map { (date: $0.key, events: $0.value) }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if filteredEvents.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle(String(localized: "activityLog.navigationTitle", defaultValue: "Activity Log"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !allEvents.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                String(localized: "activityLog.clearConfirm.title", defaultValue: "Clear entire log?"),
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "activityLog.clearConfirm.action", defaultValue: "Clear Log"), role: .destructive) {
                    logger.clearAll()
                }
                Button(String(localized: "activityLog.clearConfirm.cancel", defaultValue: "Cancel"), role: .cancel) {}
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "activityLog.empty.title", defaultValue: "No Activity"), systemImage: "clock.arrow.circlepath")
        } description: {
            Text(String(localized: "activityLog.empty.description", defaultValue: "Actions you perform in the app will appear here: scenes triggered, toggles, and changes received from HomeKit."))
        }
    }

    private var eventList: some View {
        List {
            // Filter pills
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CategoryFilter.allCases) { filter in
                            filterPill(filter)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)

            // Events grouped by day
            ForEach(groupedByDay, id: \.date) { group in
                Section(header: dayHeader(group.date)) {
                    ForEach(group.events) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func filterPill(_ filter: CategoryFilter) -> some View {
        let isSelected = selectedCategory == filter
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedCategory = filter
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.systemImage)
                    .font(.caption2.weight(.semibold))
                Text(filter.label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(BrandColor.heroGradient) : AnyShapeStyle(.regularMaterial))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func dayHeader(_ date: Date) -> some View {
        Text(date, style: .date)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func eventRow(_ event: ActivityEvent) -> some View {
        HStack(spacing: 12) {
            // Icona categoria
            ZStack {
                Circle()
                    .fill(categoryColor(event.category).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: event.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(categoryColor(event.category))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body)
                    .lineLimit(1)
                Text(event.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let roomName = event.roomName, !roomName.isEmpty {
                    Label(roomName, systemImage: "square.split.bottomrightquarter.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(event.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func categoryColor(_ category: ActivityEventCategory) -> Color {
        switch category {
        case .sceneExecution: return .accentColor
        case .write:          return .orange
        case .externalChange: return .green
        }
    }
}
