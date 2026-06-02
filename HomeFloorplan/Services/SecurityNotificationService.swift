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
/// - Chiede il permesso notifiche al primo avvio
@MainActor
@Observable
final class SecurityNotificationService {

    // MARK: - Init

    private let homeKit: HomeKitService

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }

    // MARK: - Public API

    /// Avvia il monitoraggio. Chiamare da HomeFloorplanApp.init o .task.
    func start(monitoredUUIDsRaw: String) {
        requestPermissionIfNeeded()
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
        guard !monitoredUUIDs.isEmpty else { return }

        for acc in home.accessories {
            guard monitoredUUIDs.contains(acc.uniqueIdentifier) else { continue }
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)

            let urgency = adapter.visualUrgency
            let accID = acc.uniqueIdentifier

            // Considera solo alarm e warning degni di notifica
            guard urgency == .alarm || urgency == .warning else {
                // Se l'urgency torna a normale, rimuovi il cooldown
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
        // NOTIFICHE DISABILITATE — riabilitare rimuovendo questo return
        return

        let content = UNMutableNotificationContent()
        content.sound = urgency == .alarm ? .defaultCritical : .default

        let roomName = accessory.room?.name
        let accName = accessory.name
        let location = roomName.map { "\($0) · " } ?? ""

        switch urgency {
        case .alarm:
            content.title = "⚠️ Allarme: \(accName)"
            content.body = "\(location)\(adapter.primaryStatusText ?? "Allarme rilevato")"
            content.interruptionLevel = .critical
        case .warning:
            content.title = "Attenzione: \(accName)"
            content.body = "\(location)\(adapter.primaryStatusText ?? "Evento rilevato")"
            content.interruptionLevel = .active
        default:
            return
        }

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

    // MARK: - Permission

    private func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                dprint("🔔 Permesso notifiche: \(granted), errore: \(String(describing: error))")
            }
        }
    }

    // MARK: - Helpers

    private func parseUUIDs(_ raw: String) -> Set<UUID> {
        Set(raw.split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) })
    }
}
