import SwiftUI

struct FloorplanSelectedMarkerToolbarState {
    let markerName: String
    let initialRenameText: String
    let auditNotice: MarkerAuditNotice?
}

struct FloorplanSecondaryControlsLayer: View {
    let effectiveScale: CGFloat
    /// Spazio occupato in fondo dal nastro, da non invadere.
    var bottomInset: CGFloat = 0
    let isEditing: Bool
    let isOverlayPanelVisible: Bool?
    let activeOverlayMode: FloorplanOverlayMode?
    let selectedMarkerID: UUID?
    let selectedMarker: FloorplanSelectedMarkerToolbarState?
    let onResetZoom: () -> Void
    let onRenameMarker: (UUID, String) -> Void
    let onResetMarkerName: (UUID) -> Void
    let onRecenterMarker: (UUID) -> Void
    let onDeleteMarker: (UUID) -> Void
    let onDismissMarker: () -> Void
    let onChangeMarkerIcon: (UUID) -> Void
    let onResolveMarkerAudit: (UUID) -> Void

    var body: some View {
        FloorplanSecondaryControls(
            effectiveScale: effectiveScale,
            bottomInset: bottomInset,
            isOverlayPanelVisible: isOverlayPanelVisible,
            activeOverlayMode: activeOverlayMode,
            selectedMarkerID: selectedMarkerID,
            selectedMarker: activeSelectedMarker,
            onResetZoom: onResetZoom,
            onRenameMarker: renameSelectedMarker,
            onResetMarkerName: resetSelectedMarkerName,
            onRecenterMarker: recenterSelectedMarker,
            onDeleteMarker: deleteSelectedMarker,
            onDismissMarker: onDismissMarker,
            onChangeMarkerIcon: changeSelectedMarkerIcon,
            onResolveMarkerAudit: resolveSelectedMarkerAudit
        )
    }

    private var activeSelectedMarker: FloorplanSelectedMarkerToolbarState? {
        guard isEditing, selectedMarkerID != nil else { return nil }
        return selectedMarker
    }

    private var resolveSelectedMarkerAudit: (() -> Void)? {
        guard let selectedMarkerID,
              activeSelectedMarker?.auditNotice != nil else { return nil }

        return {
            onResolveMarkerAudit(selectedMarkerID)
        }
    }

    private func renameSelectedMarker(_ newLabel: String) {
        guard let selectedMarkerID else { return }
        onRenameMarker(selectedMarkerID, newLabel)
    }

    private func resetSelectedMarkerName() {
        guard let selectedMarkerID else { return }
        onResetMarkerName(selectedMarkerID)
    }

    private func recenterSelectedMarker() {
        guard let selectedMarkerID else { return }
        onRecenterMarker(selectedMarkerID)
    }

    private func deleteSelectedMarker() {
        guard let selectedMarkerID else { return }
        onDeleteMarker(selectedMarkerID)
    }

    private func changeSelectedMarkerIcon() {
        guard let selectedMarkerID else { return }
        onChangeMarkerIcon(selectedMarkerID)
    }
}

struct FloorplanSecondaryControls: View {
    let effectiveScale: CGFloat
    /// Spazio occupato in fondo dal nastro, da non invadere.
    var bottomInset: CGFloat = 0
    let isOverlayPanelVisible: Bool?
    let activeOverlayMode: FloorplanOverlayMode?
    let selectedMarkerID: UUID?
    let selectedMarker: FloorplanSelectedMarkerToolbarState?
    let onResetZoom: () -> Void
    let onRenameMarker: (String) -> Void
    let onResetMarkerName: () -> Void
    let onRecenterMarker: () -> Void
    let onDeleteMarker: () -> Void
    let onDismissMarker: () -> Void
    let onChangeMarkerIcon: () -> Void
    let onResolveMarkerAudit: (() -> Void)?

    var body: some View {
        zoomIndicator
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOverlayPanelVisible)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeOverlayMode)

        if let selectedMarker {
            VStack {
                Spacer()
                MarkerActionToolbar(
                    markerName: selectedMarker.markerName,
                    initialRenameText: selectedMarker.initialRenameText,
                    onRename: onRenameMarker,
                    onResetName: onResetMarkerName,
                    onRecenter: onRecenterMarker,
                    onDelete: onDeleteMarker,
                    onDismiss: onDismissMarker,
                    onChangeIcon: onChangeMarkerIcon,
                    auditNotice: selectedMarker.auditNotice,
                    onResolveAudit: onResolveMarkerAudit
                )
                .padding(.bottom, 20)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedMarkerID)
        }
    }

    private var zoomIndicator: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                VStack(spacing: 10) {
                    // La soglia deve accordarsi con ciò che l'etichetta
                    // SCRIVE, non con ciò che il numero vale.
                    //
                    // Era 1.01, ma il formato ha una sola cifra decimale:
                    // tutto fra 1.011 e 1.049 compariva scrivendo «1.0×»,
                    // cioè un comando che si offriva di togliere uno zoom
                    // mentre dichiarava che non ce n'era. Bastava che la
                    // colonna della mappa cambiasse larghezza — aprendo il
                    // pannello dei filtri, per dire — perché il fit si
                    // assestasse su uno di quei valori.
                    //
                    // 1.05 è il primo che arrotonda a «1.1×».
                    if effectiveScale >= 1.05 {
                        GlassTitlePill {
                            HStack(spacing: 8) {
                                Text(String(format: "%.1f×", effectiveScale))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                                Divider().frame(height: 20)
                                Button {
                                    onResetZoom()
                                } label: {
                                    Image(systemName: "1.magnifyingglass")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        // Sola opacità: scalare il vetro ne cambia la geometria
                        // a ogni fotogramma della transizione.
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 20)
            // Il nastro attraversa tutto il fondo: senza il suo ingombro
            // questa pastiglia gli finisce sotto, come si vedeva.
            .padding(.bottom, 20 + bottomInset)
        }
    }
}
