import CoreGraphics
import simd

// MARK: - ARPlanAligner

/// Il ponte fra lo spazio della sessione AR e la pianta: dato «sono QUI sulla
/// pianta e sto guardando in QUESTA direzione della pianta» (il tuo Align),
/// converte ogni posizione AR successiva in un punto canvas, e la posa della
/// camera in una freccia di direzione sulla mappa.
///
/// Geometria pura, niente ARKit e niente stato di sessione: si testa a
/// tavolino. È il pezzo che chiude il «vado a destra e sulla mappa vado in
/// alto a sinistra» — che non era un angolo sbagliato ma uno SPECCHIO, il
/// difetto classico di questa proiezione. Le tre trappole, inchiodate qui:
///
/// 1. ⚠️ `columns.2` della camera è **+z, cioè il DIETRO**: il forward è −z.
///    Dimenticare il segno = 180° di errore.
/// 2. ⚠️ Il canvas ha la **y in giù**; lo spazio AR visto dall'alto no.
///    Mescolare le convenzioni produce una riflessione, non una rotazione —
///    ed è la riflessione a trasformare «destra» in «alto-sinistra».
/// 3. ⚠️ Gli angoli si misurano con la **stessa convenzione** nei due spazi:
///    proiezione dall'alto, senso orario positivo. Qui: φ = atan2(x, −z) in
///    AR e ψ = atan2(x, −y) sul canvas — entrambe «0 = avanti/alto, positivo
///    = orario» — così la differenza è UNA rotazione e basta.
///
/// L'`angleOffset` è **di sessione**: gli assi AR nascono dall'orientamento
/// del telefono all'avvio, quindi va ricalcolato a ogni Align. Ciò che si
/// persiste (ARFloorCalibration) sono solo punto-pianta e mapForward.
struct ARPlanAligner: Equatable {

    /// Dove sta l'utente sulla pianta al momento dell'Align, in punti canvas.
    var originPlanPoint: CGPoint
    /// Dove sta la camera nello spazio AR nello stesso istante.
    var originARPosition: SIMD3<Float>
    /// ψ_forward − φ_forward: la rotazione che porta gli angoli AR in angoli
    /// canvas. Radianti.
    var angleOffset: Double
    /// Scala della pianta: punti canvas per metro.
    var pointsPerMetre: Double

    // MARK: Costruzione

    /// L'Align: l'utente sta in `originPlanPoint` e il telefono INQUADRA la
    /// direzione `facingPlanDirection` della pianta (nel MVP: l'alto della
    /// mappa, `(0, -1)`). `cameraTransform` è la posa in quell'istante.
    static func aligned(originPlanPoint: CGPoint,
                        cameraTransform: simd_float4x4,
                        facingPlanDirection: CGPoint,
                        pointsPerMetre: Double) -> ARPlanAligner {
        let forward = cameraForwardOnFloor(cameraTransform)
        let phiForward = atan2(Double(forward.x), Double(-forward.y))
        let psiForward = atan2(Double(facingPlanDirection.x),
                               Double(-facingPlanDirection.y))
        let position = cameraTransform.columns.3
        return ARPlanAligner(
            originPlanPoint: originPlanPoint,
            originARPosition: SIMD3(position.x, position.y, position.z),
            angleOffset: psiForward - phiForward,
            pointsPerMetre: pointsPerMetre
        )
    }

    // MARK: Proiezioni

    /// La posizione AR → punto sulla pianta, in punti canvas.
    func planPoint(for arPosition: SIMD3<Float>) -> CGPoint {
        let dx = Double(arPosition.x - originARPosition.x)
        let dz = Double(arPosition.z - originARPosition.z)
        let distance = (dx * dx + dz * dz).squareRoot()
        guard distance > 0 else { return originPlanPoint }
        let phi = atan2(dx, -dz)
        let psi = phi + angleOffset
        let points = distance * pointsPerMetre
        return CGPoint(x: originPlanPoint.x + CGFloat(sin(psi) * points),
                       y: originPlanPoint.y - CGFloat(cos(psi) * points))
    }

    /// La direzione dello sguardo sulla pianta: versore canvas (y in giù),
    /// per il cono/freccia dell'utente sulla mini-mappa.
    func planHeading(for cameraTransform: simd_float4x4) -> CGVector {
        let forward = Self.cameraForwardOnFloor(cameraTransform)
        let phi = atan2(Double(forward.x), Double(-forward.y))
        let psi = phi + angleOffset
        return CGVector(dx: CGFloat(sin(psi)), dy: CGFloat(-cos(psi)))
    }

    // MARK: Interni

    /// Il forward della camera proiettato sul pavimento, come (x, z) unitario.
    /// Ritorna (0, −1) («avanti» convenzionale) se la camera guarda in
    /// verticale e la proiezione degenera.
    static func cameraForwardOnFloor(_ transform: simd_float4x4) -> SIMD2<Float> {
        // ⚠️ columns.2 è +z = DIETRO la camera: il forward è il suo opposto.
        let forward = SIMD2(-transform.columns.2.x, -transform.columns.2.z)
        let length = simd_length(forward)
        guard length > 1e-4 else { return SIMD2(0, -1) }
        return forward / length
    }
}
