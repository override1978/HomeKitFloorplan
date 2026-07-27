import SwiftUI

// MARK: - AppearanceSettingsView

/// Come si presenta la planimetria: marker, effetto vetro, salvaschermo.
///
/// Nasce staccando questi controlli da due sezioni dove non c'entravano: la
/// dimensione dei marker e la visibilità delle etichette stavano sotto "Home &
/// Floorplan", il vetro e il salvaschermo sotto "App". Chi cerca come
/// rimpicciolire i marker non guarda in nessuna delle due.
struct AppearanceSettingsView: View {

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    @AppStorage(MarkerLabelVisibility.appStorageKey)
    private var markerLabelVisibilityRaw: String = MarkerLabelVisibility.smart.rawValue

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled: Bool = false

    /// Timeout salvo in secondi. Default 90s (= 1m 30s).
    @AppStorage("idleTimeout")
    private var idleTimeoutSeconds: Double = 90

    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }

    var body: some View {
        Form {
            Section {
                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)

                Picker(String(localized: "settings.marker.size.picker", defaultValue: "Size"),
                       selection: $markerSizeRaw) {
                    ForEach(MarkerSize.allCases) { size in
                        Text(size.localizationKey).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker(String(localized: "settings.marker.labels.picker", defaultValue: "Labels"),
                       selection: $markerLabelVisibilityRaw) {
                    ForEach(MarkerLabelVisibility.allCases) { visibility in
                        Text(visibility.localizationKey).tag(visibility.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(String(localized: "settings.appearance.markers.header", defaultValue: "Markers"))
            }

            Section {
                Toggle(isOn: $isLiquidGlassEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "settings.appearance.liquidGlass", defaultValue: "Liquid Glass"))
                            Text(String(localized: "settings.appearance.liquidGlass.subtitle", defaultValue: "Use the new glass effect on floorplan controls where supported."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack")
                    }
                }
            } header: {
                Text(String(localized: "settings.appearance.effects.header", defaultValue: "Effects"))
            }

            Section {
                Picker(String(localized: "settings.screensaver.picker", defaultValue: "Activate after"),
                       selection: $idleTimeoutSeconds) {
                    Text(String(localized: "settings.screensaver.30s",   defaultValue: "30 seconds")).tag(30.0)
                    Text(String(localized: "settings.screensaver.1m",    defaultValue: "1 minute")).tag(60.0)
                    Text(String(localized: "settings.screensaver.1m30s", defaultValue: "1 min 30 sec")).tag(90.0)
                    Text(String(localized: "settings.screensaver.2m",    defaultValue: "2 minutes")).tag(120.0)
                    Text(String(localized: "settings.screensaver.5m",    defaultValue: "5 minutes")).tag(300.0)
                    Text(String(localized: "settings.screensaver.10m",   defaultValue: "10 minutes")).tag(600.0)
                    Text(String(localized: "settings.screensaver.never", defaultValue: "Never")).tag(0.0)
                }
                .pickerStyle(.menu)
            } header: {
                Text(String(localized: "settings.appearance.screensaver.header", defaultValue: "Screen Saver"))
            }
            .onChange(of: idleTimeoutSeconds) { _, newValue in
                IdleTimerService.shared.timeout = newValue == 0 ? .infinity : newValue
                IdleTimerService.shared.resetTimer()
            }
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.appearance.title", defaultValue: "Appearance"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
