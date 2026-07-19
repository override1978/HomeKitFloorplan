import Foundation
import Testing
@testable import HomeFloorplan

/// Test della risoluzione UUID remoti → entità HomeKit locali,
/// estratta dalle closure inline di HomeFloorplanApp.init.
@Suite("HomeKitEntityResolver — match UUID, nome+stanza, solo nome")
struct HomeKitEntityResolverTests {

    private func acc(_ name: String, room: String?) -> HomeKitEntityResolver.AccessoryRef {
        .init(uuid: UUID(), name: name, roomName: room)
    }

    @Test("UUID presente localmente: match diretto anche con nome diverso")
    func directUUIDMatchWins() {
        let local = acc("Lampada", room: "Studio")
        let result = HomeKitEntityResolver.resolveAccessory(
            remoteUUID: local.uuid, accessoryName: "Altro nome", roomName: nil,
            in: [local]
        )
        #expect(result == local.uuid)
    }

    @Test("UUID sconosciuto: vince il match nome+stanza sul match solo-nome")
    func nameAndRoomBeatsNameOnly() {
        let inKitchen = acc("Luce", room: "Cucina")
        let inStudio = acc("Luce", room: "Studio")
        let result = HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(), accessoryName: "Luce", roomName: "Studio",
            in: [inKitchen, inStudio]
        )
        #expect(result == inStudio.uuid)
    }

    @Test("Match per nome è case/whitespace-insensitive")
    func nameMatchingIsNormalized() {
        let local = acc("Presa Isola", room: nil)
        let result = HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(), accessoryName: "  presa isola ", roomName: nil,
            in: [local]
        )
        #expect(result == local.uuid)
    }

    @Test("Stanza remota senza corrispondenza: fallback al solo nome")
    func unknownRoomFallsBackToName() {
        let local = acc("Sensore", room: "Bagno")
        let result = HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(), accessoryName: "Sensore", roomName: "Cantina",
            in: [local]
        )
        #expect(result == local.uuid)
    }

    @Test("Nome remoto nil o vuoto: nessun match")
    func missingNameReturnsNil() {
        let local = acc("Luce", room: nil)
        #expect(HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(), accessoryName: nil, roomName: nil, in: [local]) == nil)
        #expect(HomeKitEntityResolver.resolveAccessory(
            remoteUUID: UUID(), accessoryName: "   ", roomName: nil, in: [local]) == nil)
    }

    @Test("resolveRoom: UUID diretto, poi nome normalizzato, poi nil")
    func roomResolution() {
        let salotto = HomeKitEntityResolver.RoomRef(uuid: UUID(), name: "Salotto")
        #expect(HomeKitEntityResolver.resolveRoom(
            remoteUUID: salotto.uuid, roomName: nil, in: [salotto]) == salotto.uuid)
        #expect(HomeKitEntityResolver.resolveRoom(
            remoteUUID: UUID(), roomName: " SALOTTO ", in: [salotto]) == salotto.uuid)
        #expect(HomeKitEntityResolver.resolveRoom(
            remoteUUID: UUID(), roomName: "Cucina", in: [salotto]) == nil)
    }
}
