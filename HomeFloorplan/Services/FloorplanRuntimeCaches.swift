import Foundation
import Observation

// MARK: - FloorplanRuntimeCaches

/// Le tre cose costose che l'editor non deve ricalcolare a ogni render.
///
/// La mappa degli adapter, l'adapter di sicurezza e la salute casa hanno in
/// comune la sola cosa che conta per stare insieme: si ricalcolano tutte e tre
/// **sugli stessi eventi discreti** — apertura, HomeKit pronto, elenco
/// accessori cambiato, raggiungibilità — e mai per fotogramma. Tre `@State`
/// sparsi in duecento righe di vista non lo dicevano; un oggetto con un solo
/// `refresh` lo dice da sé.
///
/// A differenza delle fabbriche dei collaboratori — che ho provato a spostare
/// e ho rimesso a posto — questo gruppo ha un'interfaccia stretta: tre letture
/// e un'invalidazione. È la differenza fra spaccare un file e dividere una
/// responsabilità: la prima allarga la visibilità di tutto ciò che si muove,
/// la seconda la restringe.
@Observable
@MainActor
final class FloorplanRuntimeCaches {

    private(set) var securityAdapter: SecuritySystemAdapter?
    private(set) var healthScore: Int?
    private(set) var adapterMap: [UUID: any AccessoryAdapter] = [:]

    /// Ricalcola tutto. Solo su eventi discreti, mai per-frame.
    func refresh(homeKit: HomeKitService, security: () -> SecuritySystemAdapter?) {
        securityAdapter = security()
        adapterMap = AccessoryAdapterFactory.adapterMap(homeKit: homeKit)
        healthScore = FloorplanStatusStripBuilder.weightedHealthScore(homeKit: homeKit)
    }

    /// La mappa degli adapter, costruita al volo se la cache è ancora vuota.
    ///
    /// Il ripiego non è pigrizia: c'è una finestra fra il primo render e il
    /// primo `refresh` in cui la cache è vuota, e in quella finestra una mappa
    /// vuota non significa «nessun accessorio» — significa «non lo so ancora».
    /// Restituirla farebbe sparire i marker per un fotogramma.
    func adapters(homeKit: HomeKitService) -> [UUID: any AccessoryAdapter] {
        adapterMap.isEmpty ? AccessoryAdapterFactory.adapterMap(homeKit: homeKit) : adapterMap
    }
}
