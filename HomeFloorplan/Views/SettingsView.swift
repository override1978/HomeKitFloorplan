import SwiftUI
import HomeKit

struct SettingsView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(OnboardingService.self) private var onboarding
    
    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue
    
    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }
    
    var body: some View {
        Form {
            // MARK: - HomeKit
            
            Section {
                homeKitSection
            } header: {
                Text("HomeKit")
            } footer: {
                if homeKit.availableHomes.count > 1 {
                    Text("Puoi avere più case configurate in Apple Home. Scegli quale gestire con HomeFloorplan.")
                } else {
                    Text("La casa attiva determina quali accessori e planimetrie sono visibili.")
                }
            }
            
            // MARK: - Marker
            
            Section {
                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)
                
                Picker("Dimensione", selection: $markerSizeRaw) {
                    ForEach(MarkerSize.allCases) { size in
                        Text(size.localized).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Dimensione marker")
            } footer: {
                Text("La dimensione dei marker si applica a tutte le planimetrie.")
            }
            
            Section {
                Button {
                    onboarding.resetForDebug()
                } label: {
                    Label("Mostra onboarding al prossimo lancio", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("Sviluppatore")
            } footer: {
                Text("Ripristina la prima esperienza. Killa e riapri l'app per vedere l'onboarding.")
            }
            
            // MARK: - Info
            
            Section {
                HStack {
                    Text("Versione")
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Info")
            }
        }
        .navigationTitle("Impostazioni")
        .navigationBarTitleDisplayMode(.large)
    }
    
    // MARK: - HomeKit section
    
    @ViewBuilder
    private var homeKitSection: some View {
        let homes = homeKit.availableHomes
        
        if homes.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nessuna casa configurata")
                        .font(.body)
                    Text("Configura una casa dall'app Casa di Apple per iniziare.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if homes.count == 1, let only = homes.first {
            HStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Casa attiva")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(only.name)
                        .font(.body)
                }
            }
        } else {
            Picker(selection: Binding(
                get: { homeKit.currentHome?.uniqueIdentifier },
                set: { newUUID in
                    if let uuid = newUUID,
                       let home = homes.first(where: { $0.uniqueIdentifier == uuid }) {
                        homeKit.setActiveHome(home)
                    } else {
                        homeKit.resetToPrimaryHome()
                    }
                }
            )) {
                ForEach(homes, id: \.uniqueIdentifier) { home in
                    HStack {
                        Text(home.name)
                        if home == homeKit.availableHomes.first(where: { _ in
                            // Indicatore visivo della primaria HomeKit
                            return false
                        }) {
                            Spacer()
                            Text("Primaria")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(home.uniqueIdentifier as UUID?)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.tint)
                    Text("Casa attiva")
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
