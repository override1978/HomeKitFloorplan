import Foundation
import Testing
@testable import HomeFloorplan

@Suite("Controllo lingua delle risposte AI")
@MainActor
struct AILanguageSuspectTests {

    /// Il caso che il controllo precedente sbagliava: italiano corretto ma
    /// senza accenti, quindi tutto ASCII, quindi dichiarato inglese. Preso
    /// testualmente dal log del pannello.
    @Test("Una frase italiana senza accenti non è sospetta")
    func plainAsciiItalianIsNotSuspect() {
        let msg = "Studio: aria viziata di notte, ventilare subito per dormire bene."
        #expect(!AmbientalAIService.languageSuspect(message: msg, expected: "Italian"))
    }

    @Test("Una frase inglese quando ci si aspetta italiano è sospetta")
    func englishWhenItalianExpected() {
        let msg = "The air in this room has been high for hours, open the window."
        #expect(AmbientalAIService.languageSuspect(message: msg, expected: "Italian"))
    }

    /// Il controllo precedente non guardava affatto questo caso.
    @Test("Il controllo è simmetrico")
    func italianWhenEnglishExpected() {
        let msg = "La qualita dell aria nella stanza e molto alta, apri la finestra."
        #expect(AmbientalAIService.languageSuspect(message: msg, expected: "English"))
    }

    @Test("Una frase italiana con accenti resta non sospetta")
    func accentedItalianIsNotSuspect() {
        let msg = "L'umidità è più alta del solito nella stanza da letto."
        #expect(!AmbientalAIService.languageSuspect(message: msg, expected: "Italian"))
    }

    /// Su testi troppo corti tace, invece di tirare a indovinare.
    @Test("Un messaggio troppo corto non viene giudicato")
    func tooShortIsNeverSuspect() {
        #expect(!AmbientalAIService.languageSuspect(message: "CO2 alta", expected: "Italian"))
        #expect(!AmbientalAIService.languageSuspect(message: "", expected: "Italian"))
    }

    /// Nomi propri e sigle non devono bastare ad accusare.
    @Test("Uno scarto di una sola parola non basta")
    func singleMarkerIsNotEnough() {
        let msg = "Studio: CO2 oltre 1200 ppm, ventilare la stanza."
        #expect(!AmbientalAIService.languageSuspect(message: msg, expected: "Italian"))
    }
}
