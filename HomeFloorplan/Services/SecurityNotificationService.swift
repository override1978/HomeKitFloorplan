import Foundation
import UserNotifications
import HomeKit
import Observation

/// Servizio che monitora i sensori di sicurezza selezionati dall'utente
/// e invia notifiche locali iOS quando uno di essi entra in stato di allarme
/// o attenzione, anche con l'app in background.
///
/// Funzionamento:
/// - Osserva `HomeKitService.characteristicValues` tramite un loop `withObservationTracking`
/// - Tiene traccia dell'ultima urgency notificata per UUID per evitare notifiche duplicate
/// - Cooldown di 60s per stesso UUID: non rinotifica se già in allarme
/// - Non chiede permessi al primo avvio: la richiesta parte dai Settings quando l'utente abilita le notifiche
/// - Rispetta la preferenza `securityNotificationsEnabled` (AppStorage)
@MainActor
@Observable
final class SecurityNotificationService {

    // MARK: - AppStorage keys

    static let enabledKey = "securityNotificationsEnabled"

    // MARK: - Init

    private let homeKit: HomeKitService

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }

    // MARK: - Public API

    /// Avvia il monitoraggio. Chiamare da HomeFloorplanApp.init o .task.
    func start(monitoredUUIDsRaw: String) {
        observedUUIDsRaw = monitoredUUIDsRaw
        startObservationLoop()
    }

    /// Aggiorna la lista degli UUID monitorati quando l'utente modifica la selezione.
    func updateMonitored(uuidsRaw: String) {
        observedUUIDsRaw = uuidsRaw
    }

    // MARK: - Private state

    /// Set corrente di UUID monitorati (come stringa CSV, stessa key di AppStorage)
    private var observedUUIDsRaw: String = ""

    /// Ultima urgency notificata per UUID, con timestamp. Usato per cooldown.
    private var lastNotifiedUrgency: [UUID: (urgency: MarkerUrgency, date: Date)] = [:]

    /// Cooldown: non ri-notifica lo stesso UUID per questo intervallo se l'urgency non è cambiata
    private let cooldownSeconds: TimeInterval = 60

    private var isObserving = false

    // MARK: - Observation loop

    private func startObservationLoop() {
        guard !isObserving else { return }
        isObserving = true
        Task { @MainActor in
            await observationLoop()
        }
    }

    private func observationLoop() async {
        // Loop: ogni volta che characteristicValues cambia, ri-eseguiamo il check
        while !Task.isCancelled {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    // Legge characteristicValues per registrare la dipendenza
                    _ = homeKit.characteristicValues
                } onChange: {
                    continuation.resume()
                }
            }
            // characteristicValues è cambiato: controlla i sensori monitorati
            checkMonitoredSensors()
        }
    }

    // MARK: - Check logic

    private func checkMonitoredSensors() {
        guard let home = homeKit.currentHome else { return }
        let monitoredUUIDs = parseUUIDs(observedUUIDsRaw)

        // Costruisce l'insieme di accessori da controllare:
        // 1. Tutti i sensori configurati dall'utente (se presenti)
        // 2. SEMPRE il sistema di allarme (SecuritySystemAdapter), anche se non
        //    esplicitamente in monitoredUUIDs — l'allarme non deve mai essere mancato.
        var accessoriesToCheck: [HMAccessory] = []
        for acc in home.accessories {
            let isMonitored = monitoredUUIDs.contains(acc.uniqueIdentifier)
            let isSecuritySystem = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) is SecuritySystemAdapter
            if isMonitored || isSecuritySystem {
                accessoriesToCheck.append(acc)
            }
        }

        guard !accessoriesToCheck.isEmpty else { return }

        for acc in accessoriesToCheck {
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)

            let urgency = adapter.visualUrgency
            let accID = acc.uniqueIdentifier

            // Invia notifica push solo per eventi critici (.alarm):
            // fumo, CO, perdita acqua, antifurto scattato.
            // I .warning (porta aperta, movimento, occupazione) aggiornano l'UI
            // ma NON generano notifiche push — sono troppo frequenti e non urgenti.
            guard urgency == .alarm else {
                lastNotifiedUrgency.removeValue(forKey: accID)
                continue
            }

            // Controlla cooldown: stessa urgency notificata di recente?
            if let last = lastNotifiedUrgency[accID],
               last.urgency == urgency,
               Date().timeIntervalSince(last.date) < cooldownSeconds {
                continue
            }

            // Invia notifica
            sendNotification(for: acc, adapter: adapter, urgency: urgency)
            lastNotifiedUrgency[accID] = (urgency, Date())
        }
    }

    // MARK: - Notification

    private func sendNotification(for accessory: HMAccessory, adapter: any AccessoryAdapter, urgency: MarkerUrgency) {
        guard urgency == .alarm else { return }
        // Rispetta la preferenza utente. Default: disabilitato finché l'utente non abilita dai Settings.
        let enabled = UserDefaults.standard.object(forKey: SecurityNotificationService.enabledKey) as? Bool ?? false
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.sound = .defaultCritical

        let roomName = accessory.room?.name
        let accName = accessory.name
        let location = roomName.map { "\($0) · " } ?? ""

        content.title = "⚠️ Allarme: \(accName)"
        content.body = "\(location)\(adapter.primaryStatusText ?? "Allarme rilevato")"
        content.interruptionLevel = .critical

        let request = UNNotificationRequest(
            identifier: "security-\(accessory.uniqueIdentifier.uuidString)",
            content: content,
            trigger: nil  // consegna immediata
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                dprint("🔔 Notifica sicurezza fallita per \(accName): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func parseUUIDs(_ raw: String) -> Set<UUID> {
        Set(raw.split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) })
    }
}
