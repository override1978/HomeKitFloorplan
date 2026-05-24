import SwiftUI
import HomeKit

/// Sheet di selezione icona per un accessorio. Mostra due tab:
/// - Sistema: SF Symbols organizzati per categoria
/// - Custom: asset Lucide organizzati per categoria
/// Permette anche di ripristinare l'icona di default dell'adapter.
struct IconPickerSheet: View {
    let accessory: HMAccessory
    let defaultIconName: String
    
    @Environment(IconOverrideStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PickerTab = .system
    @State private var showingIconPicker: Bool = false
    
    enum PickerTab: String, CaseIterable, Identifiable {
        case system = "Sistema"
        case custom = "Custom"
        var id: String { rawValue }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(PickerTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(activeCategories) { category in
                            categorySection(category)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Icona di \(accessory.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ripristina") {
                        store.removeIcon(for: accessory.uniqueIdentifier)
                        dismiss()
                    }
                    .disabled(store.icon(for: accessory.uniqueIdentifier) == nil)
                }
            }
        }
    }
    
    private var activeCategories: [AccessoryIconCatalog.IconCategory] {
        switch selectedTab {
        case .system: return AccessoryIconCatalog.systemCategories
        case .custom: return AccessoryIconCatalog.customCategories
        }
    }
    
    @ViewBuilder
    private func categorySection(_ category: AccessoryIconCatalog.IconCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6),
                spacing: 12
            ) {
                ForEach(category.icons, id: \.self) { iconName in
                    iconCell(iconName)
                }
            }
        }
    }
    
    @ViewBuilder
    private func iconCell(_ iconName: String) -> some View {
        let isSelected = store.icon(for: accessory.uniqueIdentifier) == iconName
        let isDefault = iconName == defaultIconName && store.icon(for: accessory.uniqueIdentifier) == nil
        let highlighted = isSelected || isDefault
        
        Button {
            store.setIcon(iconName, for: accessory.uniqueIdentifier)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                AccessoryIconView(iconName: iconName)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.primary)
                    .padding(8)
                    .background(highlighted ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(highlighted ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
    }
}
