import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("AutomationSkipStore — «stavolta no» e il ritorno")
struct AutomationSkipStoreTests {

    private func makeStore() -> AutomationSkipStore {
        UserDefaults.standard.removeObject(forKey: "automations.skippedUntil")
        return AutomationSkipStore()
    }

    @Test("Un'automazione non saltata non risulta saltata")
    func untouchedIsNotSkipped() {
        #expect(makeStore().isSkipped("qualunque") == false)
    }

    @Test("Il salto vale fino a poco dopo l'orario di scatto")
    func skipCoversTheFiring() {
        let store = makeStore()
        let fire = Date().addingTimeInterval(3600)
        store.recordSkip("trigger", firingAt: fire)

        #expect(store.isSkipped("trigger", now: fire.addingTimeInterval(-60)))
        #expect(store.isSkipped("trigger", now: fire),
                "all'istante esatto deve essere ancora saltata")
        #expect(store.isSkipped("trigger", now: fire.addingTimeInterval(60)),
                "il margine copre la tolleranza con cui HomeKit valuta i trigger")
    }

    @Test("Passato il margine il salto è scaduto e va disfatto")
    func skipExpiresAfterGrace() {
        let store = makeStore()
        let fire = Date()
        store.recordSkip("trigger", firingAt: fire)
        let after = fire.addingTimeInterval(AutomationSkipStore.restoreGrace + 1)

        #expect(store.isSkipped("trigger", now: after) == false)
        #expect(store.expiredTriggerIDs(now: after) == ["trigger"])
        #expect(store.expiredTriggerIDs(now: fire).isEmpty,
                "prima della scadenza non c'è niente da riaccendere")
    }

    @Test("Solo dopo la riaccensione il salto si cancella")
    func clearingRemovesTheSkip() {
        let store = makeStore()
        store.recordSkip("trigger", firingAt: Date())
        #expect(store.skipExpiry("trigger") != nil)

        store.clearSkip("trigger")
        #expect(store.skipExpiry("trigger") == nil)
        #expect(store.isSkipped("trigger") == false)
    }

    @Test("La scadenza sopravvive a una nuova istanza")
    func skipSurvivesRelaunch() {
        let store = makeStore()
        let fire = Date().addingTimeInterval(1800)
        store.recordSkip("trigger", firingAt: fire)

        // Come dopo una chiusura dell'app: stesso archivio, oggetto nuovo.
        let reborn = AutomationSkipStore()
        #expect(reborn.isSkipped("trigger"),
                "tenerla in memoria lascerebbe l'automazione spenta per sempre dopo un riavvio")
        reborn.clearSkip("trigger")
    }

    @Test("Salti su automazioni diverse non si disturbano")
    func skipsAreIndependent() {
        let store = makeStore()
        store.recordSkip("a", firingAt: Date().addingTimeInterval(600))
        store.recordSkip("b", firingAt: Date().addingTimeInterval(1200))

        store.clearSkip("a")
        #expect(store.isSkipped("a") == false)
        #expect(store.isSkipped("b"))
        store.clearSkip("b")
    }
}
