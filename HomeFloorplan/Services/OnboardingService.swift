import Foundation
import Observation

/// Gestisce lo stato dell'onboarding: se l'utente l'ha già visto e quale versione.
/// Memorizzato in UserDefaults così sopravvive a riavvii.
@MainActor
@Observable
final class OnboardingService {
    
    private static let lastSeenVersionKey = "onboardingLastSeenVersion"
    
    /// Versione corrente dell'onboarding. Incrementala quando vuoi forzare
    /// la ri-visualizzazione (es. dopo aggiornamenti major o cambi rilevanti).
    static let currentVersion: Int = 2
    
    /// True se l'utente deve vedere l'onboarding adesso.
    /// Calcolato comparando la versione vista con quella corrente.
    var shouldShowOnboarding: Bool {
        lastSeenVersion < Self.currentVersion
    }
    
    /// L'ultima versione di onboarding vista dall'utente.
    /// 0 = mai visto (primo lancio assoluto).
    private(set) var lastSeenVersion: Int
    
    init() {
        self.lastSeenVersion = UserDefaults.standard.integer(forKey: Self.lastSeenVersionKey)
    }
    
    /// Marca l'onboarding come completato salvando la versione corrente.
    func markCompleted() {
        lastSeenVersion = Self.currentVersion
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.lastSeenVersionKey)
    }
    
    /// Per debug/testing: ripristina lo stato a "mai visto"
    /// così l'onboarding ricompare al prossimo lancio.
    func resetForDebug() {
        lastSeenVersion = 0
        UserDefaults.standard.removeObject(forKey: Self.lastSeenVersionKey)
        UserDefaults.standard.removeObject(forKey: "onboardingCurrentStep")
    }
}
