import SwiftUI

struct SettingsView: View {
    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue
    
    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }
    
    var body: some View {
        Form {
            Section {
                // Preview live
                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)
                
                // Picker dimensione
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
            
            // Sezioni future, già strutturate ma vuote
            Section {
                Text("Casa HomeKit attiva")
                    .foregroundStyle(.secondary)
                Text("Da configurare")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("HomeKit")
            }
            
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
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
