import Foundation
import CoreGraphics
import simd

// MARK: - FloorplanExtruder

/// Trasforma un `DrawingDocument` in facce nello spazio.
///
/// **Puro e senza rendering**: entra il documento, escono quadrilateri con le
/// loro coordinate in metri. È la parte che serve identica sia a una proiezione
/// disegnata su `Canvas` sia a un motore 3D vero — quindi scriverla adesso non è
/// lavoro speso per una strada sola.
///
/// L'unica cosa che il piano non può contenere sono le **altezze**: un disegno
/// in pianta non sa quanto è alto un soffitto. Sono parametri, ed è lo stesso
/// motivo per cui un'app concorrente chiede l'altezza del soffitto prima di
/// generare il modello.
enum FloorplanExtruder {

    struct Heights {
        var ceiling: Double = 2.4
        /// Architrave delle porte: sopra resta muro.
        var doorTop: Double = 2.1
        /// Finestre: davanzale e architrave.
        var windowBottom: Double = 0.9
        var windowTop: Double = 2.2
        /// Il perimetro di un balcone è un **parapetto**, non un muro: si
        /// affaccia, non chiude. Estruderlo fino al soffitto trasformava una
        /// stanza aperta in uno stanzino cieco.
        var parapet: Double = 1.05

        func top(for kind: WallKind) -> Double {
            kind == .balcony ? parapet : ceiling
        }
    }

    /// Un quadrilatero in metri. Le facce sono piane per costruzione, quindi
    /// quattro punti bastano e non serve una mesh.
    struct Face {
        enum Kind {
            case floor
            /// Faccia verticale di un muro.
            case wallSide
            /// Faccia superiore: prende più luce, ed è ciò che dà il volume.
            case wallTop
            /// Il vetro di una finestra. Senza, una finestra e una porta sono
            /// lo stesso buco e non si distinguono.
            case glass
            /// Il telaio che contorna un'apertura. Senza, un vano è un buco
            /// come un altro: è la cornice a dire che lì c'è una porta.
            case frame
            /// Il battente di una porta, pieno. Il vetro può permettersi di
            /// essere trasparente perché dà sull'esterno; una porta dà sulla
            /// stanza accanto, e trasparente ne prenderebbe il colore.
            case doorLeaf
            /// Parapetto di un balcone: basso **e** diverso, altrimenti resta
            /// un muro tagliato a metà.
            case parapetSide
            case parapetTop
            /// Velatura di stato appoggiata alla facciata interna di un muro.
        ///
        /// È geometria a sé e non una tinta sul muro: un colore moltiplicato sul
        /// materiale non può sfumare, una superficie traslucida sì. E la
        /// costruisce l'estrusore perché è l'unico che sa **da che parte** guarda
        /// una facciata — nel renderer il verso della normale non è affidabile.
        case wallGlow
        /// L'ombra di contatto alla base di un muro, e quella che un arredo
        /// lascia sul pavimento.
        ///
        /// Dentro casa **non entra il sole**: i muri lo fermano, e tutta la luce
        /// interna arriva da direzionali senza ombra. Senza queste due velature
        /// nessun oggetto tocca il pavimento e la stanza sembra un collage.
        /// Sono geometria e non ombre vere perché un'ombra vera qui costerebbe
        /// una seconda shadow map su tutta la scena, e darebbe una seconda
        /// direzione d'ombra che in un interno non esiste.
        case wallContact
        case groundContact
        /// La tapparella calata davanti a un vano. Sta **fuori dal muro** come
        /// nella realtà: scorre in un cassonetto esterno, non dentro la stanza.
        case shutter
        /// Specchiatura in rilievo sull'anta di una porta.
        case doorPanel
        /// Rosetta e leva. È l'unico dettaglio del modello alla scala della mano,
        /// e per questo è il primo che si riconosce.
        case handle
        /// Un arredo. Porta la propria tinta, quando ne ha una.
            case furnitureSide
            case furnitureTop
        }
        var points: [SIMD3<Double>]
        var kind: Kind
        /// Indice nella palette delle stanze, solo per i pavimenti.
        var roomColorIndex: Int?
        /// Identità della stanza, per poterla selezionare toccando il pavimento.
        var roomID: UUID?
        var roomName: String?
        /// Materiale pavimento scelto nel Drawing Context, solo per le facce floor.
        var floorKind: FloorKind? = nil
        /// Tipo apertura, solo per pannelli/telai/vetri generati da opening.
        var openingKind: OpeningKind? = nil
        /// Quale apertura ha generato questa faccia. Serve a sapere che il sole
        /// non passa da un vetro che ha la tapparella giù: il tipo non basta,
        /// perché le finestre della casa sono tante e ognuna sta per conto suo.
        var openingID: UUID? = nil
        /// Tipo muro sorgente, utile per distinguere ingresso, interno e balcone.
        var wallKind: WallKind? = nil
        /// Lato apertura scelto nel 2D.
        var flipSide: Bool = false
        /// Tinta scelta dall'utente per questo arredo, se ne ha una.
        var tint: CGColor?
        /// Finitura render dell'arredo: resta nel 3D, non nello schema salvato.
        var furnitureMaterial: FurnitureMaterialStyle? = nil

        var centroid: SIMD3<Double> {
            points.reduce(.zero, +) / Double(points.count)
        }
    }

    // MARK: - Ingresso

    static func faces(from document: DrawingDocument,
                      heights: Heights = Heights(),
                      openOpeningIDs: Set<UUID> = [],
                      closedShutters: [UUID: Double] = [:],
                      televisionSpots: [SIMD2<Double>] = []) -> [Face] {
        var result: [Face] = []
        for area in document.roomAreas {
            result.append(contentsOf: floorFaces(area))
        }
        let physicalWalls = document.walls.filter(\.kind.rendersAsPhysicalWall)
        let joints = sharedEndpoints(of: physicalWalls)
        let balconies = balconyAreaIDs(in: document)
        for wall in physicalWalls {
            result.append(contentsOf: wallFaces(wall, in: document, heights: heights,
                                                joints: joints, openOpeningIDs: openOpeningIDs,
                                                closedShutters: closedShutters,
                                                balconyAreaIDs: balconies))
        }
        // Nell'ordine di disegno del documento, così i tappeti restano sotto
        // come già fanno in pianta.
        for item in document.furnitureDrawOrder {
            result.append(contentsOf: furnitureFaces(item, in: document,
                                                     televisionSpots: televisionSpots))
        }
        return result
    }

    // MARK: - Pavimenti

    private static func floorFaces(_ area: RoomArea) -> [Face] {
        let outline: [CGPoint] = {
            if let points = area.points, points.count >= 3 { return points }
            return [CGPoint(x: area.rect.minX, y: area.rect.minY),
                    CGPoint(x: area.rect.maxX, y: area.rect.minY),
                    CGPoint(x: area.rect.maxX, y: area.rect.maxY),
                    CGPoint(x: area.rect.minX, y: area.rect.maxY)]
        }()
        // Un poligono qualsiasi resta una faccia sola: il disegno lo riempie
        // come cammino chiuso, senza bisogno di triangolarlo.
        return [Face(points: outline.map { SIMD3(metres($0.x), metres($0.y), 0) },
                     kind: .floor,
                     roomColorIndex: area.colorIndex,
                     roomID: area.id,
                     roomName: area.name,
                     floorKind: area.floorKind,
                     tint: nil)]
    }

    // MARK: - Arredi

