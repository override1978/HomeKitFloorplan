import SwiftUI

// MARK: - LanguageAndUnitsSettingsView

/// Lingua dell'app e unità di misura.
///
/// Tenuta separata da "Aspetto" di proposito: la lingua non è una preferenza
/// estetica. La temperatura arriva qui dalla vecchia sezione "Environment",
/// dove stava lontana dalle altre unità pur essendo la stessa scelta.
struct LanguageAndUnitsSettingsView: View {

    @Environment(CloudKitSyncService.self) private var cloudKitSync

    @AppStorage(AppLanguage.appStorageKey)
    private var appLanguageRaw: String = AppLanguage.system.rawValue

    @AppStorage(DimensionUnit.appStorageKey)
    private var dimensionUnitRaw: String = DimensionUnit.metric.rawValue

    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    @State private var showLanguageRestartAlert = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $appLanguageRaw) {
                    ForEach(AppLanguage.selectableLanguages) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                } label: {
                    Label(String(localized: "settings.language.picker", defaultValue: "App Language"),
                          systemImage: "globe")
                }
                .pickerStyle(.menu)
            } footer: {
                Text(String(localized: "settings.language.restartHint", defaultValue: "Language changes are applied after closing and reopening the app on iPad."))
            }

            Section {
                Picker(selection: $dimensionUnitRaw) {
                    Text(String(localized: "settings.drawing.dimensionUnit.metric",   defaultValue: "m – Metric")).tag(DimensionUnit.metric.rawValue)
                    Text(String(localized: "settings.drawing.dimensionUnit.imperial", defaultValue: "ft – Imperial")).tag(DimensionUnit.imperial.rawValue)
                } label: {
                    Label(String(localized: "settings.drawing.dimensionUnit", defaultValue: "Measurements"),
                          systemImage: "ruler")
                }
                .pickerStyle(.menu)

                Picker(selection: $temperatureUnitRaw) {
                    Text("°C – Celsius").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F – Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                } label: {
                    Label(String(localized: "settings.environment.temperature", defaultValue: "Temperature"),
                          systemImage: "thermometer.medium")
                }
                .pickerStyle(.menu)
            } header: {
                Text(String(localized: "settings.languageUnits.units.header", defaultValue: "Units"))
            }
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.languageUnits.title", defaultValue: "Language & Units"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appLanguageRaw) { _, newValue in
            AppLanguage.apply(rawValue: newValue)
            showLanguageRestartAlert = true
        }
        .onChange(of: temperatureUnitRaw) { _, _ in
            cloudKitSync.markSettingsNeedsSync()
        }
        .alert(String(localized: "settings.language.restartAlert.title", defaultValue: "Restart required"),
               isPresented: $showLanguageRestartAlert) {
            Button(String(localized: "button.ok", defaultValue: "OK")) {}
        } message: {
            Text(String(localized: "settings.language.restartAlert.message", defaultValue: "Close and reopen Home Floorplan on this iPad to apply the selected language everywhere."))
        }
    }
}
