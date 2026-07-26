import Foundation
import Testing
@testable import HomeFloorplan

/// Ciò che resta dei test anti-duplicazione dopo il ritiro del motore abitudini:
/// `AutomationDuplicateChecker` e `HabitNoiseFilter` sono stati rimossi con esso,
/// mentre la decodifica della causeSignature vive ancora nel mapper automazioni.
@MainActor
@Suite("Automazioni — decodifica causeSignature")
struct CauseSignatureTests {

    @Test("causeSignature → stato trigger: on/dim attivano, off disattiva, sconosciuto nil")
    func causeTriggerStateParsing() {
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "light:Faretti Cucina:on") == true)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "light:Lampada:dim") == true)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "switch:TV:off") == false)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "sensor:X:unknown-action") == nil)
        #expect(AutomationProposalMapper.causeTriggerState(fromSignature: "malformed") == nil)
    }
}
