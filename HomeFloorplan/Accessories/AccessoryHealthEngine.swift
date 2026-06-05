import HomeKit

// MARK: - AccessoryHealthEngine

/// Motore di scoring deterministico per la salute degli accessori di una stanza.
///
/// Non richiede AI. Il punteggio è calcolato unicamente da:
/// - Dispositivi offline (isReachable = false nella reachabilityMap)
/// - Dispositivi con batteria scarica (BatteryInfo.isLow)
/// - Dispositivi con errore di scrittura recente (isLikelyOffline)
///
/// Penalità calibrate in modo analogo a SecurityScoreService:
/// - Offline o irraggiungibile: -15 per dispositivo
/// - Batteria scarica: -8 per dispositivo
/// - Errore scrittura recente (likely offline): -10 per dispositivo
///
/// Il punteggio finale è clamped a [0, 100].
@MainActor
enum AccessoryHealthEngine {

    // MARK: - Penalties

    private static let penaltyOffline      = 15
    private static let penaltyLowBattery   = 8
    private static let penaltyLikelyOffline = 10

    // MARK: - Score computation

    /// Calcola il punteggio di salute (0–100) per un insieme di accessori.
    ///
    /// - Parameters:
    ///   - accessories: Gli HMAccessory della stanza.
    ///   - homeKit: Servizio HomeKit per leggere reachabilityMap e isLikelyOffline.
    /// - Returns: Intero 0–100.
    static func score(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> Int {
        guard !accessories.isEmpty else { return 100 }

        var penalty = 0

        for accessory in accessories {
            // Usa homeKit.isReachable() — rispetta il grace period iniziale
            // e la reachabilityMap, non accessory.isReachable direttamente.
            let isReachable = homeKit.isReachable(accessory)

            // Offline (irraggiungibile)
            if !isReachable {
                penalty += penaltyOffline
                continue  // se già offline, non accumuliamo anche likely offline
            }

            // Errore di scrittura recente
            if homeKit.isLikelyOffline(accessory) {
                penalty += penaltyLikelyOffline
            }

            // Batteria scarica
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            if adapter.batteryInfo?.isLow == true {
                penalty += penaltyLowBattery
            }
        }

        return max(0, 100 - penalty)
    }

    // MARK: - Category badges

    /// Costruisce i micro-badge di categoria per una stanza.
    /// Solo le categorie con almeno un accessorio sono incluse.
    static func categoryBadges(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> [AccessoryRoomCategoryBadge] {
        // Categorie da mostrare nella card, in ordine di priorità visiva
        let orderedCategories: [AccessoryCategory] = [
            .lights, .climate, .sensors, .security, .air, .outlets, .windowCoverings, .hubs, .others
        ]

        var counts: [AccessoryCategory: Int] = [:]
        for accessory in accessories {
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            let cat = AccessoryCategory.classify(adapter: adapter)
            counts[cat, default: 0] += 1
        }

        return orderedCategories.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return AccessoryRoomCategoryBadge(
                id: category,
                count: count,
                symbol: category.symbolName
            )
        }
    }

    // MARK: - Issue counts

    /// Numero di dispositivi offline (non raggiungibili).
    static func offlineCount(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> Int {
        accessories.filter { !homeKit.isReachable($0) }.count
    }

    /// Numero di dispositivi con batteria scarica.
    static func lowBatteryCount(
        for accessories: [HMAccessory],
        homeKit: HomeKitService
    ) -> Int {
        accessories.filter { accessory in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            return adapter.batteryInfo?.isLow == true
        }.count
    }
}
