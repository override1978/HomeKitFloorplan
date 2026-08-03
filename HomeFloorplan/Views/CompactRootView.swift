import SwiftUI

// MARK: - CompactRootView

/// Radice della navigazione a **larghezza compatta** (iPhone).
///
/// Su iPad resta `NavigationSplitView`: la sidebar sta accanto al contenuto e il
/// contenuto è la planimetria, quindi l'app mostra subito ciò che è. Collassata
/// su iPhone, invece, la sidebar diventa la *prima* schermata — e un elenco di
/// destinazioni letto come schermata d'ingresso sembra un menu impostazioni.
/// L'app smetteva di somigliare a sé stessa.
///
/// Qui la radice è una tab bar, così si atterra sulle planimetrie e le sezioni
/// restano raggiungibili senza passare da un indice.
///
/// ⚠️ **È un MVP, e questa duplicazione è un debito dichiarato.** La destinazione
/// giusta è `TabViewStyle.sidebarAdaptable`, che con UNA sola struttura dà
/// sidebar su iPad e tab bar su iPhone. Non è stata adottata subito perché
/// richiede di riscrivere `SidebarView` — intestazione col brand, gruppi
/// apribili, elenco planimetrie, footer con la casa attiva — e il rischio di
/// regressione sarebbe caduto sull'iPad, che oggi funziona. Da riprendere quando
/// la forma dell'iPhone sarà decisa.
struct CompactRootView: View {

    @Environment(AISettings.self) private var aiSettings

    @State private var tab: CompactTab = .floorplans
    /// Il pannello della chat è escluso su compatto: è un riquadro flottante in
    /// alto a destra tarato su iPad, e a 390 punti coprirebbe tutto. Su iPhone
    /// l'assistente andrà presentato come sheet — lavoro a sé.
    private let showsAssistant = false

    enum CompactTab: Hashable {
        case floorplans, analysis, accessories, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "sidebar.section.floorplans", defaultValue: "Floorplans"),
                systemImage: "square.on.square",
                value: CompactTab.floorplans) {
                // `FloorplanListView` porta già la propria navigazione e apre
                // l'editor in presentazione `.pushed`, che è la forma giusta su
                // iPhone: si entra e si torna indietro.
                FloorplanListView(columnVisibility: .constant(.detailOnly))
            }

            Tab(String(localized: "sidebar.section.analysis", defaultValue: "Analysis"),
                systemImage: "chart.bar.xaxis",
                value: CompactTab.analysis) {
                NavigationStack {
                    List {
                        NavigationLink(String(localized: "overlay.environment", defaultValue: "Environment")) {
                            EnvironmentDashboardView()
                        }
                        NavigationLink(String(localized: "overlay.security", defaultValue: "Security")) {
                            SecurityView()
                        }
                        NavigationLink(String(localized: "overlay.intelligence", defaultValue: "Intelligence")) {
                            HomeIntelligenceDashboardView()
                        }
                    }
                    .navigationTitle(String(localized: "sidebar.section.analysis", defaultValue: "Analysis"))
                }
            }

            Tab(String(localized: "sidebar.section.scenesAndAutomations", defaultValue: "Scenes & Automations"),
                systemImage: "square.grid.2x2",
                value: CompactTab.accessories) {
                NavigationStack {
                    List {
                        NavigationLink(String(localized: "sidebar.accessories", defaultValue: "Accessories")) {
                            AccessoriesTabView()
                        }
                        NavigationLink(String(localized: "scenes.title", defaultValue: "Scenes")) {
                            ScenesView()
                        }
                        NavigationLink(String(localized: "sidebar.automations", defaultValue: "Automations")) {
                            AutomationsView()
                        }
                    }
                    .navigationTitle(String(localized: "sidebar.section.scenesAndAutomations", defaultValue: "Scenes & Automations"))
                }
            }

            Tab(String(localized: "sidebar.settings", defaultValue: "Settings"),
                systemImage: "gearshape",
                value: CompactTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        // La tab bar si ritira scorrendo, come nelle app di sistema di iOS 26:
        // su uno schermo stretto ogni punto restituito al contenuto conta.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
