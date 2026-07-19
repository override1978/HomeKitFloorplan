import SwiftUI
import HomeKit

/// Stato UI dell'editor floorplan, raggruppato in un unico oggetto @Observable.
///
/// Sostituisce i ~17 `@State` sparsi che `FloorplanEditorView` accumulava
/// (editing/selezione marker, contesto del picker accessori, presentazioni
/// modali). Le transizioni di stato vivono qui come metodi, così sono
/// unit-testabili senza SwiftUI; la view mantiene solo stato infrastrutturale
/// (viewport, cache, chrome auto-hide).
@MainActor
@Observable
final class FloorplanEditorUIState {

    // MARK: - Editing e selezione marker

    var isEditing = false
    var selectedMarkerID: UUID?
    var dragDeltas: [UUID: CGSize] = [:]
    var shakeMarkerID: UUID?
    var executingMarkerID: UUID?
    var suppressNextMarkerTapID: UUID?
    var editHighlightedRoomID: UUID?
    var pendingDeleteMarkerID: UUID?

    // MARK: - Picker accessori

    var showingPicker = false
    /// When set, the picker shows this room prominently (tap on room area).
    var pickerRoomFilter: UUID?
    /// Normalized position where the user tapped — new accessories placed here.
    var pendingMarkerPosition: NormalizedPoint?

    // MARK: - Presentazioni modali

    var controllingAccessory: HMAccessory?
    var iconPickerTargetID: UUID?
    var showFloorplanDiagnostics = false
    var drawingEditFloorplan: Floorplan?
    var showScenesPanel = false
    var showFloorplanHelp = false

    // MARK: - Stato derivato

    /// Sheet/overlay modali che, se presenti, bloccano la comparsa dell'aiuto
    /// contestuale. Sorgente unica condivisa con `shouldSuppressIdleScreensaver`
    /// per evitare drift tra le due liste.
    var hasBlockingModalPresentation: Bool {
        showingPicker
            || controllingAccessory != nil
            || iconPickerTargetID != nil
            || showFloorplanDiagnostics
            || showScenesPanel
    }

    var shouldSuppressIdleScreensaver: Bool {
        hasBlockingModalPresentation
            || showFloorplanHelp
            || pendingDeleteMarkerID != nil
    }

    // MARK: - Transizioni

    func toggleEditing() {
        isEditing.toggle()
        suppressNextMarkerTapID = nil
        executingMarkerID = nil
        if !isEditing {
            selectedMarkerID = nil
            editHighlightedRoomID = nil
        }
    }

    func resetAccessoryPickerContext() {
        pickerRoomFilter = nil
        pendingMarkerPosition = nil
        editHighlightedRoomID = nil
    }

    func dismissSelectedMarker() {
        withAnimation(.spring(response: 0.35)) {
            selectedMarkerID = nil
        }
    }
}
