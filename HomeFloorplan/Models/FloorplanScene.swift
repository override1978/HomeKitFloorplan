import Foundation
import CoreGraphics
import simd

// MARK: - FloorplanScene

/// Renderer-agnostic model for a generated 3D floorplan.
struct FloorplanScene {
    struct MeshFace {
        enum MaterialRole: Hashable {
            case floor
            case wall
            case wallTop
            case glass
            case frame
            case door
            case doorEdge
            case doorTrim
            case doorGlass
            case doorHandle
            case houseShadow
            /// La macchia di sole che entra da un vetro e cade sul pavimento.
            case sunPatch
            case balcony
            case balconyTop
            case furniture
            case wallGlow
            /// L'ombra di contatto alla base di un muro.
            case wallContact
            /// L'ombra che un arredo lascia sul pavimento.
            case groundContact
            /// La tapparella calata davanti a un vano.
            case shutter
            /// La tenda da sole stesa sopra un balcone.
            case awning
        }

        var points: [SIMD3<Float>]
        var role: MaterialRole
        var roomID: UUID?
        var roomName: String?
        var floorKind: FloorKind? = nil
        var openingKind: OpeningKind? = nil
        /// Quale apertura ha generato questa faccia: serve al sole, che non deve
        /// passare da un vetro con la tapparella giù.
        var openingID: UUID? = nil
        var wallKind: WallKind? = nil
        var flipSide: Bool = false
        /// Tinta del pezzo, solo per gli arredi: l'estrusore la assegnava gia',
        /// ma la pipeline la perdeva qui e tutto usciva dello stesso beige.
        var tint: CGColor? = nil
    }

    var faces: [MeshFace]
    var bounds: Bounds
    /// Ciò che cambia la **forma** senza cambiare il conteggio delle facce.
    ///
    /// Un'anta che si apre ha esattamente le stesse facce di prima, solo
    /// ruotate, e il bounding box lo decide la casa: contarle non basta a
    /// distinguere aperto da chiuso. Senza questo, il gate anti-ricostruzione
    /// scartava l'aggiornamento e la porta restava dipinta chiusa.
    var stateSignature: String = ""

    var renderSignature: String {
        [
            stateSignature,
            "\(faces.count)",
            "\(bounds.min.x)",
            "\(bounds.min.y)",
            "\(bounds.min.z)",
            "\(bounds.max.x)",
            "\(bounds.max.y)",
            "\(bounds.max.z)"
        ].joined(separator: ":")
    }

    struct Bounds {
        var min: SIMD3<Float>
        var max: SIMD3<Float>

        var center: SIMD3<Float> {
            (min + max) / 2
        }

        var horizontalSize: SIMD2<Float> {
            SIMD2(max.x - min.x, max.z - min.z)
        }

        var radius: Float {
            let width = horizontalSize.x
            let depth = horizontalSize.y
            let height = max.y - min.y
            return Swift.max(Swift.max(width, depth), height) / 2
        }
    }
}
