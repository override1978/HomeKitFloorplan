import Foundation
import HomeKit
import SwiftData
import Observation

// MARK: - FloorplanArchiveService

/// Mette da parte una planimetria e la rimette **come nuova**.
///
/// ⚠️ Il «come nuova» non è una comodità, è ciò che rende la funzione sicura.
/// Sovrascrivere la planimetria esistente significherebbe farlo anche sugli
/// altri device: le planimetrie si sincronizzano via CloudKit, quindi un
/// «annulla» locale diventerebbe una sovrascrittura di flotta, con l'iPhone che
/// si ritrova una versione di due settimane fa senza che nessuno gliel'abbia
/// chiesto. Creando una copia non c'è conflitto da risolvere e l'originale
/// resta lì mentre si confronta.
@MainActor
@Observable
final class FloorplanArchiveService {

    private let archive: ArchiveStore
    private let homeKit: HomeKitService
    private let context: ModelContext

    private let census: AccessoryCensusService

    init(archive: ArchiveStore,
         homeKit: HomeKitService,
         census: AccessoryCensusService,
         modelContainer: ModelContainer) {
        self.archive = archive
        self.homeKit = homeKit
        self.census = census
        self.context = ModelContext(modelContainer)
    }

    // MARK: - Mettere da parte

    @discardableResult
    func archive(_ floorplan: Floorplan, note: String = "") -> ArchivedItem? {
        guard let home = homeKit.currentHome else { return nil }
        let image = floorplan.currentImageData

        let payload = FloorplanArchive(
            name: floorplan.name,
            homeUUID: floorplan.homeUUID,
            tapModeRaw: floorplan.tapModeRaw,
            exteriorFillColorIndex: floorplan.exteriorFillColorIndex,
            drawingVisualExportStyleRaw: floorplan.drawingVisualExportStyleRaw,
            drawingExportRotationRaw: floorplan.drawingExportRotationRaw,
            linkedRoomsJSON: floorplan.linkedRoomsJSON,
            drawingDocumentJSON: floorplan.drawingDocumentJSON,
            markers: floorplan.accessories.map { marker in
                let accessory = homeKit.accessory(for: marker.homeKitAccessoryUUID)
                return FloorplanArchive.Marker(
                    homeKitAccessoryUUID: marker.homeKitAccessoryUUID,
                    // Nome e stanza accanto all'UUID: fra device l'UUID non
                    // coincide, e dopo un ri-accoppiamento non coincide più
                    // nemmeno qui. Stesso criterio di `HomeKitEntityResolver`.
                    accessoryName: accessory?.name,
                    roomName: accessory?.room?.name,
                    positionX: marker.positionX,
                    positionY: marker.positionY,
                    linkedRoomUUID: marker.linkedRoomUUID,
                    customLabel: marker.customLabel
                )
            },
            imageByteCount: image?.count ?? 0
        )

        let item = ArchivedItem(name: floorplan.name,
                                homeName: home.name,
                                deviceName: AppDeviceIdentity.displayName,
                                note: note,
                                content: .floorplan(payload))
        if let image { archive.storeImage(image, for: item.id) }
        return archive.add(item)
    }

    // MARK: - Rimettere

    enum RestoreError: LocalizedError {
        case notAFloorplan

        var errorDescription: String? {
            String(localized: "archive.floorplan.notAFloorplan",
                   defaultValue: "This copy is not a floorplan.")
        }
    }

    struct RestoreReport: Sendable {
        var name: String
        var markersPlaced: Int
        /// Marker messi giù ma senza un accessorio che risponda. Non sono
        /// perduti: finiscono fra gli accessori sconosciuti, dove si possono
        /// riabbinare o togliere.
        var markersUnresolved: [String]
    }

    @discardableResult
    func restoreAsNew(_ item: ArchivedItem) throws -> RestoreReport {
        guard case .floorplan(let payload) = item.content else { throw RestoreError.notAFloorplan }

        let copy = Floorplan(name: uniqueName(from: payload.name), homeUUID: payload.homeUUID)
        copy.imageData = archive.imageData(for: item.id)
        copy.tapModeRaw = payload.tapModeRaw
        copy.exteriorFillColorIndex = payload.exteriorFillColorIndex
        copy.drawingVisualExportStyleRaw = payload.drawingVisualExportStyleRaw
        copy.drawingExportRotationRaw = payload.drawingExportRotationRaw
        copy.linkedRoomsJSON = payload.linkedRoomsJSON
        copy.drawingDocumentJSON = payload.drawingDocumentJSON
        context.insert(copy)

        var placed = 0
        var unresolved: [String] = []
        for marker in payload.markers {
            let resolved = resolve(marker)
            // Il marker si mette **comunque**, anche se l'accessorio non si
            // trova. Lasciarlo fuori significherebbe consegnare una planimetria
            // che sembra completa e non lo è; messo, diventa una domanda a cui
            // «Accessori sconosciuti» sa già rispondere, con i candidati.
            let restored = PlacedAccessory(
                homeKitAccessoryUUID: resolved ?? marker.homeKitAccessoryUUID,
                position: NormalizedPoint(x: marker.positionX, y: marker.positionY),
                customLabel: marker.customLabel,
                linkedRoomUUID: marker.linkedRoomUUID
            )
            restored.floorplan = copy
            context.insert(restored)

            if resolved != nil {
                placed += 1
            } else {
                let name = marker.accessoryName ?? marker.customLabel ?? "—"
                unresolved.append(name)
                // Serve la riga di censimento, altrimenti la riconciliazione non
                // ha niente su cui costruire la domanda.
                census.recordAbsent(name: name,
                                    roomName: marker.roomName,
                                    localUUID: marker.homeKitAccessoryUUID)
            }
        }
        try context.save()
        return RestoreReport(name: copy.name, markersPlaced: placed, markersUnresolved: unresolved)
    }

    /// UUID salvato se quell'accessorio esiste ancora, altrimenti per nome e
    /// stanza — che fra device sono gli unici a coincidere.
    private func resolve(_ marker: FloorplanArchive.Marker) -> UUID? {
        HomeKitEntityResolver.resolveAccessory(
            remoteUUID: marker.homeKitAccessoryUUID,
            accessoryName: marker.accessoryName,
            roomName: marker.roomName,
            in: homeKit.allAccessories.map {
                HomeKitEntityResolver.AccessoryRef(uuid: $0.uniqueIdentifier,
                                                   name: $0.name,
                                                   roomName: $0.room?.name)
            }
        )
    }

    /// «Cucina» accanto a «Cucina» non si distinguono, e la copia serve proprio
    /// a stare accanto all'originale per confronto.
    private func uniqueName(from name: String) -> String {
        let existing = Set(((try? context.fetch(FetchDescriptor<Floorplan>())) ?? []).map(\.name))
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }
}
