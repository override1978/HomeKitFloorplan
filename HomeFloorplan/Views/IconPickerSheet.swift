import SwiftUI
import HomeKit

/// Sheet di selezione icona per un accessorio. Mostra due tab:
/// - Sistema: SF Symbols organizzati per categoria
/// - Custom: asset Lucide organizzati per categoria
/// Permette anche di ripristinare l'icona di default dell'adapter.
struct IconPickerSheet: View {
    let accessory: HMAccessory
    let defaultIconName: String
    var onIconChanged: (() -> Void)? = nil
    
    @Environment(IconOverrideStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PickerTab = .system
    @State private var showingIconPicker: Bool = false
    
    enum PickerTab: String, CaseIterable, Identifiable {
        case system = "Sistema"
        case custom = "Custom"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return String(localized: "iconPicker.system", defaultValue: "System")
            case .custom: return String(localized: "iconPicker.custom", defaultValue: "Custom")
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(PickerTab.allCases) { tab in
                        Text(tab.label).tag(tab)
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
            .navigationTitle(String(localized: "iconPicker.accessory.title", defaultValue: "\(accessory.name) Icon"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.reset", defaultValue: "Reset")) {
                        store.removeIcon(for: accessory.uniqueIdentifier)
                        onIconChanged?()
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
            onIconChanged?()
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
