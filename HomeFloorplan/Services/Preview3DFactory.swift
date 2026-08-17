import SwiftUI
import SwiftData

// MARK: - Preview3DFactory

/// Costruisce la richiesta per la vista 3D a partire dai modelli SwiftData.
///
/// Era un blocco privato di `FloorplanListView`. Con il secondo punto
/// d'ingresso — l'editor — sarebbe diventato la copia destinata a divergere:
/// lo stesso errore già pagato col salvataggio del ridisegno, dove la copia
/// rimasta indietro ha perso pezzi in silenzio per settimane.
///
/// Le scritture passano tutte da `FloorplanMarkerEditingCoordinator`: la 3D
/// riceve chiusure, mai il contesto.
@MainActor
enum Preview3DFactory {

    /// La richiesta completa: **tutte** le planimetrie con un disegno, così il
    /// menu del titolo può cambiare piano senza uscire dalla vista.
    static func request(initialID: UUID,
                        floorplans: [Floorplan],
                        modelContext: ModelContext,
                        cloudKitSync: CloudKitSyncService,
                        homeKit: HomeKitService) -> Preview3DRequest? {
        let previewable = floorplans.compactMap {
            preview($0, modelContext: modelContext,
                    cloudKitSync: cloudKitSync, homeKit: homeKit)
        }
        guard previewable.contains(where: { $0.id == initialID }) else { return nil }
        return Preview3DRequest(floorplans: previewable, initialID: initialID)
    }

    /// Una planimetria pronta per il volume, o `nil` se non c'è un disegno da
    /// estrudere: da una foto ricalcata non si ricava niente.
    static func preview(_ plan: Floorplan,
                        modelContext: ModelContext,
                        cloudKitSync: CloudKitSyncService,
                        homeKit: HomeKitService) -> Preview3DFloorplan? {
        guard let document = plan.drawingDocument, !document.walls.isEmpty else { return nil }

        func coordinator(_ plan: Floorplan) -> FloorplanMarkerEditingCoordinator {
            FloorplanMarkerEditingCoordinator(floorplan: plan,
                                              modelContext: modelContext,
                                              cloudKitSync: cloudKitSync,
                                              homeKit: homeKit)
        }

        return Preview3DFloorplan(
            id: plan.id,
            name: plan.name,
            document: document,
            readNorthBearing: { [weak plan, initial = plan.northBearingDegrees] in
                plan?.northBearingDegrees ?? initial
            },
            applyNorthBearing: { [weak plan] bearing in
                guard let plan else { return }
                coordinator(plan).setNorthBearing(bearing)
            },
            ceilingHeight: plan.ceilingHeightMetres,
            applyCeilingHeight: { [weak plan] metres in
                guard let plan else { return }
                coordinator(plan).setCeilingHeight(metres)
            },
            markers: plan.accessories.map { placed in
                Preview3DMarker(
                    uuid: placed.homeKitAccessoryUUID,
                    position: CGPoint(x: placed.positionX, y: placed.positionY),
                    openingID: placed.linkedOpeningID
                )
            },
            lampSettings: { [weak plan] uuid in
                guard let placed = plan?.accessories.first(where: { $0.homeKitAccessoryUUID == uuid })
                else { return LampSettings() }
                let renderStyle = placed.lightRenderStyleRaw
                    .flatMap(LampRenderStyle.init(rawValue:))
                    ?? (placed.isDeclaredLight ? .marker : .spotlight)
                return LampSettings(
                    height: placed.mountHeight,
                    direction: placed.lightDirectionRaw.flatMap(LampDirection.init(rawValue:)),
                    renderStyle: renderStyle,
                    position: CGPoint(x: placed.positionX, y: placed.positionY),
                    isDeclaredLight: placed.isDeclaredLight
                )
            },
            applyLampSettings: { [weak plan] uuid, height, direction, renderStyle in
                guard let plan else { return }
                coordinator(plan).setLampSettings(accessoryUUID: uuid,
                                                  height: height,
                                                  direction: direction,
                                                  renderStyle: renderStyle)
            },
            applyDeclaredLight: { [weak plan] uuid, flag in
                guard let plan else { return }
                coordinator(plan).setDeclaredLight(accessoryUUID: uuid, flag)
            },
            applyMarkerPosition: { [weak plan] uuid, position in
                guard let plan else { return }
                coordinator(plan).setMarkerPosition(
                    accessoryUUID: uuid,
                    to: NormalizedPoint(x: Double(position.x), y: Double(position.y))
                )
            },
            applyARCalibration: { [weak plan] calibration in
                guard let plan else { return }
                coordinator(plan).setARCalibration(calibration)
            },
            exportRotation: plan.drawingExportRotation,
            background: background(for: plan)
        )
    }

    /// La 3D è un diorama su un palco da studio: fondale neutro caldo che fa
    /// risaltare la casa invece di competerci (il prato saturo la faceva
    /// giocattolo). La tinta esterna scelta nel 2D resta un fatto del disegno
    /// e dell'export — il 3D ha la sua scenografia. Lo stile scuro resta un
    /// palco scuro.
    static func background(for floorplan: Floorplan) -> UIColor {
        if floorplan.drawingVisualExportStyleRaw == DrawingVisualExportStyle.architecturalDark.rawValue {
            return UIColor(red: 0.108, green: 0.114, blue: 0.126, alpha: 1)
        }
        return UIColor(red: 0.852, green: 0.842, blue: 0.822, alpha: 1)
    }
}