    /// Un arredo diventa **una o due scatole**.
    ///
    /// Il modello ha ingombri, non forme: estrudere il rettangolo dà una cassa,
    /// e una casa piena di casse non si legge. Due volumi sovrapposti bastano a
    /// far riconoscere un divano da un tavolo — seduta più schienale, materasso
    /// più testiera — e sono la differenza fra «un mobile» e «quel mobile».
    /// Modellarli davvero è un altro mestiere e non serve a questa vista.
    private static func furnitureFaces(_ item: FurnitureItem,
                                       in document: DrawingDocument,
                                       televisionSpots: [SIMD2<Double>] = []) -> [Face] {
        let kind = item.kind
        let tint = item.tintIndex.flatMap { index -> CGColor? in
            let tints = FurnitureTint.allCases
            guard index >= 0, index < tints.count else { return nil }
            return tints[index].darkCGColor
        }

        // Un tappeto è a terra: un volume, per quanto basso, farebbe ombra e
        // spigoli dove nella realtà non si inciampa.
        if kind == .rug {
            return [Face(points: corners(of: item, at: 0.002), kind: .furnitureTop,
                         roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                         furnitureMaterial: .fabric)]
        }

        // La macchia è **più larga dell'ingombro**: il nucleo resta nascosto
        // sotto il mobile e quel che si vede è solo la sfumatura che esce dai
        // bordi, che è esattamente ciò che fa un'ombra di contatto.
        var faces = [Face(points: corners(of: item, at: 0.004, scale: 1.5),
                          kind: .groundContact,
                          roomColorIndex: nil, roomID: nil, roomName: nil)]
        faces += memberFaces(item, kind: kind, tint: tint,
                             supportTop: supportTop(for: item, in: document),
                             televisionSpots: televisionSpots)
        return faces
    }

    /// La quota su cui questo mobile appoggia, se in pianta sta sopra un altro:
    /// e' il disegno a dire dove finisce il bancone, non una costante.
    private static func supportTop(for item: FurnitureItem,
                                   in document: DrawingDocument) -> Double? {
        document.furnitureItems
            .filter { $0.id != item.id && $0.kind != .rug && $0.rect.intersects(item.rect) }
            .map { height(of: $0.kind) }
            .max()
    }

    // MARK: - Arredi a membra

