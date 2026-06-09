import SwiftUI
import HomeKit
import SwiftData

struct SettingsView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(OnboardingService.self) private var onboarding
    @Environment(\.modelContext) private var modelContext

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }

    /// Timeout salvo in secondi. Default 90s (= 1m 30s).
    @AppStorage("idleTimeout")
    private var idleTimeoutSeconds: Double = 90

    /// Nome esatto della stanza HomeKit che rappresenta il sensore outdoor.
    /// Usato dal banner esterno nella Dashboard Ambientale e (futuro) nel Floorplan.
    @AppStorage("outdoorRoomName")
    private var outdoorRoomName: String = ""

    /// Unità di misura temperatura (celsius / fahrenheit).
    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    /// Stanze distinte presenti in SwiftData, caricate all'apertura della view.
    @State private var availableRooms: [String] = []
    
    var body: some View {
        Form {
            // MARK: - HomeKit
            
            Section {
                homeKitSection
            } header: {
                Text("HomeKit")
            } footer: {
                if homeKit.availableHomes.count > 1 {
                    Text(String(localized: "settings.homekit.footer.multi", defaultValue: "Puoi avere più case configurate in Apple Home. Scegli quale gestire con HomeFloorplan."))
                } else {
                    Text(String(localized: "settings.homekit.footer.single", defaultValue: "La casa attiva determina quali accessori e planimetrie sono visibili."))
                }
            }
            
            // MARK: - Marker
            
            Section {
                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)
                
                Picker(String(localized: "settings.marker.size.picker", defaultValue: "Dimensione"), selection: $markerSizeRaw) {
                    ForEach(MarkerSize.allCases) { size in
                        Text(size.localized).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(String(localized: "settings.marker.size.header", defaultValue: "Dimensione marker"))
            } footer: {
                Text(String(localized: "settings.marker.size.footer", defaultValue: "La dimensione dei marker si applica a tutte le planimetrie."))
            }
            
            // MARK: - Screensaver

            Section {
                Picker(String(localized: "settings.screensaver.picker", defaultValue: "Attiva dopo"), selection: $idleTimeoutSeconds) {
                    Text(String(localized: "settings.screensaver.30s",    defaultValue: "30 secondi")).tag(30.0)
                    Text(String(localized: "settings.screensaver.1m",     defaultValue: "1 minuto")).tag(60.0)
                    Text(String(localized: "settings.screensaver.1m30s",  defaultValue: "1 min 30 sec")).tag(90.0)
                    Text(String(localized: "settings.screensaver.2m",     defaultValue: "2 minuti")).tag(120.0)
                    Text(String(localized: "settings.screensaver.5m",     defaultValue: "5 minuti")).tag(300.0)
                    Text(String(localized: "settings.screensaver.10m",    defaultValue: "10 minuti")).tag(600.0)
                    Text(String(localized: "settings.screensaver.never",  defaultValue: "Mai")).tag(0.0)
                }
                .pickerStyle(.menu)
            } header: {
                Text(String(localized: "settings.screensaver.header", defaultValue: "Screensaver"))
            } footer: {
                Text(String(localized: "settings.screensaver.footer", defaultValue: "Lo screensaver si attiva dopo il periodo di inattività scelto. Seleziona \"Mai\" per disabilitarlo."))
            }
            .onChange(of: idleTimeoutSeconds) { _, newValue in
                if newValue == 0 {
                    // Disabilitato: imposta un timeout molto lungo per evitare l'attivazione
                    IdleTimerService.shared.timeout = .infinity
                } else {
                    IdleTimerService.shared.timeout = newValue
                }
                IdleTimerService.shared.resetTimer()
            }

            // MARK: - Ambiente

            Section {
                // Unità temperatura
                Picker(selection: $temperatureUnitRaw) {
                    Text("°C – Celsius").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F – Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                } label: {
                    Label(String(localized: "settings.environment.temperature", defaultValue: "Temperatura"), systemImage: "thermometer.medium")
                }
                .pickerStyle(.menu)

                // Stanza outdoor
                if availableRooms.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(String(localized: "settings.environment.noReadings", defaultValue: "Nessuna lettura disponibile. Vai nella Dashboard Ambiente per campionare i sensori."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(selection: $outdoorRoomName) {
                        Text(String(localized: "settings.environment.outdoorRoom.none", defaultValue: "Nessuna")).tag("")
                        ForEach(availableRooms, id: \.self) { room in
                            Text(room).tag(room)
                        }
                    } label: {
                        Label(String(localized: "settings.environment.outdoorRoom", defaultValue: "Stanza esterna"), systemImage: "cloud.sun")
                    }
                }
            } header: {
                Text(String(localized: "settings.environment.header", defaultValue: "Ambiente"))
            } footer: {
                Text(String(localized: "settings.environment.footer", defaultValue: "Seleziona la stanza HomeKit del sensore outdoor (es. modulo Netatmo esterno). Usata dal banner meteo nella Dashboard Ambientale."))
            }

            // MARK: - Notifiche

            Section {
                NavigationLink {
                    EnvironmentNotificationsSettingsView()
                } label: {
                    Label(String(localized: "settings.notifications.environment.link",
                                 defaultValue: "Notifiche Ambiente"),
                          systemImage: "leaf")
                }

                NavigationLink {
                    SecurityNotificationsSettingsView()
                } label: {
                    Label(String(localized: "settings.notifications.security.link",
                                 defaultValue: "Notifiche Sicurezza"),
                          systemImage: "lock.shield.fill")
                }
            } header: {
                Text(String(localized: "settings.notifications.header", defaultValue: "Notifiche"))
            } footer: {
                Text(String(localized: "settings.notifications.footer",
                            defaultValue: "Configura separatamente gli alert ambientali (soglie temperatura, umidità, aria) e le notifiche di sicurezza (antifurto, fumo, CO, acqua)."))
            }

            // MARK: - Intelligenza Artificiale

            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label(String(localized: "settings.ai.link", defaultValue: "Intelligenza Artificiale"), systemImage: "brain")
                }
            } header: {
                Text(String(localized: "settings.ai.header", defaultValue: "AI"))
            } footer: {
                Text(String(localized: "settings.ai.footer", defaultValue: "Configura il provider AI e le API key per abilitare suggerimenti, anomalie e regole predittive."))
            }

            Section {
                Button {
                    onboarding.resetForDebug()
                } label: {
                    Label(String(localized: "settings.developer.showOnboarding", defaultValue: "Mostra onboarding al prossimo lancio"), systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.tint)
                }
                NavigationLink {
                    HabitsView()
                } label: {
                    Label(String(localized: "settings.developer.habits", defaultValue: "Abitudini"), systemImage: "brain.head.profile")
                }
                #if DEBUG
                NavigationLink {
                    AITraceView()
                } label: {
                    Label("AI Pipeline Trace", systemImage: "waveform.and.magnifyingglass")
                }
                #endif
            } header: {
                Text(String(localized: "settings.developer.header", defaultValue: "Sviluppatore"))
            } footer: {
                Text(String(localized: "settings.developer.footer", defaultValue: "Ripristina la prima esperienza. Chiudi e riapri l'app per vedere l'onboarding."))
            }
            
            // MARK: - Info
            
            Section {
                HStack {
                    Text(String(localized: "settings.info.version", defaultValue: "Versione"))
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.info.header", defaultValue: "Info"))
            }
        }
        .navigationTitle(String(localized: "settings.title", defaultValue: "Impostazioni"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadAvailableRooms() }
    }

    // MARK: - Carica stanze da SwiftData

    private func loadAvailableRooms() {
        let all = (try? modelContext.fetch(FetchDescriptor<SensorReading>())) ?? []
        availableRooms = Array(Set(all.map(\.roomName))).sorted()
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
                    Text(String(localized: "settings.homekit.noHome", defaultValue: "Nessuna casa configurata"))
                        .font(.body)
                    Text(String(localized: "settings.homekit.noHome.hint", defaultValue: "Configura una casa dall'app Casa di Apple per iniziare."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if homes.count == 1, let only = homes.first {
            HStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.homekit.activeHome", defaultValue: "Casa attiva"))
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
                            Text(String(localized: "settings.homekit.primary", defaultValue: "Primaria"))
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
                    Text(String(localized: "settings.homekit.activeHome", defaultValue: "Casa attiva"))
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
