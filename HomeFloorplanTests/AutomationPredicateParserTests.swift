import Foundation
import HomeKit
import Testing
@testable import HomeFloorplan

/// I dialetti dei predicati HomeKit, inchiodati sui formati VERI raccolti dal
/// log [EditDraft] della casa reale: Apple Home, Controller ed Eve scrivono
/// le stesse idee in forme diverse, e il wizard deve leggerle tutte.
///
/// Le forme con HMCharacteristic non si possono costruire nei test (serve una
/// casa vera): quelle restano al collaudo su device. Qui si coprono orari e
/// presenza, che sono i formati che hanno fallito sul campo.
@Suite("Parser dei predicati automazione — i dialetti delle altre app")
@MainActor
struct AutomationPredicateParserTests {

    private func components(hour: Int, minute: Int) -> DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    private func after(_ hour: Int, _ minute: Int) -> NSPredicate {
        HMEventTrigger.predicateForEvaluatingTrigger(
            occurringAfter: components(hour: hour, minute: minute)
        )
    }

    private func before(_ hour: Int, _ minute: Int) -> NSPredicate {
        HMEventTrigger.predicateForEvaluatingTrigger(
            occurringBefore: components(hour: hour, minute: minute)
        )
    }

    private var presenceAtHome: NSPredicate {
        HMEventTrigger.predicateForEvaluatingTrigger(
            // .atHome, non .everyEntry: i tipi da CONDIZIONE (stato presenza)
            // sono diversi dai tipi da trigger (transizioni) — è la stessa
            // distinzione che fa il nostro writer.
            withPresence: HMPresenceEvent(presenceEventType: .atHome, presenceUserType: .homeUsers)
        )
    }

    private func hourMinute(_ date: Date) -> (Int, Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? -1, parts.minute ?? -1)
    }

    // ── Il dialetto di Controller/Zappa Terra: «dopo le 08:31» da solo ──

    @Test("now() > {8:31} da solo: dopo le 08:31")
    func singleAfterFixedTime() {
        let conditions = AutomationWizardEditDraft.timeConditions(in: after(8, 31), triggerPredicates: [])
        #expect(conditions.count == 1)
        #expect(conditions.first?.kind == .fixedTime)
        #expect(conditions.first?.relation == .after)
        #expect(hourMinute(conditions.first!.time) == (8, 31))
    }

    // ── Il dialetto di Night Mode: presenza AND fascia a cavallo mezzanotte ──

    @Test("AND(presenza, OR(dopo 20:00, prima 01:59)): una fascia + una presenza")
    func nightModeShape() {
        let timespan = NSCompoundPredicate(orPredicateWithSubpredicates: [after(20, 0), before(1, 59)])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [presenceAtHome, timespan])

        let times = AutomationWizardEditDraft.timeConditions(in: predicate, triggerPredicates: [])
        #expect(times.count == 1)
        #expect(times.first?.relation == .between)
        #expect(hourMinute(times.first!.time) == (20, 0))
        #expect(hourMinute(times.first!.endTime) == (1, 59))

        let presences = AutomationWizardEditDraft.presenceConditions(in: predicate, triggerPredicates: [])
        #expect(presences.count == 1)
    }

    // ── L'AND PIATTO: orario e presenza fratelli, senza sotto-gruppi ──

    @Test("AND piatto (dopo 8:31, presenza): entrambe le condizioni emergono")
    func flatAndShape() {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [after(8, 31), presenceAtHome])

        let times = AutomationWizardEditDraft.timeConditions(in: predicate, triggerPredicates: [])
        #expect(times.count == 1)
        #expect(times.first?.relation == .after)
        #expect(hourMinute(times.first!.time) == (8, 31))

        let presences = AutomationWizardEditDraft.presenceConditions(in: predicate, triggerPredicates: [])
        #expect(presences.count == 1)
    }

    // (La coppia sunset/sunrise è provata sul campo — 'Porta Finestra' si
    // decodifica dal vivo — e le factory HMSignificantTimeEvent hanno firme
    // Swift ambigue nei test: niente test qui, il collaudo resta su device.)

    // ── La fascia nello stesso giorno, scritta come AND(dopo, prima) ──

    @Test("AND(dopo 08:00, prima 18:00): una condizione between")
    func sameDaySpan() {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [after(8, 0), before(18, 0)])
        let times = AutomationWizardEditDraft.timeConditions(in: predicate, triggerPredicates: [])
        #expect(times.count == 1)
        #expect(times.first?.relation == .between)
    }
}