    /// Le tinte dei materiali da mobile: decise qui, membro per membro, e
    /// portate fino al renderer. Prima esisteva un beige solo.
    private static let woodDark = CGColor(red: 0.35, green: 0.28, blue: 0.22, alpha: 1)
    private static let woodTop = CGColor(red: 0.70, green: 0.57, blue: 0.42, alpha: 1)
    private static let fabricSoft = CGColor(red: 0.82, green: 0.78, blue: 0.72, alpha: 1)
    private static let linenLight = CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)
    /// Vetro nero di schermi e piani cottura: il nero pieno e' l'unico
    /// materiale che si riconosce anche da tre metri.
    private static let blackGlass = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    private static let stoneTop = CGColor(red: 0.46, green: 0.45, blue: 0.43, alpha: 1)
    private static let bookRed = CGColor(red: 0.55, green: 0.18, blue: 0.16, alpha: 1)
    private static let bookBlue = CGColor(red: 0.18, green: 0.30, blue: 0.52, alpha: 1)
    private static let bookGreen = CGColor(red: 0.22, green: 0.42, blue: 0.28, alpha: 1)
    private static let ceramicWhite = CGColor(red: 0.92, green: 0.92, blue: 0.88, alpha: 1)
    private static let applianceWhite = CGColor(red: 0.86, green: 0.88, blue: 0.88, alpha: 1)
    private static let chromeGrey = CGColor(red: 0.62, green: 0.64, blue: 0.65, alpha: 1)
    private static let showerGlass = CGColor(red: 0.70, green: 0.84, blue: 0.90, alpha: 0.65)
    /// I verdi del vivaio: due palchi di chioma con toni diversi, perche' una
    /// chioma monocolore torna a essere una scatola.
    private static let terracotta = CGColor(red: 0.66, green: 0.42, blue: 0.31, alpha: 1)
    private static let foliageDark = CGColor(red: 0.23, green: 0.36, blue: 0.22, alpha: 1)
    private static let foliageMid = CGColor(red: 0.30, green: 0.44, blue: 0.25, alpha: 1)
    private static let foliageLight = CGColor(red: 0.41, green: 0.53, blue: 0.30, alpha: 1)

    /// Il mobile per **membra**, non per cassa: un tavolo è un piano più
    /// quattro gambe, un divano una seduta fra due braccioli. Sono i volumi che
    /// l'occhio usa per riconoscere, e sotto luce vera una cassa piena si vede
    /// per quello che è.
    private static func memberFaces(_ item: FurnitureItem, kind: FurnitureKind,
                                    tint: CGColor?, supportTop: Double? = nil,
                                    televisionSpots: [SIMD2<Double>] = []) -> [Face] {
        let soft = tint ?? fabricSoft
        switch kind {
        case .diningTable, .generic:
            let top = height(of: kind)
            return slab(item, from: top - 0.05, to: top, tint: woodTop, material: .wood)
                + legs(item, to: top - 0.05, side: 0.055, inset: 0.06, tint: woodDark, material: .wood)
        case .chair:
            let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let seatHalf = SIMD2(max(0.12, half.x * 0.82), max(0.12, half.y * 0.78))
            let backDepth = min(0.09, half.y * 0.28)
            var faces = legs(item, to: 0.40, side: 0.03, inset: 0.055,
                             tint: woodDark, material: .wood)
            faces += subBox(item, centreOffset: SIMD2(0, half.y * 0.06),
                            half: seatHalf, from: 0.39, to: 0.49,
                            tint: soft, material: .fabric)
            faces += subBox(item, centreOffset: SIMD2(0, -half.y + backDepth / 2),
                            half: SIMD2(max(0.10, half.x * 0.72), backDepth / 2),
                            from: 0.48, to: 0.92, tint: soft, material: .fabric)
            faces += subBox(item, centreOffset: SIMD2(0, -half.y + backDepth / 2),
                            half: SIMD2(max(0.09, half.x * 0.64), backDepth / 2),
                            from: 0.92, to: 0.98, tint: linenLight, material: .fabric)
            return faces
        case .sofa, .armchair:
            let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let seatHalf = SIMD2(max(0.18, half.x * 0.84), max(0.16, half.y * 0.74))
            let backDepth = min(0.16, half.y * 0.30)
            let armWidth = min(kind == .armchair ? 0.11 : 0.13, half.x * 0.30)
            var faces = legs(item, to: 0.16, side: 0.045, inset: 0.08,
                             tint: woodDark, material: .wood)
            faces += subBox(item, centreOffset: SIMD2(0, half.y * 0.06),
                            half: seatHalf, from: 0.16, to: 0.43,
                            tint: soft, material: .fabric)
            faces += subBox(item, centreOffset: SIMD2(0, -half.y + backDepth / 2),
                            half: SIMD2(max(0.16, half.x * 0.88), backDepth / 2),
                            from: 0.34, to: 0.82, tint: soft, material: .fabric)
            // Braccioli: piu' stretti e staccati dalla cassa, cosi' non sembrano
            // due muri pieni attaccati a un blocco.
            for side in [-1.0, 1.0] {
                faces += subBox(item,
                                centreOffset: SIMD2(side * (half.x - armWidth / 2), 0),
                                half: SIMD2(armWidth / 2, max(0.14, half.y * 0.72)),
                                from: 0.24, to: 0.62, tint: soft, material: .fabric)
            }
            if kind == .sofa {
                let cushionCount = max(2, min(3, Int((half.x * 2 / 0.65).rounded())))
                let gap = 0.035
                let cushionWidth = (half.x * 1.64 - gap * Double(cushionCount - 1)) / Double(cushionCount)
                for index in 0..<cushionCount {
                    let x = -half.x * 0.82 + cushionWidth / 2
                        + Double(index) * (cushionWidth + gap)
                    faces += subBox(item, centreOffset: SIMD2(x, half.y * 0.10),
                                    half: SIMD2(cushionWidth / 2, max(0.12, half.y * 0.34)),
                                    from: 0.43, to: 0.49, tint: linenLight,
                                    material: .fabric)
                }
            }
            return faces
        case .wardrobe:
            // Le **colonne con le fughe** sono cio' che fa dire «armadio»
            // invece di «monolite»: le ante non serve disegnarle, bastano le
            // ombre nelle fessure.
            return columns(item, to: height(of: kind), moduleWidth: 0.55, tint: soft)
        case .bookcase:
            return bookcaseFaces(item, tint: tint ?? woodTop)
        case .kitchenCounter:
            // Basi a moduli sotto un top in pietra che corre intero: e' la
            // grammatica di qualunque cucina componibile.
            return columns(item, to: 0.85, moduleWidth: 0.60, tint: soft)
                + slab(item, from: 0.85, to: 0.90, tint: stoneTop, material: .stone)
        case .tvUnit:
            // Il mobile basso e **la TV nera sopra**, contro il lato muro: lo
            // schermo e' il pezzo che si riconosce, il mobile e' solo il piede.
            // ⚠️ Lo schermo sta a **+y locale**, non a -y come gli schienali:
            // il 2D disegna il mobile TV col muro dal lato opposto rispetto a
            // divani e letti, e con la convenzione degli schienali la TV usciva
            // rivolta alla parete.
            // ⚠️ Lo schermo sta a **minY locale**: e' dove lo disegna il 2D
            // (`DrawingCanvasContent`, riga della barra TV), la stessa
            // convenzione degli schienali. Niente piu' congetture sul verso:
            // le due viste combaciano per costruzione, e se la barra guarda il
            // muro sbagliato si ruota il mobile nell'editor — e' un dato.
            // ⚠️ **Comanda l'accessorio**: se una TV vera e' posata a meno di
            // un metro e mezzo, il mobile rinuncia al suo schermo decorativo e
            // resta il piede — due schermi affiancati erano «troppe TV».
            let tvCentre = SIMD2(metres(item.rect.midX), metres(item.rect.midY))
            let hasRealTV = televisionSpots.contains {
                simd_distance($0, tvCentre) < 1.5
            }
            let tvHalf = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let cabinet = boxFaces(item, from: 0, to: 0.45, tint: soft)
            guard !hasRealTV else { return cabinet }
            return cabinet
                + subBox(item,
                         centreOffset: SIMD2(0, -tvHalf.y + 0.05),
                         half: SIMD2(min(tvHalf.x * 0.85, 0.85), 0.022),
                         from: 0.55, to: 1.30, tint: blackGlass, material: .glass)
        case .inductionCooktop:
            // **Solo il vetro nero**, appoggiato al top della cucina: il piano
            // cottura in pianta sta sopra un bancone gia' disegnato, e dargli
            // un corpo proprio raddoppiava il mobile — una base grigia spessa
            // sotto due centimetri di vetro.
            // Il vetro appoggia su **cio' che sta sotto nel disegno**: la
            // costante 0,90 lo faceva volare sopra i piani piu' bassi e
            // sparire dentro quelli piu' alti. Se sotto non c'e' niente, torna
            // il corpo — un piano cottura orfano non puo' galleggiare.
            let hobHalf = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let glassHalf = SIMD2(hobHalf.x * 0.92, hobHalf.y * 0.88)
            if let supportTop {
                return subBox(item, centreOffset: .zero, half: glassHalf,
                              from: supportTop + 0.004, to: supportTop + 0.038,
                              tint: blackGlass, material: .glass)
            }
            return boxFaces(item, from: 0, to: 0.88, tint: soft)
                + subBox(item, centreOffset: .zero, half: glassHalf,
                         from: 0.88, to: 0.915, tint: blackGlass, material: .glass)
        case .toilet:
            return toiletFaces(item)
        case .washingMachine:
            return washingMachineFaces(item)
        case .shower:
            return showerFaces(item)
        case .plant:
            // Vaso svasato in terracotta, fusto e chioma a palla low-poly:
            // tamburi a otto lati, non scatole — le scatole verdi impilate
            // erano Minecraft, parola dell'utente.
            let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let radius = min(half.x, half.y)
            var faces = drum(item, from: 0, bottomRadius: radius * 0.26,
                             to: 0.26, topRadius: radius * 0.36,
                             tint: terracotta, material: .stone)
            faces += drum(item, from: 0.26, bottomRadius: radius * 0.38,
                          to: 0.32, topRadius: radius * 0.38,
                          tint: terracotta, material: .stone)
            faces += drum(item, sides: 6, from: 0.32, bottomRadius: 0.022,
                          to: 0.58, topRadius: 0.018, tint: woodDark, material: .wood)
            faces += drum(item, from: 0.52, bottomRadius: radius * 0.50,
                          to: 0.78, topRadius: radius * 0.88, tint: foliageDark)
            faces += drum(item, from: 0.78, bottomRadius: radius * 0.88,
                          to: 1.06, topRadius: radius * 0.62, tint: foliageMid)
            faces += drum(item, from: 1.06, bottomRadius: radius * 0.62,
                          to: 1.26, topRadius: radius * 0.20, tint: foliageLight)
            return faces
        case .tree:
            // Tronco e chioma a fusi che si gonfiano e si stringono: la
            // silhouette dell'albero in low-poly, non una pila di cubi.
            let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let radius = min(half.x, half.y)
            var faces = drum(item, sides: 6, from: 0, bottomRadius: 0.11,
                             to: 1.25, topRadius: 0.085, tint: woodDark, material: .wood)
            faces += drum(item, from: 1.10, bottomRadius: radius * 0.52,
                          to: 1.95, topRadius: radius * 0.95, tint: foliageDark)
            faces += drum(item, from: 1.95, bottomRadius: radius * 0.95,
                          to: 2.75, topRadius: radius * 0.66, tint: foliageMid)
            faces += drum(item, from: 2.75, bottomRadius: radius * 0.66,
                          to: 3.35, topRadius: radius * 0.22, tint: foliageLight)
            return faces
        case .hedge:
            // La siepe squadrata e' davvero una scatola — ma verde, e senza
            // trame che facciano griglia.
            return boxFaces(item, from: 0, to: height(of: kind),
                            tint: foliageMid)
        case .bed:
            // Giroletto scuro, materasso chiaro, cuscini alla testata: tre
            // membri che dicono «letto» meglio di qualunque cassa.
            var faces = boxFaces(item, from: 0, to: 0.16, tint: woodDark, material: .wood)
            faces += boxFaces(item, from: 0.16, to: 0.50, tint: linenLight, fraction: 0.985,
                              placement: .centred, material: .fabric)
            if let back = backrest(of: kind) {
                faces += boxFaces(item, from: back.from, to: back.to,
                                  tint: woodDark, fraction: back.depth, placement: back.placement,
                                  material: .wood)
            }
            let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
            let pillowHalf = SIMD2(min(0.24, half.x * 0.34), 0.15)
            for side in [-1.0, 1.0] {
                faces += subBox(item,
                                centreOffset: SIMD2(side * half.x * 0.45,
                                                    -half.y + 0.12 + pillowHalf.y),
                                half: pillowHalf,
                                from: 0.50, to: 0.61, tint: soft, material: .fabric)
            }
            return faces
        default:
            var faces = boxFaces(item, from: 0, to: height(of: kind), tint: tint)
            if let back = backrest(of: kind) {
                faces += boxFaces(item, from: back.from, to: back.to,
                                  tint: tint, fraction: back.depth, placement: back.placement)
            }
            return faces
        }
    }

    /// Colonne affiancate con una fuga fra l'una e l'altra: la larghezza del
    /// modulo comanda, il conto delle colonne segue il mobile.
    private static func columns(_ item: FurnitureItem, to top: Double,
                                moduleWidth: Double, tint: CGColor?,
                                material: FurnitureMaterialStyle = .plain) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let width = half.x * 2
        let count = max(1, Int((width / moduleWidth).rounded()))
        let gap = 0.016
        let columnWidth = (width - gap * Double(count - 1)) / Double(count)
        guard columnWidth > 0.05 else {
            return boxFaces(item, from: 0, to: top, tint: tint, material: material)
        }

        var faces: [Face] = []
        for index in 0..<count {
            let centreX = -half.x + columnWidth / 2
                + Double(index) * (columnWidth + gap)
            faces += subBox(item,
                            centreOffset: SIMD2(centreX, 0),
                            half: SIMD2(columnWidth / 2, half.y),
                            from: 0, to: top, tint: tint, material: material)
        }
        return faces
    }

    /// Libreria alta: montanti e ripiani leggibili anche da lontano, più una
    /// fila di libri sul fronte. Il volume resta sottile come un mobile da muro,
    /// non una cassa profonda come un armadio.
    private static func bookcaseFaces(_ item: FurnitureItem, tint: CGColor?) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let top = height(of: .bookcase)
        let frame = tint ?? woodTop
        let side = min(0.055, half.x * 0.16)
        let shelfThickness = 0.045
        var faces: [Face] = []

        faces += subBox(item, centreOffset: SIMD2(0, half.y - min(0.035, half.y * 0.32)),
                        half: SIMD2(max(0.08, half.x), min(0.035, half.y * 0.32)),
                        from: 0, to: top, tint: woodDark, material: .wood)
        for sideSign in [-1.0, 1.0] {
            faces += subBox(item,
                            centreOffset: SIMD2(sideSign * (half.x - side / 2), 0),
                            half: SIMD2(side / 2, half.y),
                            from: 0, to: top, tint: frame, material: .wood)
        }

        let shelfCount = 5
        for index in 0...shelfCount {
            let z = Double(index) / Double(shelfCount) * (top - shelfThickness)
            faces += subBox(item, centreOffset: .zero,
                            half: SIMD2(max(0.08, half.x), min(half.y, 0.035)),
                            from: z, to: z + shelfThickness,
                            tint: frame, material: .wood)
        }

        let moduleCount = max(3, min(7, Int((half.x * 2 / 0.22).rounded())))
        let bookWidth = (half.x * 1.72) / Double(moduleCount)
        let bookColors = [bookRed, bookBlue, bookGreen, linenLight]
        for row in 0..<shelfCount {
            let bottom = 0.12 + Double(row) * ((top - 0.25) / Double(shelfCount))
            let bookHeight = min(0.28, (top / Double(shelfCount)) * 0.58)
            for column in 0..<moduleCount {
                let x = -half.x * 0.86 + bookWidth / 2 + Double(column) * bookWidth
                let color = bookColors[(row + column) % bookColors.count]
                faces += subBox(item,
                                centreOffset: SIMD2(x, -half.y + min(0.09, half.y * 0.55)),
                                half: SIMD2(bookWidth * 0.34, min(0.025, half.y * 0.24)),
                                from: bottom, to: bottom + bookHeight,
                                tint: color, material: .plain)
            }
        }

        return faces
    }

    /// WC in tre segni riconoscibili: cassetta a muro, tazza a gradini e foro
    /// scuro. Non e' rotondo, ma da camera alta legge come sanitario e non come
    /// mobiletto bianco.
    private static func toiletFaces(_ item: FurnitureItem) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let tankDepth = min(0.20, half.y * 0.38)
        var faces: [Face] = []

        faces += subBox(item,
                        centreOffset: SIMD2(0, -half.y + tankDepth / 2),
                        half: SIMD2(max(0.16, half.x * 0.62), tankDepth / 2),
                        from: 0.36, to: 0.82, tint: ceramicWhite, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(0, -half.y + tankDepth * 0.45),
                        half: SIMD2(max(0.06, half.x * 0.16), min(0.018, tankDepth * 0.18)),
                        from: 0.825, to: 0.845, tint: chromeGrey, material: .plain)

        faces += subBox(item,
                        centreOffset: SIMD2(0, half.y * 0.10),
                        half: SIMD2(max(0.10, half.x * 0.26), max(0.12, half.y * 0.26)),
                        from: 0, to: 0.24, tint: ceramicWhite, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(0, half.y * 0.12),
                        half: SIMD2(max(0.16, half.x * 0.48), max(0.18, half.y * 0.42)),
                        from: 0.24, to: 0.38, tint: ceramicWhite, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(0, half.y * 0.12),
                        half: SIMD2(max(0.14, half.x * 0.40), max(0.14, half.y * 0.32)),
                        from: 0.385, to: 0.43, tint: linenLight, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(0, half.y * 0.13),
                        half: SIMD2(max(0.07, half.x * 0.20), max(0.07, half.y * 0.17)),
                        from: 0.433, to: 0.446, tint: blackGlass, material: .glass)

        return faces
    }

    /// Lavatrice: corpo pieno, fascia comandi e oblò scuro frontale. I dettagli
    /// sono sottili ma rialzati, cosi' con la luce radente non spariscono.
    private static func washingMachineFaces(_ item: FurnitureItem) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let frontY = -half.y + min(0.022, half.y * 0.12)
        let doorHalf = SIMD2(max(0.11, half.x * 0.32), min(0.026, half.y * 0.18))
        var faces = boxFaces(item, from: 0, to: 0.84, tint: applianceWhite, material: .plain)

        faces += subBox(item,
                        centreOffset: SIMD2(0, frontY),
                        half: SIMD2(max(0.18, half.x * 0.72), min(0.020, half.y * 0.14)),
                        from: 0.66, to: 0.77, tint: chromeGrey, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(0, frontY - 0.002),
                        half: doorHalf,
                        from: 0.30, to: 0.60, tint: blackGlass, material: .glass)
        faces += subBox(item,
                        centreOffset: SIMD2(half.x * 0.42, frontY - 0.004),
                        half: SIMD2(max(0.035, half.x * 0.09), min(0.018, half.y * 0.12)),
                        from: 0.69, to: 0.735, tint: blackGlass, material: .glass)
        faces += subBox(item,
                        centreOffset: SIMD2(-half.x * 0.34, frontY - 0.004),
                        half: SIMD2(max(0.06, half.x * 0.15), min(0.014, half.y * 0.10)),
                        from: 0.70, to: 0.725, tint: blackGlass, material: .glass)

        return faces
    }

    /// Doccia: piatto basso, due/quattro vetri e colonna. L'oggetto rimane
    /// leggero: se diventasse un cubo pieno sembrerebbe un ripostiglio.
    private static func showerFaces(_ item: FurnitureItem) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let rail = min(0.035, min(half.x, half.y) * 0.16)
        var faces: [Face] = []

        faces += subBox(item, centreOffset: .zero,
                        half: SIMD2(max(0.16, half.x * 0.92), max(0.16, half.y * 0.92)),
                        from: 0, to: 0.10, tint: ceramicWhite, material: .plain)
        faces += subBox(item, centreOffset: .zero,
                        half: SIMD2(max(0.11, half.x * 0.62), max(0.11, half.y * 0.62)),
                        from: 0.105, to: 0.125, tint: chromeGrey, material: .plain)

        let glassHeight = 1.95
        for side in [-1.0, 1.0] {
            faces += subBox(item,
                            centreOffset: SIMD2(side * (half.x - rail / 2), 0),
                            half: SIMD2(rail / 2, max(0.14, half.y * 0.92)),
                            from: 0.10, to: glassHeight,
                            tint: showerGlass, material: .glass)
            faces += subBox(item,
                            centreOffset: SIMD2(0, side * (half.y - rail / 2)),
                            half: SIMD2(max(0.14, half.x * 0.92), rail / 2),
                            from: 0.10, to: glassHeight,
                            tint: showerGlass, material: .glass)
        }

        faces += subBox(item,
                        centreOffset: SIMD2(-half.x + rail * 1.5, -half.y + rail * 1.5),
                        half: SIMD2(rail, rail),
                        from: 0.10, to: 1.90, tint: chromeGrey, material: .plain)
        faces += subBox(item,
                        centreOffset: SIMD2(-half.x + rail * 2.8, -half.y + rail * 1.5),
                        half: SIMD2(max(0.045, half.x * 0.12), rail / 2),
                        from: 1.72, to: 1.78, tint: chromeGrey, material: .plain)

        return faces
    }

    /// Un piano a tutta pianta fra due quote.
    private static func slab(_ item: FurnitureItem, from bottom: Double, to top: Double,
                             tint: CGColor?,
                             material: FurnitureMaterialStyle = .plain) -> [Face] {
        boxFaces(item, from: bottom, to: top, tint: tint, material: material)
    }

    /// Quattro gambe agli angoli, rientrate dal bordo.
    private static func legs(_ item: FurnitureItem, to top: Double, side: Double,
                             inset: Double, tint: CGColor?,
                             material: FurnitureMaterialStyle = .plain) -> [Face] {
        let half = SIMD2(metres(item.rect.width) / 2, metres(item.rect.height) / 2)
        let offset = SIMD2(max(side / 2, half.x - inset - side / 2),
                           max(side / 2, half.y - inset - side / 2))
        var faces: [Face] = []
        for dx in [-1.0, 1.0] {
            for dy in [-1.0, 1.0] {
                faces += subBox(item,
                                centreOffset: SIMD2(dx * offset.x, dy * offset.y),
                                half: SIMD2(side / 2, side / 2),
                                from: 0, to: top, tint: tint, material: material)
            }
        }
        return faces
    }

    /// Un tamburo a piu' lati fra due quote, con raggi diversi in basso e in
    /// alto: il mattone delle forme tonde — vasi svasati, chiome, fusti —
    /// senza uscire dalla geometria a facce. Otto lati bastano a dire
    /// «rotondo» nel linguaggio low-poly della scena.
    private static func drum(_ item: FurnitureItem, centreOffset: SIMD2<Double> = .zero,
                             sides: Int = 8,
                             from bottom: Double, bottomRadius: Double,
                             to top: Double, topRadius: Double,
                             tint: CGColor?, material: FurnitureMaterialStyle = .plain) -> [Face] {
        guard top > bottom else { return [] }
        let rect = item.rect
        let centre = SIMD2(metres(rect.midX), metres(rect.midY))
        let angle = item.rotationDegrees * .pi / 180
        func ring(at z: Double, radius: Double) -> [SIMD3<Double>] {
            (0..<sides).map { index in
                let theta = (Double(index) + 0.5) / Double(sides) * 2 * .pi
                let local = SIMD2(cos(theta) * radius + centreOffset.x,
                                  sin(theta) * radius + centreOffset.y)
                let x = local.x * cos(angle) - local.y * sin(angle)
                let y = local.x * sin(angle) + local.y * cos(angle)
                return SIMD3(centre.x + x, centre.y + y, z)
            }
        }
        let low = ring(at: bottom, radius: bottomRadius)
        let high = ring(at: top, radius: max(topRadius, 0.005))
        var faces = [Face(points: high, kind: .furnitureTop,
                          roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                          furnitureMaterial: material)]
        for index in 0..<sides {
            let next = (index + 1) % sides
            faces.append(Face(points: [low[index], low[next], high[next], high[index]],
                              kind: .furnitureSide,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                              furnitureMaterial: material))
        }
        return faces
    }

    /// Una scatola in coordinate **locali** del mobile, ruotata come lui.
    private static func subBox(_ item: FurnitureItem, centreOffset: SIMD2<Double>,
                               half: SIMD2<Double>, from bottom: Double, to top: Double,
                               tint: CGColor?,
                               material: FurnitureMaterialStyle = .plain) -> [Face] {
        guard top > bottom else { return [] }
        func ring(at z: Double) -> [SIMD3<Double>] {
            let rect = item.rect
            let centre = SIMD2(metres(rect.midX), metres(rect.midY))
            let angle = item.rotationDegrees * .pi / 180
            let local = [SIMD2(centreOffset.x - half.x, centreOffset.y - half.y),
                         SIMD2(centreOffset.x + half.x, centreOffset.y - half.y),
                         SIMD2(centreOffset.x + half.x, centreOffset.y + half.y),
                         SIMD2(centreOffset.x - half.x, centreOffset.y + half.y)]
            return local.map { point in
                let x = point.x * cos(angle) - point.y * sin(angle)
                let y = point.x * sin(angle) + point.y * cos(angle)
                return SIMD3(centre.x + x, centre.y + y, z)
            }
        }
        let low = ring(at: bottom)
        let high = ring(at: top)
        var faces = [Face(points: high, kind: .furnitureTop,
                          roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                          furnitureMaterial: material)]
        for index in 0..<4 {
            let next = (index + 1) % 4
            faces.append(Face(points: [low[index], low[next], high[next], high[index]],
                              kind: .furnitureSide,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                              furnitureMaterial: material))
        }
        return faces
    }

    /// Altezze plausibili, non misurate: servono a distinguere un tavolo da un
    /// armadio a colpo d'occhio, non a fare un computo metrico.
    private static func height(of kind: FurnitureKind) -> Double {
        switch kind {
        case .sofa, .armchair:      0.42
        case .chair:                0.45
        case .diningTable:          0.75
        case .bed:                  0.50
        case .wardrobe:             2.10
        case .bookcase:             2.15
        case .toilet:               0.40
        case .sink, .kitchenSink:   0.85
        case .inductionCooktop:     0.90
        case .washingMachine:       0.85
        case .bathtub:              0.55
        case .shower:               0.10
        case .kitchenCounter:       0.90
        case .tvUnit:               0.45
        case .plant:                0.70
        case .stairs:               0.60
        case .spiralStairs:         2.20
        case .tree:                 2.20
        case .hedge:                0.90
        case .rug:                  0.00
        case .generic:              0.75
        }
    }

    /// Da che parte della profondità sta il volume secondario.
    ///
    /// ⚠️ Il 2D disegna **sempre** schienali, testiere e cassette contro `minY`,
    /// cioè in alto sul rettangolo — sulla tela la y cresce verso il basso. Il
    /// 3D li costruiva dal lato opposto, quindi ogni divano, poltrona, sedia,
    /// letto e water usciva ruotato di mezzo giro. In pianta non si nota, perché
    /// la sagoma è quasi simmetrica; in volume si vede subito, perché ci si
    /// siede rivolti al muro.
    enum Placement {
        /// Contro il lato testa, dove il 2D disegna lo schienale.
        case head
        /// Centrato: chiome e volumi che un davanti non ce l'hanno.
        case centred
    }

    /// Il secondo volume: schienale, testiera, cassetta, chioma. `fraction` è
    /// quanta parte della profondità occupa.
    private static func backrest(of kind: FurnitureKind) -> (from: Double, to: Double, depth: Double, placement: Placement)? {
        switch kind {
        case .sofa, .armchair: (0.42, 0.82, 0.30, .head)
        case .chair:           (0.45, 0.92, 0.22, .head)
        case .bed:             (0.50, 1.00, 0.10, .head)
        case .toilet:          (0.40, 0.78, 0.30, .head)
        case .shower:          (0.10, 2.00, 1.00, .centred)
        default:               nil
        }
    }

    /// I quattro angoli del rettangolo, ruotati come nel disegno.
    private static func corners(of item: FurnitureItem, at z: Double,
                                fraction: Double = 1,
                                placement: Placement = .centred,
                                scale: Double = 1) -> [SIMD3<Double>] {
        let rect = item.rect
        let centre = SIMD2(metres(rect.midX), metres(rect.midY))
        let half = SIMD2(metres(rect.width) / 2 * scale, metres(rect.height) / 2 * scale)

        // Il volume secondario occupa una fetta lungo la profondità, non tutto
        // il rettangolo: uno schienale largo quanto il divano è un muro.
        let depth = half.y * 2 * fraction
        let (y0, y1): (Double, Double) = switch placement {
        case .head:    (-half.y, -half.y + depth)
        case .centred: (-depth / 2, depth / 2)
        }

        let local = [SIMD2(-half.x, y0), SIMD2(half.x, y0), SIMD2(half.x, y1), SIMD2(-half.x, y1)]
        let angle = item.rotationDegrees * .pi / 180
        return local.map { point in
            let x = point.x * cos(angle) - point.y * sin(angle)
            let y = point.x * sin(angle) + point.y * cos(angle)
            return SIMD3(centre.x + x, centre.y + y, z)
        }
    }

    private static func boxFaces(_ item: FurnitureItem, from bottom: Double, to top: Double,
                                 tint: CGColor?, fraction: Double = 1,
                                 placement: Placement = .centred,
                                 material: FurnitureMaterialStyle = .plain) -> [Face] {
        guard top > bottom else { return [] }
        let low = corners(of: item, at: bottom, fraction: fraction, placement: placement)
        let high = corners(of: item, at: top, fraction: fraction, placement: placement)
        var faces = [Face(points: high, kind: .furnitureTop,
                          roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                          furnitureMaterial: material)]
        for index in 0..<4 {
            let next = (index + 1) % 4
            faces.append(Face(points: [low[index], low[next], high[next], high[index]],
                              kind: .furnitureSide,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint,
                              furnitureMaterial: material))
        }
        return faces
    }

    // MARK: - Muri

    /// Un muro diventa una scatola per ogni tratto **pieno**.
    ///
    /// I vani non si bucano: si evitano. Si lavora in una dimensione lungo il
    /// muro, si tolgono gli intervalli occupati dalle aperture, e di ogni tratto
    /// rimasto si costruisce un solido. Sopra una porta e sotto una finestra il
    /// muro c'è, quindi quei pezzi tornano come tratti a quota diversa.
    private static func wallFaces(_ wall: WallSegment,
                                  in document: DrawingDocument,
                                  heights: Heights,
                                  joints: Set<GridKey>,
                                  openOpeningIDs: Set<UUID>,
                                  closedShutters: [UUID: Double],
                                  balconyAreaIDs: Set<UUID> = []) -> [Face] {
        let start = SIMD2(metres(wall.start.x), metres(wall.start.y))
        let end   = SIMD2(metres(wall.end.x), metres(wall.end.y))
        let length = simd_distance(start, end)
        guard length > 0.01 else { return [] }

        let isParapet = wall.kind == .balcony
        // Un parapetto è più sottile di un muro portante: tenerlo allo stesso
        // spessore lo faceva sembrare un muro segato a mezz'altezza.
        let thickness = metres(DrawingDocument.wallWidth(for: wall.kind)) * (isParapet ? 0.5 : 1)
        let wallTop = heights.top(for: wall.kind)
        let axis = simd_normalize(end - start)

        // Angoli **lisci**: un muro che ne incontra un altro sborda di mezzo
        // spessore, così le due scatole si compenetrano e la tacca fra loro
        // sparisce. Senza, ai vertici restano i tappi in vista.
        //
        // ⚠️ Lo sbordo è una **coda**, non un allungamento del muro: le
        // aperture hanno `t` normalizzato sulla lunghezza vera, quindi
        // allungare il muro prima di collocarle le farebbe scivolare tutte
        // verso i bordi. Si calcolano sulla misura originale e si sborda solo
        // il primo e l'ultimo tratto pieno.
        let headOverhang = joints.contains(GridKey(start)) ? thickness / 2 : 0
        let tailOverhang = joints.contains(GridKey(end)) ? thickness / 2 : 0
        let openings = document.openings
            .filter { $0.wallID == wall.id }
            .sorted { $0.t < $1.t }

        // Tratti pieni: (da, a) lungo il muro, con la loro fascia verticale.
        var spans: [(from: Double, to: Double, bottom: Double, top: Double)] = []
        /// I vani, che poi `FloorplanOpeningBuilder` riempie di infisso.
        var holes: [FloorplanOpeningBuilder.Opening] = []
        // Un tratto pieno più corto dello spessore del muro non è un muro: è una
        // pila. E se tocca un estremo si prende anche la coda di giunzione, che
        // lo spinge **fuori** dallo spigolo — in pianta è invisibile perché la
        // linea del muro resta continua, in volume diventa un pilastro isolato
        // accanto alla casa. Si preferisce allargare l'apertura di quei pochi
        // centimetri: uno stipite spostato non lo nota nessuno, un pilastro sì.
        let minSpan = thickness
        var cursor = 0.0
        for opening in openings {
            let width = metres(opening.width)
            let centre = Double(opening.t) * length
            var from = max(0, centre - width / 2)
            var to   = min(length, centre + width / 2)
            // `from` sotto il cursore vuol dire aperture sovrapposte: agganciarlo
            // al cursore impedisce anche che questo torni indietro e riempia di
            // muro i vani già scavati.
            if from - cursor < minSpan { from = cursor }
            if length - to < minSpan { to = length }
            guard to > from else { continue }

            if from > cursor {
                spans.append((cursor, from, 0, wallTop))
            }
            switch opening.kind {
            case .window:
                spans.append((from, to, 0, min(heights.windowBottom, wallTop)))
                spans.append((from, to, heights.windowTop, wallTop))
                holes.append(.init(from: from, to: to,
                                   bottom: heights.windowBottom,
                                   top: min(heights.windowTop, wallTop),
                                   kind: opening.kind, flipSide: opening.flipSide,
                                   isOpen: openOpeningIDs.contains(opening.id),
                                   shutterClosed: closedShutters[opening.id],
                                   id: opening.id))
            case .door, .slidingDoor, .frenchDoor:
                spans.append((from, to, heights.doorTop, wallTop))
                // Una porta poggia a terra: niente traversa in basso, o
                // diventa un ostacolo che nella realtà non c'è.
                holes.append(.init(from: from, to: to,
                                   bottom: 0,
                                   top: min(heights.doorTop, wallTop),
                                   kind: opening.kind, flipSide: opening.flipSide,
                                   isOpen: openOpeningIDs.contains(opening.id),
                                   shutterClosed: closedShutters[opening.id],
                                   id: opening.id))
            }
            cursor = max(cursor, to)
        }
        if cursor < length {
            spans.append((cursor, length, 0, wallTop))
        }

        let unitNormal = SIMD2(-axis.y, axis.x)
        let normal = unitNormal * (thickness / 2)

        // A quale stanza **guarda** ogni facciata di muro.
        //
        // L'estrusore costruisce i muri senza sapere niente delle stanze, ma
        // qui l'informazione c'è tutta: si sa da che parte dell'asse sta la
        // faccia, e basta sporgersi di trenta centimetri in quella direzione
        // per vedere in che stanza si finisce. Senza questo non si può dare a
        // una stanza il colore del proprio stato: i muri sarebbero tutti uno.
        let roomPolygons = document.roomAreas.map { area in
            (id: area.id, points: area.effectivePoints.map {
                SIMD2(metres($0.x), metres($0.y))
            })
        }
        func facingRoom(of face: Face) -> UUID? {
            guard face.kind == .wallSide else { return nil }
            let centre = face.centroid
            let flat = SIMD2(centre.x, centre.y)
            let offset = simd_dot(flat - start, unitNormal)
            // I tappi di testa stanno sull'asse: sporgersi lungo la normale non
            // vuol dire niente, e indovinerebbero una stanza a caso.
            guard abs(offset) > thickness * 0.3 else { return nil }

            let probe = flat + unitNormal * (offset > 0 ? 0.30 : -0.30)
            return roomPolygons.first { contains(probe, $0.points) }?.id
        }

        var faces = spans.flatMap { span -> [Face] in
            guard span.to > span.from, span.top > span.bottom else { return [] }
            // Lo sbordo tocca solo chi arriva davvero all'estremità del muro.
            let from = span.from <= 0.0001 ? -headOverhang : span.from
            let to   = span.to >= length - 0.0001 ? length + tailOverhang : span.to
            let a = start + axis * from
            let b = start + axis * to
            return box(from: a, to: b, normal: normal,
                       bottom: span.bottom, top: span.top, isParapet: isParapet)
        }

        // Gli infissi non sono più adesivi sulla mezzeria: li costruisce un
        // builder dedicato come solidi dentro lo spessore del muro. Un parapetto
        // di balcone non ne ha, quindi non lo si disturba.
        var glows: [Face] = []
        for index in faces.indices {
            faces[index].roomID = facingRoom(of: faces[index])
            guard faces[index].roomID != nil else { continue }

            // Sei millimetri dentro la stanza: abbastanza da non litigare col
            // muro, troppo poco perché si veda lo stacco.
            let centre = faces[index].centroid
            let offset = simd_dot(SIMD2(centre.x, centre.y) - start, unitNormal)
            let push = unitNormal * (offset > 0 ? 0.006 : -0.006)
            var glow = faces[index]
            glow.kind = .wallGlow
            glow.points = faces[index].points.map { SIMD3($0.x + push.x, $0.y + push.y, $0.z) }
            glows.append(glow)

            // Tre millimetri: **davanti** al muro e **dietro** la velatura di
            // stato, così le due non litigano per lo stesso piano.
            if let contact = contactFace(faces[index],
                                         push: unitNormal * (offset > 0 ? 0.003 : -0.003)) {
                glows.append(contact)
            }
        }
        faces += glows

        if !isParapet {
            // Da che parte è «fuori»: si sporge di trenta centimetri da un lato
            // del muro e si guarda se si finisce in una stanza. Dedurlo dal verso
            // della normale non si può — l'estrusore non garantisce un
            // avvolgimento coerente, che è lo stesso motivo per cui le facce si
            // emettono da entrambi i lati.
            //
            // ⚠️ Non basta guardare **un** lato. Una portafinestra su un balcone
            // ha una stanza da tutte e due le parti — il soggiorno e il balcone,
            // che e' un'area come le altre — e fermandosi al primo controllo la
            // tapparella finiva **dentro il soggiorno**. Quando entrambi i lati
            // sono stanze vince il balcone, che e' l'unico posto dove una
            // copertura ha senso.
            let middle = start + axis * (length / 2)
            let reach = thickness / 2 + 0.30
            let ahead = roomPolygons.first { contains(middle + unitNormal * reach, $0.points) }?.id
            let behind = roomPolygons.first { contains(middle - unitNormal * reach, $0.points) }?.id

            let outward: SIMD2<Double>
            if ahead == nil {
                outward = unitNormal
            } else if behind == nil {
                outward = -unitNormal
            } else if let ahead, balconyAreaIDs.contains(ahead) {
                outward = unitNormal
            } else {
                outward = -unitNormal
            }
            // La stanza che questa apertura **serve**: quella dal lato opposto a
            // fuori. Serve alle finestre per sapere se di notte la loro stanza è
            // accesa, e viene gratis da un conto che stiamo già facendo.
            let servedRoom = outward == unitNormal ? behind : ahead

            let context = FloorplanOpeningBuilder.Wall(start: start,
                                                       axis: axis,
                                                       normal: unitNormal,
                                                       outward: outward,
                                                       thickness: thickness,
                                                       kind: wall.kind)
            for hole in holes {
                var produced = FloorplanOpeningBuilder.faces(for: hole, in: context)
                for index in produced.indices {
                    produced[index].openingID = hole.id
                    produced[index].roomID = servedRoom
                }
                faces += produced
            }
        }

        return faces
    }

    /// La fascia scura alla base di una facciata interna.
    ///
    /// Solo i tratti che **partono da terra**: sopra una porta il muro c'è, ma
    /// non tocca niente, e una velatura sospesa a due metri sarebbe una macchia
    /// senza causa.
    private static func contactFace(_ face: Face, push: SIMD2<Double>) -> Face? {
        guard face.kind == .wallSide else { return nil }
        let heights = face.points.map(\.z)
        guard let bottom = heights.min(), let top = heights.max(), bottom < 0.02 else { return nil }

        let base = face.points.filter { abs($0.z - bottom) < 0.001 }
        guard base.count == 2 else { return nil }
        let ceiling = min(top, bottom + contactHeight)

        var contact = face
        contact.kind = .wallContact
        contact.points = [
            SIMD3(base[0].x + push.x, base[0].y + push.y, bottom),
            SIMD3(base[1].x + push.x, base[1].y + push.y, bottom),
            SIMD3(base[1].x + push.x, base[1].y + push.y, ceiling),
            SIMD3(base[0].x + push.x, base[0].y + push.y, ceiling)
        ]
        return contact
    }

    /// Quanto sale la velatura di contatto. Oltre questa quota la luce ci
    /// arriva, e scurire diventa sporcare.
    static let contactHeight: Double = 0.34

    /// La forma di una tenda sopra un balcone, **senza il suo stato**.
    ///
    /// Geometria e stato viaggiano separati apposta: la corsa di una tenda
    /// cambia venti volte in venti secondi, e riestrudere la casa per ognuna
    /// era il costo che rendeva l'animazione a scatti. La forma si calcola una
    /// volta; quanto ne e' fuori lo decide il renderer, fotogramma per
    /// fotogramma.
    ///
    /// Si attacca al **lato di casa**, cioè al bordo del balcone che confina con
    /// un muro vero e non con un parapetto: è l'unico posto a cui una tenda
    /// possa essere fissata. Poi esce verso il vuoto e scende di trenta
    /// centimetri, che è la pendenza che la fa leggere come telo invece che come
    /// mensola.
    struct AwningGeometry: Equatable {
        var attachA: SIMD2<Double>
        var attachB: SIMD2<Double>
        /// Versore in pianta, dal lato di casa verso il vuoto.
        var inward: SIMD2<Double>
        var maxReach: Double
        /// Quota dell'attacco da terra.
        var attachHeight: Double
        /// Discesa del telo a tenda tutta stesa.
        var fullDrop: Double = 0.30
        /// Il cassonetto: ritirata resta questo, ed è ciò che si tocca per
        /// stenderla.
        var minReach: Double = 0.24
    }

    static func awningGeometry(over area: RoomArea,
                               in document: DrawingDocument,
                               heights: Heights = Heights()) -> AwningGeometry? {
        let polygon = area.effectivePoints.map { SIMD2(metres($0.x), metres($0.y)) }
        guard polygon.count >= 3 else { return nil }
        let solidWalls = document.walls.filter { $0.kind != .balcony && $0.kind.rendersAsPhysicalWall }
        guard !solidWalls.isEmpty else { return nil }

        // Il lato di casa: quello il cui punto medio è più vicino a un muro
        // pieno. Gli altri danno sul vuoto.
        var attachment: (a: SIMD2<Double>, b: SIMD2<Double>, distance: Double)?
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let middle = (a + b) / 2
            let distance = solidWalls.map { wall -> Double in
                let start = SIMD2(metres(wall.start.x), metres(wall.start.y))
                let end = SIMD2(metres(wall.end.x), metres(wall.end.y))
                let span = end - start
                let length = simd_length(span)
                guard length > 0.01 else { return .greatestFiniteMagnitude }
                let axis = span / length
                let t = max(0, min(length, simd_dot(middle - start, axis)))
                return simd_distance(middle, start + axis * t)
            }.min() ?? .greatestFiniteMagnitude

            if attachment == nil || distance < attachment!.distance {
                attachment = (a, b, distance)
            }
        }

        guard let attachment, attachment.distance < 0.6 else { return nil }

        let centre = polygon.reduce(SIMD2<Double>.zero, +) / Double(polygon.count)
        let middle = (attachment.a + attachment.b) / 2
        let toCentre = centre - middle
        let span = simd_length(toCentre)
        guard span > 0.3 else { return nil }

        // Esce fin quasi al parapetto opposto, ma non oltre due metri e mezzo:
        // una tenda più lunga di così in casa non c'è.
        return AwningGeometry(attachA: attachment.a,
                              attachB: attachment.b,
                              inward: toCentre / span,
                              maxReach: min(2.5, span * 1.8),
                              attachHeight: heights.ceiling - 0.10)
    }

    /// Le aree che sono **balconi**.
    ///
    /// Il disegno non ha un modo per dirlo: sa solo che certi muri sono
    /// parapetti. Ma un balcone e' proprio l'area che se li ritrova attorno,
    /// quindi la si riconosce da quelli invece di chiedere all'utente una cosa
    /// che ha gia' disegnato.
    static func balconyAreaIDs(in document: DrawingDocument) -> Set<UUID> {
        let parapets = document.walls.filter { $0.kind == .balcony }
        guard !parapets.isEmpty else { return [] }

        var result: Set<UUID> = []
        for area in document.roomAreas {
            let polygon = area.effectivePoints.map { SIMD2(metres($0.x), metres($0.y)) }
            guard polygon.count >= 3 else { continue }
            let centre = polygon.reduce(SIMD2<Double>.zero, +) / Double(polygon.count)

            let touched = parapets.contains { wall in
                let mid = SIMD2(metres((wall.start.x + wall.end.x) / 2),
                                metres((wall.start.y + wall.end.y) / 2))
                // Il punto medio di un parapetto sta **sul bordo** dell'area: si
                // sposta di un palmo verso il centro, o il risultato dipende da
                // quanto precisamente e' stata disegnata.
                let toCentre = centre - mid
                let distance = simd_length(toCentre)
                guard distance > 0.001 else { return true }
                return contains(mid + toCentre / distance * 0.15, polygon)
            }
            if touched { result.insert(area.id) }
        }
        return result
    }

    /// Le facce di un tratto di muro. Solo quelle **visibili** da un punto di
    /// vista alto: le due fiancate, la sommità e i due tappi. Il sotto non si
    /// vede mai e disegnarlo raddoppierebbe i poligoni per niente.
    private static func box(from a: SIMD2<Double>,
                            to b: SIMD2<Double>,
                            normal: SIMD2<Double>,
                            bottom: Double,
                            top: Double,
                            isParapet: Bool = false) -> [Face] {
        let sideKind: Face.Kind = isParapet ? .parapetSide : .wallSide
        let topKind: Face.Kind = isParapet ? .parapetTop : .wallTop
        let corners = [a + normal, b + normal, b - normal, a - normal]
        func face(_ indices: [Int], kind: Face.Kind, low: Double, high: Double) -> Face {
            let points = indices.enumerated().map { index, corner -> SIMD3<Double> in
                let z = index < 2 ? low : high
                return SIMD3(corners[corner].x, corners[corner].y, z)
            }
            return Face(points: points, kind: kind, roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil)
        }
        // Le due facciate lunghe si spezzano in tratti.
        //
        // ⚠️ Un muro non appartiene a **una** stanza: quello esterno in alto
        // corre lungo la cucina e poi lungo il soggiorno. Assegnandolo per
        // baricentro finiva tutto alla stanza in cui cadeva il centro, e
        // accendere la cucina accendeva anche mezzo soggiorno. Spezzato ogni
        // 35 cm, ogni tratto trova la propria stanza da solo.
        func longSide(from p0: SIMD2<Double>, to p1: SIMD2<Double>) -> [Face] {
            let count = max(1, Int((simd_distance(p0, p1) / 0.35).rounded()))
            return (0..<count).map { index in
                let t0 = Double(index) / Double(count)
                let t1 = Double(index + 1) / Double(count)
                let a = p0 + (p1 - p0) * t0
                let b = p0 + (p1 - p0) * t1
                return Face(points: [SIMD3(a.x, a.y, bottom), SIMD3(b.x, b.y, bottom),
                                     SIMD3(b.x, b.y, top), SIMD3(a.x, a.y, top)],
                            kind: sideKind,
                            roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil)
            }
        }

        var faces = [
            Face(points: corners.map { SIMD3($0.x, $0.y, top) }, kind: topKind,
                 roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil),
            face([1, 2, 2, 1], kind: sideKind, low: bottom, high: top),
            face([3, 0, 0, 3], kind: sideKind, low: bottom, high: top)
        ]
        faces += longSide(from: corners[0], to: corners[1])
        faces += longSide(from: corners[2], to: corners[3])
        // Il sotto di un muro che poggia a terra non si vede mai. Quello di un
        // architrave sopra una porta sì: è l'intradosso del vano, e senza si
        // guarda dentro un solido vuoto.
        if bottom > 0.001 {
            faces.append(Face(points: corners.map { SIMD3($0.x, $0.y, bottom) }, kind: sideKind,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil))
        }
        return faces
    }

    private static func contains(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// Coordinata arrotondata al millimetro: due estremi «uguali» in un disegno
    /// non lo sono mai al bit, e confrontarli per identità non troverebbe
    /// nessuna giunzione.
    struct GridKey: Hashable {
        let x: Int, y: Int
        init(_ point: SIMD2<Double>) {
            x = Int((point.x * 1000).rounded())
            y = Int((point.y * 1000).rounded())
        }
    }

    private static func sharedEndpoints(of walls: [WallSegment]) -> Set<GridKey> {
        var counts: [GridKey: Int] = [:]
        for wall in walls {
            for point in [wall.start, wall.end] {
                counts[GridKey(SIMD2(metres(point.x), metres(point.y))), default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private static func metres(_ points: CGFloat) -> Double {
        Double(points) / Double(DrawingDocument.ptsPerMeter)
    }
}
