import Foundation
import CoreGraphics
import simd
import Testing
@testable import HomeFloorplan

/// Gli assi della proiezione AR→pianta, inchiodati. Ogni test è un caso che
/// «faceva ammattire»: qui camminare a destra DEVE andare a destra.
@Suite("ARPlanAligner — dallo spazio AR alla pianta")
struct ARPlanAlignerTests {

    /// Posa camera: posizione + rotazione attorno all'asse verticale.
    /// yaw 0 = guarda −z (la direzione iniziale di sessione); positivo = gira
    /// in senso orario visto dall'alto (verso +x).
    private func pose(x: Float = 0, z: Float = 0, yawDegrees: Float = 0) -> simd_float4x4 {
        let yaw = yawDegrees * .pi / 180
        var transform = matrix_identity_float4x4
        // ⚠️ La rotazione standard R_y è ANTIORARIA vista dall'alto (regola
        // della mano destra, y in su): per la convenzione promessa qui —
        // positivo = orario, verso +x — serve l'angolo NEGATO. Il primo run
        // di questi test è caduto proprio su questo: la trappola n°3 esiste
        // anche negli harness. Forward risultante: (sin yaw, −cos yaw).
        transform.columns.0 = SIMD4(cos(yaw), 0, sin(yaw), 0)
        transform.columns.2 = SIMD4(-sin(yaw), 0, cos(yaw), 0)
        transform.columns.3 = SIMD4(x, 0, z, 1)
        return transform
    }

    private let origin = CGPoint(x: 1000, y: 1000)
    private let mapUp = CGPoint(x: 0, y: -1)

    private func aligner(yawDegrees: Float = 0,
                         facing: CGPoint? = nil) -> ARPlanAligner {
        ARPlanAligner.aligned(originPlanPoint: origin,
                              cameraTransform: pose(yawDegrees: yawDegrees),
                              facingPlanDirection: facing ?? mapUp,
                              pointsPerMetre: 100)
    }

    @Test("Allineato verso l'alto mappa: avanti va in alto")
    func forwardGoesUp() {
        let a = aligner()
        let p = a.planPoint(for: SIMD3(0, 0, -2))   // 2 m avanti (−z)
        #expect(abs(p.x - 1000) < 0.01)
        #expect(abs(p.y - 800) < 0.01)              // su = y canvas che scende
    }

    /// IL caso del bug: «vado a destra e sulla mappa risulto in alto a
    /// sinistra». Destra deve essere destra — né specchi né rotazioni spurie.
    @Test("Destra va a destra, mai in alto a sinistra")
    func rightGoesRight() {
        let a = aligner()
        let p = a.planPoint(for: SIMD3(2, 0, 0))    // 2 m a destra (+x)
        #expect(abs(p.x - 1200) < 0.01)
        #expect(abs(p.y - 1000) < 0.01)
    }

    @Test("La diagonale avanti-destra resta avanti-destra (niente specchio)")
    func diagonalIsNotMirrored() {
        let a = aligner()
        let p = a.planPoint(for: SIMD3(1, 0, -1))
        #expect(p.x > 1000 && p.y < 1000)           // destra E alto
    }

    /// L'Align può avvenire guardando ovunque: se al momento dell'Align la
    /// camera era già girata di 90° a destra, quel «davanti» È l'alto mappa.
    @Test("Align con camera già ruotata di 90°: il suo avanti è l'alto mappa")
    func alignedWhileRotated() {
        let a = aligner(yawDegrees: 90)             // guarda +x
        let p = a.planPoint(for: SIMD3(2, 0, 0))    // cammina verso +x (il suo avanti)
        #expect(abs(p.x - 1000) < 0.01)
        #expect(abs(p.y - 800) < 0.01)              // = alto mappa
    }

    @Test("Align a 180°: camminare verso +z è l'alto mappa")
    func alignedBackwards() {
        let a = aligner(yawDegrees: 180)
        let p = a.planPoint(for: SIMD3(0, 0, 2))
        #expect(abs(p.x - 1000) < 0.1)
        #expect(abs(p.y - 800) < 0.1)
    }

    /// L'Align può puntare qualunque direzione DELLA PIANTA, non solo l'alto:
    /// guardo «destra mappa», cammino avanti, e sulla mappa vado a destra.
    @Test("Align verso destra-mappa: avanti va a destra sulla pianta")
    func alignToMapRight() {
        let a = aligner(facing: CGPoint(x: 1, y: 0))
        let p = a.planPoint(for: SIMD3(0, 0, -2))
        #expect(abs(p.x - 1200) < 0.01)
        #expect(abs(p.y - 1000) < 0.01)
    }

    @Test("La quota (y AR) non sposta il punto sulla pianta")
    func heightIsIgnored() {
        let a = aligner()
        let p = a.planPoint(for: SIMD3(0, 1.4, -2))
        #expect(abs(p.x - 1000) < 0.01 && abs(p.y - 800) < 0.01)
    }

    @Test("La freccia di direzione segue la camera, in convenzione canvas")
    func headingFollowsCamera() {
        let a = aligner()
        // Camera che guarda avanti → freccia verso l'alto mappa.
        let up = a.planHeading(for: pose(yawDegrees: 0))
        #expect(abs(up.dx) < 0.01 && up.dy < -0.99)
        // Camera girata a destra → freccia verso destra mappa.
        let right = a.planHeading(for: pose(yawDegrees: 90))
        #expect(right.dx > 0.99 && abs(right.dy) < 0.01)
    }

    /// La via a bussola (.gravityAndHeading): −z = nord. Con la pianta che
    /// guarda a nord (β = 0), camminare verso nord è l'alto mappa.
    @Test("Bussola, pianta verso nord: nord è l'alto mappa")
    func headingAlignedNorth() {
        let a = ARPlanAligner.headingAligned(originPlanPoint: origin,
                                             originARPosition: .zero,
                                             northBearingDegrees: 0,
                                             pointsPerMetre: 100)
        let p = a.planPoint(for: SIMD3(0, 0, -2))   // 2 m verso nord
        #expect(abs(p.x - 1000) < 0.01 && abs(p.y - 800) < 0.01)
    }

    /// Pianta col lato alto verso EST (β = 90): camminare verso est (+x)
    /// deve essere l'alto mappa, e il nord deve finire a sinistra.
    @Test("Bussola, pianta verso est: est è l'alto mappa, nord la sinistra")
    func headingAlignedEast() {
        let a = ARPlanAligner.headingAligned(originPlanPoint: origin,
                                             originARPosition: .zero,
                                             northBearingDegrees: 90,
                                             pointsPerMetre: 100)
        let east = a.planPoint(for: SIMD3(2, 0, 0))
        #expect(abs(east.x - 1000) < 0.01 && abs(east.y - 800) < 0.01)
        let north = a.planPoint(for: SIMD3(0, 0, -2))
        #expect(abs(north.x - 800) < 0.01 && abs(north.y - 1000) < 0.01)
    }

    /// ⚠️ La trappola n°1 resa test: columns.2 è il DIETRO. Se qualcuno
    /// togliesse il segno meno, questo test lo becca (darebbe (0, 1)).
    @Test("Il forward è −z, non +z")
    func forwardIsMinusZ() {
        let f = ARPlanAligner.cameraForwardOnFloor(matrix_identity_float4x4)
        #expect(f.y < -0.99 && abs(f.x) < 0.01)
    }
}
