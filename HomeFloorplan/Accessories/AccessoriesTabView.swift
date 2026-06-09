import SwiftUI
import HomeKit

// MARK: - AccessoriesTabView
//
// Nuovo root del modulo Accessori. Sostituisce AllAccessoriesView come
// destination nella sidebar (case .allAccessories in ContentView).
//
// Struttura verticale (identica a EnvironmentDashboardView):
//   1. AccessoriesHeroView       — score globale, totale accessori/stanze, alert
//   2. Filter bar (categoria + stato) — logica migrata da AllAccessoriesView
//   3a. LazyVGrid (2 colonne)    — AccessoryRoomCard per ogni stanza (filtri inattivi)
//   3b. Lista flat               — AccessoryFlatRow per accessorio (filtri attivi)
//
// Navigazione:
//   Tap su card stanza  →  NavigationStack push  →  AccessoryRoomDetailView
//   Tap su riga flat    →  Sheet  →  AccessoryDetailView

struct AccessoriesTabView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var vm: AccessoriesViewModel?

    // Navigazione stanza (grid mode)
    @State private var selectedRoom: RoomAccessoryData?

    // Navigazione accessorio singolo (flat mode)
    @State private var selectedAccessory: HMAccessory?

    // Riordino stanze
    @State private var isReordering = false

    // iPad: 2 colonne adattive da 300pt min, identico a EnvironmentDashboardView
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    content(vm: vm)
                } else {
                    loadingState
                }
            }
            .navigationTitle(String(localized: "accessories.navigationTitle", defaultValue: "Accessories"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar { toolbarContent }
            .searchable(
                text: Binding(
                    get: { vm?.searchText ?? "" },
                    set: { vm?.searchText = $0 }
                ),
                placement: .navigationBarDrawer(displayMode: .always)
            )
            .navigationDestination(item: $selectedRoom) { room in
                AccessoryRoomDetailView(room: room)
            }
            .sheet(item: $selectedAccessory) { accessory in
                AccessoryDetailView(accessory: accessory)
            }
            .sheet(isPresented: $isReordering) {
                if let vm {
                    RoomReorderSheet(vm: vm)
                }
            }
        }
        .onAppear {
            if vm == nil {
                vm = AccessoriesViewModel(homeKit: homeKit)
            }
            vm?.refresh()
        }
        .onChange(of: homeKit.allAccessories.count) { _, _ in
            vm?.refresh()
        }
        // reachabilityVersion si incrementa ad ogni cambio di valore nella mappa
        // (non solo al cambio di conteggio), garantendo aggiornamenti UI tempestivi.
        .onChange(of: homeKit.reachabilityVersion) { _, _ in
            vm?.refresh()
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(vm: AccessoriesViewModel) -> some View {
        if vm.isLoading && vm.rooms.isEmpty {
            loadingState
        } else if vm.rooms.isEmpty {
            emptyState
        } else {
            scrollContent(vm: vm)
        }
    }

    // MARK: - Scroll content

    private func scrollContent(vm: AccessoriesViewModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── 1. Hero ────────────────────────────────────────────
                AccessoriesHeroView(
                    score: vm.globalHealthScore,
                    level: vm.globalHealthLevel,
                    totalAccessories: vm.totalAccessoryCount,
                    totalRooms: vm.totalRoomCount,
                    offlineCount: vm.totalOfflineCount,
                    lowBatteryCount: vm.totalLowBatteryCount
                )

                // ── 2. Filter bar ──────────────────────────────────────
                AccessoriesFilterBar(vm: vm)

                // ── 3. Header sezione ──────────────────────────────────
                // Mostra "Accessori N" in flat mode, "Stanze N" in grid mode.
                if vm.hasActiveFilters {
                    let count = vm.filteredAccessories.count
                    if count > 0 {
                        HStack {
                            Text(String(localized: "accessories.section.accessories",
                                        defaultValue: "Accessories"))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 4)
                    }
                } else {
                    let filtered = vm.filteredRooms
                    if !filtered.isEmpty {
                        HStack {
                            Text(String(localized: "accessories.section.rooms", defaultValue: "Rooms"))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(filtered.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 4)
                    }
                }

                // ── 4. Contenuto principale ────────────────────────────
                if vm.hasActiveFilters {
                    // Flat list: lista diretta degli accessori che matchano
                    let items = vm.filteredAccessories
                    if items.isEmpty {
                        noResultsState
                    } else {
                        flatAccessoryList(items: items)
                    }
                } else {
                    // Grid mode: card per stanza (comportamento originale)
                    let filtered = vm.filteredRooms
                    if filtered.isEmpty {
                        noResultsState
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered) { room in
                                AccessoryRoomCard(room: room) {
                                    selectedRoom = room
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.hasActiveFilters)
        }
    }

    // MARK: - Flat accessory list

    @ViewBuilder
    private func flatAccessoryList(items: [FlatAccessoryItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                let adapter = AccessoryAdapterFactory.adapter(for: item.accessory, homeKit: homeKit)
                AccessoryFlatRow(
                    item: item,
                    adapter: adapter,
                    homeKit: homeKit,
                    iconOverrides: iconOverrides
                ) {
                    selectedAccessory = item.accessory
                }

                if item.id != items.last?.id {
                    Divider()
                        .padding(.horizontal, 16)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text(String(localized: "accessories.loading", defaultValue: "Loading HomeKit accessories…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                String(localized: "accessories.empty.title", defaultValue: "No Accessories"),
                systemImage: "house"
            )
        } description: {
            VStack(spacing: 8) {
                Text(String(localized: "accessories.empty.description",
                            defaultValue: "The active home has no configured accessories."))
                Text(String(localized: "accessories.empty.hint",
                            defaultValue: "Add accessories from the Apple Home app to manage them here."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            if let url = URL(string: "x-apple-homekit://"), UIApplication.shared.canOpenURL(url) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(
                        String(localized: "accessories.empty.openHome", defaultValue: "Open Home"),
                        systemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            String(localized: "accessories.noResults.title", defaultValue: "No Results"),
            systemImage: "magnifyingglass",
            description: Text(
                vm?.searchText.isEmpty == false
                    ? String(localized: "accessories.noResults.searchHint",
                             defaultValue: "Adjust your search or filters.")
                    : String(localized: "accessories.noResults.filterHint",
                             defaultValue: "Adjust filters to see accessories.")
            )
        )
        .padding(.top, 40)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                // Pulsante riordina stanze (disabilitato in flat mode — non ha senso riordinare)
                Button {
                    isReordering = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(vm == nil || vm?.rooms.isEmpty == true || vm?.hasActiveFilters == true)

                // Pulsante reset filtri — abilitato solo se c'è almeno un filtro attivo
                let hasActiveFilters = vm?.hasActiveFilters ?? false
                Button {
                    vm?.resetFilters()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolVariant(hasActiveFilters ? .fill : .none)
                }
                .disabled(vm == nil || !hasActiveFilters)
            }
        }
    }
}

// MARK: - AccessoryFlatRow

/// Riga per un singolo accessorio nella lista flat (filtri attivi).
/// Mostra: icona colorata, nome, stanza + stato, badge batteria, offline indicator, chevron.
private struct AccessoryFlatRow: View {

    let item: FlatAccessoryItem
    let adapter: (any AccessoryAdapter)?
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {

                // Icona con sfondo colorato
                let appearance = AccessoryAppearance.from(adapter)
                let iconName = adapter.map { iconOverrides.effectiveIcon(for: item.accessory, adapter: $0) }
                    ?? "questionmark.circle"
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(appearance.statusColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(appearance.statusColor)
                }

                // Nome + stanza + stato
                let isOffline = !homeKit.isReachable(item.accessory)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.accessory.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(item.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if isOffline {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "accessories.row.offline",
                                        defaultValue: "Unreachable"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let status = adapter?.primaryStatusText {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Badge batteria
                if let battery = adapter?.batteryInfo {
                    BatteryBadgeView(info: battery)
                }

                // Indicatore offline
                if isOffline {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Chevron navigazione
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AccessoriesFilterBar

/// Barra filtri: riga categoria + riga stato.
/// Logica migrata verbatim da AllAccessoriesView — nessuna modifica alla logica.
private struct AccessoriesFilterBar: View {

    @Bindable var vm: AccessoriesViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Riga 1: categorie
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AccessoryCategory.allCases) { category in
                        filterPill(
                            title: category.displayName,
                            symbol: category.symbolName,
                            isSelected: vm.selectedCategory == category
                        ) {
                            vm.selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Riga 2: stato
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AccessoryStateFilter.allCases) { state in
                        filterPill(
                            title: state.displayName,
                            symbol: state.symbolName,
                            isSelected: vm.selectedStateFilter == state
                        ) {
                            vm.selectedStateFilter = state
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color.clear.overlay(.thinMaterial.opacity(0.6)))
    }

    private func filterPill(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected
                          ? AnyShapeStyle(BrandColor.heroGradient)
                          : AnyShapeStyle(.regularMaterial))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - RoomReorderSheet

/// Sheet che permette di riordinare le stanze con drag-and-drop.
/// L'ordine viene salvato in UserDefaults via AccessoriesViewModel.saveOrder().
private struct RoomReorderSheet: View {

    @Bindable var vm: AccessoriesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var localRooms: [RoomAccessoryData] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(localRooms) { room in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text(room.roomName)
                            .font(.body)
                        Spacer()
                        Text(room.subtitleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    localRooms.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "accessories.reorder.title", defaultValue: "Reorder Rooms"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "accessories.reorder.reset", defaultValue: "Reset")) {
                        vm.saveOrder([])   // ordine vuoto = torna ad alfabetico
                        vm.refresh()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "accessories.reorder.done", defaultValue: "Done")) {
                        vm.saveOrder(localRooms)
                        vm.refresh()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localRooms = vm.rooms
        }
    }
}

// MARK: - HMAccessory + Identifiable (già esteso in HMAccessory+Identifiable.swift)
// Non serve riestendere qui.

// MARK: - Preview

#Preview {
    let homeKit = HomeKitService()
    let iconStore = IconOverrideStore()
    return AccessoriesTabView()
        .environment(homeKit)
        .environment(iconStore)
}
