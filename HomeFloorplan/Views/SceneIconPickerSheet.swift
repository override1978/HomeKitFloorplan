import SwiftUI

/// Picker icona per una scena. Identico nello spirito a IconPickerSheet ma
/// non richiede HMAccessory (le scene sono HMActionSet, modello diverso).
struct SceneIconPickerSheet: View {
    let scene: SceneItem
    
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: IconTab = .system
    
    enum IconTab: String, CaseIterable, Identifiable {
        case system = "Sistema"
        case custom = "Custom"
        var id: String { rawValue }
    }
    
    private var currentIcon: String {
        iconOverrides.effectiveIcon(for: scene)
    }
    
    private var defaultIcon: String {
        scene.symbolName
    }
    
    private var hasOverride: Bool {
        iconOverrides.icon(for: scene.id) != nil
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                
                Picker("Tipologia", selection: $selectedTab) {
                    ForEach(IconTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                              spacing: 14) {
                        ForEach(iconsForCurrentTab(), id: \.self) { icon in
                            iconButton(icon)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Icona scena")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasOverride {
                        Button("Ripristina") {
                            iconOverrides.removeIcon(for: scene.id)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: currentIcon)
                    .foregroundStyle(.tint)
                    .font(.title)
            }
            Text(scene.name)
                .font(.headline)
        }
        .padding(.top, 16)
    }
    
    private func iconButton(_ icon: String) -> some View {
        Button {
            iconOverrides.setIcon(icon, for: scene.id)
        } label: {
            ZStack {
                Circle()
                    .fill(icon == currentIcon
                          ? AnyShapeStyle(.tint)
                          : AnyShapeStyle(Color.secondary.opacity(0.12)))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .foregroundStyle(icon == currentIcon ? .white : .primary)
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }
    
    private func iconsForCurrentTab() -> [String] {
        switch selectedTab {
        case .system: return Self.systemIcons
        case .custom: return Self.customIcons
        }
    }
    
    private static let systemIcons: [String] = [
        "wand.and.sparkles", "house.fill", "moon.fill", "sunrise.fill", "sunset.fill",
        "bed.double.fill", "figure.walk.departure", "shield.fill", "exclamationmark.shield.fill",
        "tv.fill", "fork.knife", "book.fill", "leaf.fill", "music.note", "party.popper.fill",
        "laptopcomputer", "figure.mind.and.body", "shower.fill", "flame.fill", "snowflake",
        "wind", "lightbulb.fill", "lightbulb.slash", "key.fill", "lock.fill", "lock.open.fill",
        "blinds.horizontal.closed", "blinds.horizontal.open", "thermometer", "humidity.fill",
        "cup.and.saucer.fill", "fan.fill", "gamecontroller.fill", "popcorn.fill", "bath",
        "stove.fill", "washer.fill", "carrot.fill", "wineglass.fill", "balloon.fill"
    ]
    
    private static let customIcons: [String] = [
        // Per ora identici - in futuro asset catalog Lucide/Tabler
    ]
}
