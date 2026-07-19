import Foundation
import Testing
@testable import HomeFloorplan

/// Transizioni di stato dell'editor floorplan, ora unit-testabili
/// grazie al raggruppamento in `FloorplanEditorUIState`.
@MainActor
@Suite("FloorplanEditorUIState — transizioni e stato derivato")
struct FloorplanEditorUIStateTests {

    @Test("Stato iniziale: non in editing, nessuna selezione né modale")
    func initialState() {
        let ui = FloorplanEditorUIState()
        #expect(ui.isEditing == false)
        #expect(ui.selectedMarkerID == nil)
        #expect(ui.hasBlockingModalPresentation == false)
        #expect(ui.shouldSuppressIdleScreensaver == false)
    }

    @Test("toggleEditing in uscita azzera selezione e stanza evidenziata")
    func exitEditingClearsSelection() {
        let ui = FloorplanEditorUIState()
        ui.isEditing = true
        ui.selectedMarkerID = UUID()
        ui.editHighlightedRoomID = UUID()
        ui.suppressNextMarkerTapID = UUID()
        ui.executingMarkerID = UUID()

        ui.toggleEditing()

        #expect(ui.isEditing == false)
        #expect(ui.selectedMarkerID == nil)
        #expect(ui.editHighlightedRoomID == nil)
        #expect(ui.suppressNextMarkerTapID == nil)
        #expect(ui.executingMarkerID == nil)
    }

    @Test("toggleEditing in entrata conserva la selezione ma azzera i flag transienti")
    func enterEditingKeepsSelection() {
        let ui = FloorplanEditorUIState()
        let marker = UUID()
        ui.selectedMarkerID = marker
        ui.suppressNextMarkerTapID = UUID()

        ui.toggleEditing()

        #expect(ui.isEditing == true)
        #expect(ui.selectedMarkerID == marker)
        #expect(ui.suppressNextMarkerTapID == nil)
    }

    @Test("resetAccessoryPickerContext azzera filtro, posizione e highlight")
    func resetPickerContext() {
        let ui = FloorplanEditorUIState()
        ui.pickerRoomFilter = UUID()
        ui.pendingMarkerPosition = NormalizedPoint(x: 0.3, y: 0.3)
        ui.editHighlightedRoomID = UUID()

        ui.resetAccessoryPickerContext()

        #expect(ui.pickerRoomFilter == nil)
        #expect(ui.pendingMarkerPosition == nil)
        #expect(ui.editHighlightedRoomID == nil)
    }

    @Test("dismissSelectedMarker azzera la selezione")
    func dismissSelection() {
        let ui = FloorplanEditorUIState()
        ui.selectedMarkerID = UUID()
        ui.dismissSelectedMarker()
        #expect(ui.selectedMarkerID == nil)
    }

    @Test("Ogni modale blocca l'aiuto contestuale e lo screensaver")
    func blockingModalsAreDetected() {
        let cases: [(FloorplanEditorUIState) -> Void] = [
            { $0.showingPicker = true },
            { $0.iconPickerTargetID = UUID() },
            { $0.showFloorplanDiagnostics = true },
            { $0.showScenesPanel = true }
        ]
        for apply in cases {
            let ui = FloorplanEditorUIState()
            apply(ui)
            #expect(ui.hasBlockingModalPresentation == true)
            #expect(ui.shouldSuppressIdleScreensaver == true)
        }
    }

    @Test("Help e delete pendente sopprimono lo screensaver ma non bloccano l'help")
    func helpAndPendingDeleteSuppressScreensaverOnly() {
        let helpUI = FloorplanEditorUIState()
        helpUI.showFloorplanHelp = true
        #expect(helpUI.hasBlockingModalPresentation == false)
        #expect(helpUI.shouldSuppressIdleScreensaver == true)

        let deleteUI = FloorplanEditorUIState()
        deleteUI.pendingDeleteMarkerID = UUID()
        #expect(deleteUI.hasBlockingModalPresentation == false)
        #expect(deleteUI.shouldSuppressIdleScreensaver == true)
    }
}
