import SwiftUI
import HomeKit
import Observation

struct AllAccessoriesView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    
    @State private var searchText: String = ""
    @State private var selectedCategory: AccessoryCategory = .all
    @State private var selectedStateFilter: AccessoryStateFilter = .all

    // Group accessories by room name, or "No Room" if unavailable
    private var accessoriesByRoom: [String: [HMAccessory]] {
        let filtered: [HMAccessory]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = homeKit.allAccessories
        } else {
            filtered = homeKit.allAccessories.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return Dictionary(grouping: filtered) { accessory in
            accessory.room?.name ?? "Nessuna stanza"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                
                List {
                    if homeKit.allAccessories.isEmpty {
                        // Caso A: casa HomeKit vuota
                        ContentUnavailableView {
                            Label("Nessun accessorio", systemImage: "house")
                        } description: {
                            VStack(spacing: 8) {
                                Text("La casa attiva non ha accessori configurati.")
                                Text("Aggiungi accessori dall'app Casa di Apple per gestirli qui.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } actions: {
                            if let url = URL(string: "x-apple-homekit://"), UIApplication.shared.canOpenURL(url) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Label("Apri Casa", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else if filteredGroups.isEmpty {
                        // Caso B: ci sono accessori ma i filtri/search non trovano niente
                        ContentUnavailableView(
                            "Nessun risultato",
                            systemImage: "magnifyingglass",
                            description: Text(searchText.isEmpty
                                              ? "Modifica i filtri per vedere accessori."
                                              : "Modifica la ricerca o i filtri.")
                        )
                    } else {
                        // Caso C: normale - renderizza le sezioni stanze
                        ForEach(filteredGroups, id: \.roomID) { group in
                            roomSection(group)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                //.background(Color.clear)
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always))
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Accessori")
        }
    }

    // MARK: - Room section (insetGrouped + custom expand/collapse)

    private func roomSection(_ group: RoomGroup) -> some View {
        let isExpanded = !collapsedRooms.contains(group.roomID)
        
        return Section {
            if isExpanded {
                ForEach(group.accessories, id: \.uniqueIdentifier) { accessory in
                    NavigationLink {
                        AccessoryDetailView(accessory: accessory)
                    } label: {
                        accessoryRow(accessory)
                    }
                }
            }
        } header: {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    toggleExpanded(group.roomID)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "square.split.bottomrightquarter.fill")
                        .foregroundStyle(BrandColor.primary)
                        .font(.subheadline)
                    
                    Text(group.roomName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Text(group.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
        }
    }

    // MARK: - Expanded state

    @State private var collapsedRooms: Set<UUID> = []

    private func toggleExpanded(_ roomID: UUID) {
        if collapsedRooms.contains(roomID) {
            collapsedRooms.remove(roomID)
        } else {
            collapsedRooms.insert(roomID)
        }
    }

    private func roomHeader(_ group: RoomGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.split.bottomrightquarter.fill")
                .foregroundStyle(.tint)
                .font(.subheadline)
            
            Text(group.roomName)
                .font(.headline)
                .foregroundStyle(.primary)
            
            Spacer()
            
            Text(group.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    // MARK: - Filter & group

    private struct RoomGroup {
        let roomID: UUID
        let roomName: String
        let accessories: [HMAccessory]
        let onCount: Int
        
        var summaryText: String {
            if onCount > 0 {
                return "\(accessories.count) • \(onCount) attivi"
            }
            return "\(accessories.count)"
        }
    }

    private var filteredGroups: [RoomGroup] {
        // 1. Filtro lineare
        var accessories = homeKit.allAccessories
        
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            accessories = accessories.filter { $0.name.lowercased().contains(needle) }
        }
        
        if selectedCategory != .all {
            accessories = accessories.filter { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                return AccessoryCategory.classify(adapter: adapter) == selectedCategory
            }
        }
        
        if selectedStateFilter != .all {
            accessories = accessories.filter { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                let isOffline = homeKit.isLikelyOffline(accessory)
                return selectedStateFilter.matches(adapter: adapter, isOffline: isOffline)
            }
        }
        
        // 2. Raggruppa per stanza
        let grouped = Dictionary(grouping: accessories) { accessory -> UUID in
            accessory.room?.uniqueIdentifier ?? UUID.zero
        }
        
        // 3. Costruisci RoomGroup con count "attivi"
        let groups: [RoomGroup] = grouped.map { (roomID, accessories) -> RoomGroup in
            let roomName: String = {
                if roomID == UUID.zero { return "Senza stanza" }
                return accessories.first?.room?.name ?? "—"
            }()
            let sortedAccessories = accessories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let onCount = sortedAccessories.filter { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                return adapter.isOn
            }.count
            return RoomGroup(roomID: roomID,
                             roomName: roomName,
                             accessories: sortedAccessories,
                             onCount: onCount)
        }
        
        return groups.sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            // Riga 1: Categorie
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AccessoryCategory.allCases) { category in
                        filterPill(
                            title: category.displayName,
                            symbol: category.symbolName,
                            count: countForCategory(category),
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            // Riga 2: Stato
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AccessoryStateFilter.allCases) { state in
                        filterPill(
                            title: state.displayName,
                            symbol: state.symbolName,
                            count: nil,
                            isSelected: selectedStateFilter == state
                        ) {
                            selectedStateFilter = state
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(
            Color.clear
                .overlay(.thinMaterial.opacity(0.6))   // mescola brand + material per leggibilità
        )
    }

    private func filterPill(title: String, symbol: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected
                          ? AnyShapeStyle(BrandColor.secondary)
                          : AnyShapeStyle(.regularMaterial))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    // MARK: - Filter logic

    private var filteredAccessories: [HMAccessory] {
        var result = homeKit.allAccessories
        
        // Search text
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        
        // Category filter
        if selectedCategory != .all {
            result = result.filter { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                return AccessoryCategory.classify(adapter: adapter) == selectedCategory
            }
        }
        
        // State filter
        if selectedStateFilter != .all {
            result = result.filter { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                let isOffline = homeKit.isLikelyOffline(accessory)
                return selectedStateFilter.matches(adapter: adapter, isOffline: isOffline)
            }
        }
        
        return result
    }

    private func countForCategory(_ category: AccessoryCategory) -> Int {
        if category == .all { return homeKit.allAccessories.count }
        return homeKit.allAccessories.filter { accessory in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            return AccessoryCategory.classify(adapter: adapter) == category
        }.count
    }
    
    // MARK: - Row
    
    @ViewBuilder
    private func accessoryRow(_ accessory: HMAccessory) -> some View {
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
        
        HStack(spacing: 12) {
            AccessoryIconView(iconName: iconName)
                .foregroundStyle(AccessoryAppearance.from(adapter).statusColor)
                .frame(width: 22, height: 22)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.body)
                Text(summaryFor(accessory: accessory, adapter: adapter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            if let battery = adapter.batteryInfo {
                    BatteryBadgeView(info: battery)
                }
            
            if homeKit.isLikelyOffline(accessory) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Summary
    
    /// Riassunto testuale: dove possibile usa l'adapter (più preciso),
    /// altrimenti cade su ricerca diretta delle caratteristiche.
    private func summaryFor(accessory: HMAccessory, adapter: any AccessoryAdapter) -> String {
        // Adapter espone già un primaryStatusText per molti casi (sensori, robot...)
        if let status = adapter.primaryStatusText {
            return status
        }
        // Fallback: power state + brightness se è una luce dimmerabile
        if let on = boolCharacteristic(type: HMCharacteristicTypePowerState, in: accessory) {
            if let brightness = intCharacteristic(type: HMCharacteristicTypeBrightness, in: accessory) {
                return on ? "Acceso • \(brightness)%" : "Spento"
            }
            return on ? "Acceso" : "Spento"
        }
        return ""
    }

    // MARK: - Characteristic helpers (per fallback summary)
    
    private func characteristic(with type: String, in accessory: HMAccessory) -> HMCharacteristic? {
        for service in accessory.services {
            if let ch = service.characteristics.first(where: { $0.characteristicType == type }) {
                return ch
            }
        }
        return nil
    }

    private func boolCharacteristic(type: String, in accessory: HMAccessory) -> Bool? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Bool { return v }
        return nil
    }

    private func intCharacteristic(type: String, in accessory: HMAccessory) -> Int? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Int { return v }
        if let v = homeKit.value(for: ch) as? NSNumber { return v.intValue }
        return nil
    }
}

#Preview {
    let service = HomeKitService()
    let store = IconOverrideStore()
    return NavigationStack {
        AllAccessoriesView()
            .environment(service)
            .environment(store)
    }
}

extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
#if !canImport(RoomPlan)
private struct RoomPlanCaptureFallbackView: View {
    var body: some View {
        ContentUnavailableView("RoomPlan non disponibile", systemImage: "exclamationmark.triangle", description: Text("Questa funzione richiede un dispositivo con LiDAR."))
            .navigationTitle("Scansione stanza")
    }
}
#endif

