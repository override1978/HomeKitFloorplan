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

        var centroid: SIMD3<Double> {
            points.reduce(.zero, +) / Double(points.count)
        }
    }

    // MARK: - Ingresso

    static func faces(from document: DrawingDocument,
                      heights: Heights = Heights(),
                      openOpeningIDs: Set<UUID> = [],
                      closedShutters: [UUID: Double] = [:]) -> [Face] {
        var result: [Face] = []
        for area in document.roomAreas {
            result.append(contentsOf: floorFaces(area))
        }
        let joints = sharedEndpoints(of: document.walls)
        let balconies = balconyAreaIDs(in: document)
        for wall in document.walls {
            result.append(contentsOf: wallFaces(wall, in: document, heights: heights,
                                                joints: joints, openOpeningIDs: openOpeningIDs,
                                                closedShutters: closedShutters,
                                                balconyAreaIDs: balconies))
        }
        // Nell'ordine di disegno del documento, così i tappeti restano sotto
        // come già fanno in pianta.
        for item in document.furnitureDrawOrder {
            result.append(contentsOf: furnitureFaces(item))
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
    private static func furnitureFaces(_ item: FurnitureItem) -> [Face] {
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
                         roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint)]
        }

        // La macchia è **più larga dell'ingombro**: il nucleo resta nascosto
        // sotto il mobile e quel che si vede è solo la sfumatura che esce dai
        // bordi, che è esattamente ciò che fa un'ombra di contatto.
        var faces = [Face(points: corners(of: item, at: 0.004, scale: 1.5),
                          kind: .groundContact,
                          roomColorIndex: nil, roomID: nil, roomName: nil)]
        faces += boxFaces(item, from: 0, to: height(of: kind), tint: tint)
        if let back = backrest(of: kind) {
            faces += boxFaces(item, from: back.from, to: back.to,
                              tint: tint, fraction: back.depth, placement: back.placement)
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
        case .plant:           (0.70, 1.30, 0.60, .centred)
        case .tree:            (2.20, 3.60, 0.95, .centred)
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
                                 placement: Placement = .centred) -> [Face] {
        guard top > bottom else { return [] }
        let low = corners(of: item, at: bottom, fraction: fraction, placement: placement)
        let high = corners(of: item, at: top, fraction: fraction, placement: placement)
        var faces = [Face(points: high, kind: .furnitureTop,
                          roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint)]
        for index in 0..<4 {
            let next = (index + 1) % 4
            faces.append(Face(points: [low[index], low[next], high[next], high[index]],
                              kind: .furnitureSide,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint))
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
                                   shutterClosed: closedShutters[opening.id] ?? 0,
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
                                   shutterClosed: closedShutters[opening.id] ?? 0,
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
