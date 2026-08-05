import SwiftUI

// MARK: - FloorplanPreview3DView

/// Anteprima in volume di una planimetria disegnata.
///
/// **Non genera un modello: proietta il documento.** Non c'è niente da
/// rigenerare quando il disegno cambia, perché qui non si conserva nulla — il
/// che è la differenza fra una vista e un export, ed è il motivo per cui questa
/// strada regge anche se un giorno ci si mette un motore 3D vero sotto:
/// cambierebbe solo chi disegna le facce, non chi le calcola.
///
/// Proiezione ortografica calcolata a mano su `Canvas`: nessun framework nuovo.
struct FloorplanPreview3DView: View {

    let document: DrawingDocument
    let title: String
    /// Marker della planimetria, in coordinate normalizzate sull'immagine.
    let markers: [(position: CGPoint, name: String)]
    /// Servono a **ricavare** la trasformazione: una stanza esiste in entrambi
    /// gli spazi — normalizzata qui, in coordinate canvas nel disegno — e due
    /// rappresentazioni della stessa cosa sono tutto ciò che serve per passare
    /// dall'una all'altra.
    let linkedRooms: [LinkedRoom]

    @Environment(\.dismiss) private var dismiss

    @State private var ceilingHeight: Double = 2.4
    /// Azimut e altezza della telecamera, in radianti. Continui, non a scatti:
    /// una proiezione ortografica generale costa le stesse quattro moltiplicazioni
    /// di un'isometrica fissa, quindi bloccarla a 90° non risparmiava niente e
    /// toglieva l'unica cosa che fa sembrare un volume un volume — poterci
    /// girare intorno.
    @State private var azimuth: Double = .pi / 4
    @State private var elevation: Double = .pi / 6
    @State private var gestureStart: (azimuth: Double, elevation: Double)?
    @State private var selectedRoomID: UUID?

    private var faces: [FloorplanExtruder.Face] {
        FloorplanExtruder.faces(from: document, heights: .init(ceiling: ceilingHeight))
    }

    private var selectedRoomName: String? {
        faces.first { $0.roomID == selectedRoomID }?.roomName
    }

    /// Da coordinate normalizzate sull'immagine a metri nel modello.
    ///
    /// L'immagine è inquadrata al momento dell'export, quindi il fattore non è
    /// deducibile: si ricava confrontando le stanze collegate — stesso
    /// `hmRoomUUID`, un rettangolo normalizzato di qua e uno in canvas di là.
    /// Si media su tutte quelle disponibili, perché una sola porta con sé tutto
    /// il proprio errore di arrotondamento.
    private var imageToMetres: (scale: Double, dx: Double, dy: Double)? {
        var samples: [(scale: Double, dx: Double, dy: Double)] = []
        for room in linkedRooms {
            guard let area = document.roomAreas.first(where: { $0.hmRoomUUID == room.hmRoomUUID }),
                  room.normalizedRect.width > 0.001, room.normalizedRect.height > 0.001
            else { continue }
            let metres = 1.0 / Double(DrawingDocument.ptsPerMeter)
            let scale = Double(area.rect.width) * metres / Double(room.normalizedRect.width)
            let midX = room.normalizedRect.x + room.normalizedRect.width / 2
            let midY = room.normalizedRect.y + room.normalizedRect.height / 2
            samples.append((scale,
                            Double(area.rect.midX) * metres - midX * scale,
                            Double(area.rect.midY) * metres - midY * scale))
        }
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        return (samples.reduce(0) { $0 + $1.scale } / count,
                samples.reduce(0) { $0 + $1.dx } / count,
                samples.reduce(0) { $0 + $1.dy } / count)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Non nero: un'ombra su fondo nero non esiste. Un grigio caldo con
            // un accenno di gradiente dà alla casa un piano su cui posarsi.
            LinearGradient(colors: [Color(red: 0.33, green: 0.34, blue: 0.36),
                                    Color(red: 0.20, green: 0.21, blue: 0.23)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            GeometryReader { geometry in
                Canvas { context, size in
                    draw(in: context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(orbit)
                .onTapGesture { location in
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedRoomID = room(at: location, in: geometry.size)
                    }
                }
            }
            .ignoresSafeArea()

            controls
        }
        .overlay(alignment: .top) { topChrome }
        .statusBarHidden()
    }

    /// Trascinare gira la casa: orizzontale l'azimut, verticale l'inclinazione.
    ///
    /// L'inclinazione si ferma prima dello zero e prima della verticale: a filo
    /// di pavimento le stanze diventano una riga, dall'alto perfetto sparisce
    /// ogni rilievo. Entrambi gli estremi sono viste inutili, e lasciarci
    /// arrivare è solo un modo per far perdere l'orientamento.
    private var orbit: some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = gestureStart ?? (azimuth, elevation)
                if gestureStart == nil { gestureStart = origin }
                // Il modello segue il dito: trascinando a destra il fronte gira a
                // destra. Con l'asse `x` in questo verso è l'azimut che cresce.
                azimuth = origin.azimuth + value.translation.width * 0.006
                elevation = min(max(origin.elevation + value.translation.height * 0.005,
                                    .pi / 18), .pi / 2.2)
            }
            .onEnded { _ in gestureStart = nil }
    }

    // MARK: - Comandi

    /// Comandi sospesi invece che una barra: a schermo intero il soggetto è il
    /// modello, e una barra di navigazione gli toglierebbe spazio per ripetere
    /// un nome che si sa già.
    private var topChrome: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { chrome("xmark") }

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.34), in: Capsule())
                .frame(maxWidth: .infinity)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    azimuth = .pi / 4
                    elevation = .pi / 6
                    selectedRoomID = nil
                }
            } label: {
                chrome("arrow.counterclockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let selectedRoomName {
                Text(selectedRoomName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 14) {
                Image(systemName: "arrow.up.and.down")
                // L'unico dato che una pianta non può contenere: quanto è alto
                // il soffitto. Tutto il resto viene dal disegno.
                Slider(value: $ceilingHeight, in: 2.0...4.0, step: 0.1)
                Text(ceilingHeight.formatted(.number.precision(.fractionLength(1))) + " m")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.35), in: Capsule())
            .frame(maxWidth: 420)
        }
        .padding(.bottom, 28)
        .padding(.horizontal)
    }

    // MARK: - Impaginazione

    private struct Entry {
        let face: FloorplanExtruder.Face
        let screen: [CGPoint]
        let depth: Double
    }

    private struct Projected {
        let entries: [Entry]
        let scale: CGFloat
        let dx: CGFloat
        let dy: CGFloat

        func screen(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + dx, y: point.y * scale + dy)
        }
    }

    /// Estrusione, proiezione e inquadratura in **una sola passata**.
    ///
    /// ⚠️ Prima erano tre funzioni che si richiamavano: `screen` chiedeva
    /// l'inquadratura per ogni punto, e l'inquadratura riproiettava tutte le
    /// facce per ricavarla. Quadratico a ogni fotogramma — e invisibile
    /// leggendo le funzioni una per una, perché ciascuna sembrava ragionevole
    /// da sola.
    private func projected(in size: CGSize) -> Projected? {
        let pairs = faces.map { face in
            (face, face.points.map(project), depth(of: face.centroid))
        }
        let all = pairs.flatMap(\.1)
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }

        let inset: CGFloat = 56
        let scale = min((size.width - inset * 2) / (maxX - minX),
                        (size.height - inset * 2) / (maxY - minY))
        let dx = (size.width - (maxX - minX) * scale) / 2 - minX * scale
        let dy = (size.height - (maxY - minY) * scale) / 2 - minY * scale

        let entries = pairs.map { pair -> Entry in
            Entry(face: pair.0,
                  screen: pair.1.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) },
                  depth: pair.2)
        }

        // I pavimenti **sempre per primi**, non secondo profondità.
        //
        // Un pavimento è grande e il suo baricentro sta in mezzo alla stanza,
        // quindi risulta più vicino di un mobile addossato alla parete di
        // fondo: ordinandoli insieme, il pavimento finiva dipinto sopra il
        // mobile e i mobili sembravano sprofondati. Sotto il pavimento non c'è
        // niente, quindi qui l'ordine giusto non è da calcolare, è noto.
        let floors = entries.filter { $0.face.kind == .floor }.sorted { $0.depth > $1.depth }
        // Gli arredi stanno dentro la casa, non sopra la casa. Disegnarli prima
        // dell'involucro evita che un box vicino al perimetro sembri uscire dai
        // muri quando il painter's algorithm ha ambiguità di profondità.
        let furniture = entries.filter { isFurniture($0.face.kind) }.sorted { $0.depth > $1.depth }
        let shell = entries.filter { $0.face.kind != .floor && !isFurniture($0.face.kind) }
            .sorted { $0.depth > $1.depth }
        return Projected(entries: floors + furniture + shell, scale: scale, dx: dx, dy: dy)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard let scene = projected(in: size) else { return }
        let entries = scene.entries

        // Ombre per prime, tutte insieme e sotto tutto: sono la proiezione a
        // terra delle facce superiori, spostate lungo la luce. Non è un calcolo
        // di illuminazione — è la stessa faccia disegnata due volte, ed è
        // sufficiente perché l'occhio cerca il contatto col pavimento, non la
        // correttezza fisica.
        for entry in entries where entry.face.kind == .wallTop || entry.face.kind == .parapetTop {
            var path = Path()
            let dropped = entry.face.points.map { point -> CGPoint in
                scene.screen(project(SIMD3(point.x + point.z * 0.25,
                                           point.y + point.z * 0.18, 0)))
            }
            path.move(to: dropped[0])
            for point in dropped.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            context.fill(path, with: .color(.black.opacity(0.08)))
        }

        for entry in entries {
            var path = Path()
            path.move(to: entry.screen[0])
            for point in entry.screen.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            // Nessun contorno: erano i bordi a far vedere le giunzioni, e con i
            // muri che ora si compenetrano non separano più niente.
            context.fill(path, with: .color(color(for: entry.face)))
            if let stroke = strokeColor(for: entry.face.kind) {
                context.stroke(path, with: .color(stroke), lineWidth: strokeWidth(for: entry.face.kind))
            }
        }

        drawMarkers(in: context, scene: scene)
    }

    /// I marker sopra tutto, non in coda alla profondità.
    ///
    /// Un accessorio dietro un muro resterebbe nascosto proprio quando lo si
    /// cerca: qui non sono oggetti della scena, sono etichette su di essa — e
    /// un'etichetta che si nasconde non serve a niente.
    private func drawMarkers(in context: GraphicsContext, scene: Projected) {
        guard let transform = imageToMetres else { return }
        let stem = 1.5

        for marker in markers {
            let x = Double(marker.position.x) * transform.scale + transform.dx
            let y = Double(marker.position.y) * transform.scale + transform.dy
            let foot = scene.screen(project(SIMD3(x, y, 0)))
            let head = scene.screen(project(SIMD3(x, y, stem)))

            var stalk = Path()
            stalk.move(to: foot)
            stalk.addLine(to: head)
            context.stroke(stalk, with: .color(.white.opacity(0.55)), lineWidth: 1.5)

            // Il punto a terra dice **dove**, la sfera in alto dice **cosa**:
            // senza il primo un marker sospeso è ambiguo di mezzo metro.
            context.fill(Path(ellipseIn: CGRect(x: foot.x - 2.5, y: foot.y - 2.5, width: 5, height: 5)),
                         with: .color(.white.opacity(0.5)))
            context.fill(Path(ellipseIn: CGRect(x: head.x - 7, y: head.y - 7, width: 14, height: 14)),
                         with: .color(Color(red: 1.0, green: 0.72, blue: 0.25)))

            drawMarkerLabel(marker.name, at: CGPoint(x: head.x, y: head.y - 13), in: context)
        }
    }

    private func drawMarkerLabel(_ name: String, at point: CGPoint, in context: GraphicsContext) {
        let label = compactMarkerLabel(name)
        guard !label.isEmpty else { return }

        let width = min(max(CGFloat(label.count) * 6.4 + 18, 44), 138)
        let rect = CGRect(x: point.x - width / 2, y: point.y - 25, width: width, height: 21)
        context.fill(Path(roundedRect: rect, cornerRadius: 10),
                     with: .color(.black.opacity(0.58)))
        context.draw(Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white),
                     at: CGPoint(x: rect.midX, y: rect.midY),
                     anchor: .center)
    }

    private func compactMarkerLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 18 else { return trimmed }
        return String(trimmed.prefix(17)) + "..."
    }

    /// La stanza sotto il dito.
    ///
    /// Prima si prova il colpo esatto, poi si **ignora ciò che sta davanti**: da
    /// questa inquadratura i muri coprono buona parte del pavimento, e chiedere
    /// di centrare il lembo scoperto trasforma una selezione in una prova di
    /// mira. Toccare il muro di una stanza vuol dire quella stanza.
    private func room(at location: CGPoint, in size: CGSize) -> UUID? {
        guard let entries = projected(in: size)?.entries else { return nil }
        for entry in entries.reversed() where contains(entry.screen, location) {
            if entry.face.kind == .floor { return entry.face.roomID }
            break
        }
        for entry in entries.reversed()
        where entry.face.kind == .floor && contains(entry.screen, location) {
            return entry.face.roomID
        }
        return nil
    }

    private func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Proiezione

    /// Proiezione ortografica da una telecamera ad azimut e altezza qualsiasi.
    /// Nessuna prospettiva: le linee parallele restano parallele, che su una
    /// pianta è quello che si vuole — le stanze mantengono le proporzioni.
    ///
    /// ⚠️ Il verso di `x` non è arbitrario. Nel disegno la `y` cresce **verso il
    /// basso**, come sul canvas: una terna scritta con le convenzioni della
    /// matematica produce l'immagine **riflessa**, e uno specchio è difficile da
    /// notare su una casa quasi simmetrica. A 45° questa formula dà `x − y`,
    /// cioè esattamente l'isometrica da cui siamo partiti.
    private func project(_ point: SIMD3<Double>) -> CGPoint {
        let forward = point.x * cos(azimuth) + point.y * sin(azimuth)
        return CGPoint(x: point.x * sin(azimuth) - point.y * cos(azimuth),
                       y: forward * sin(elevation) - point.z * cos(elevation))
    }

    private func depth(of point: SIMD3<Double>) -> Double {
        let forward = point.x * cos(azimuth) + point.y * sin(azimuth)
        return -(forward * cos(elevation) + point.z * sin(elevation))
    }

    private func isFurniture(_ kind: FloorplanExtruder.Face.Kind) -> Bool {
        kind == .furnitureTop || kind == .furnitureSide
    }

    /// Facce superiori più chiare, fiancate più scure: è tutto ciò che serve a
    /// leggere un volume, senza calcolare nessuna illuminazione.
    private func color(for face: FloorplanExtruder.Face) -> Color {
        switch face.kind {
        case .floor:
            guard let index = face.roomColorIndex else { return Color(white: 0.22) }
            let palette = RoomLabelPalette.colors
            let base = Color(cgColor: palette[index % palette.count])
            let isSelected = face.roomID != nil && face.roomID == selectedRoomID
            // La selezione alza l'opacità invece di cambiare tinta: la stanza
            // resta riconoscibile dal suo colore, si vede solo che è accesa —
            // e le altre si spengono, così il confronto è immediato.
            return base.opacity(isSelected ? 0.72 : (selectedRoomID == nil ? 0.34 : 0.16))
        case .wallTop:
            return Color(white: 0.96)
        case .wallSide:
            return Color(white: 0.80)
        case .glass:
            // Trasparente sul serio: si deve vedere la stanza dietro, altrimenti
            // è un pannello azzurro e tanto valeva lasciare il buco.
            return Color(red: 0.55, green: 0.78, blue: 0.92).opacity(0.35)
        case .frame:
            return Color(white: 0.62)
        case .doorLeaf:
            // **Opaco.** Traslucido prendeva il colore di ciò che ha dietro: una
            // finestra dà sullo sfondo scuro e resta azzurra, una porta dà sul
            // pavimento della stanza accanto e diventava verde.
            //
            // Non toglie niente: da una telecamera alta si entra nelle stanze
            // scavalcando i muri, non guardando attraverso le porte.
            return Color(red: 0.72, green: 0.62, blue: 0.52)
        case .parapetTop:
            // Toni freddi contro i grigi caldi dei muri: si legge «fuori» prima
            // ancora di accorgersi che è più basso.
            return Color(red: 0.88, green: 0.94, blue: 0.98).opacity(0.86)
        case .parapetSide:
            return Color(red: 0.64, green: 0.78, blue: 0.88).opacity(0.62)
        case .furnitureTop:
            // La tinta scelta in pianta vale anche qui: un mobile riconoscibile
            // di sopra deve restarlo di sotto.
            guard let tint = face.tint else { return Color(white: 0.64).opacity(0.88) }
            return Color(cgColor: tint).opacity(0.62)
        case .furnitureSide:
            guard let tint = face.tint else { return Color(white: 0.46).opacity(0.70) }
            return Color(cgColor: tint).opacity(0.42)
        }
    }

    private func strokeColor(for kind: FloorplanExtruder.Face.Kind) -> Color? {
        switch kind {
        case .parapetTop, .parapetSide:
            return Color(red: 0.95, green: 1.0, blue: 1.0).opacity(0.45)
        case .glass:
            return Color(red: 0.80, green: 0.94, blue: 1.0).opacity(0.55)
        case .frame, .doorLeaf:
            return Color.white.opacity(0.22)
        case .furnitureTop:
            return Color.white.opacity(0.18)
        default:
            return nil
        }
    }

    private func strokeWidth(for kind: FloorplanExtruder.Face.Kind) -> CGFloat {
        switch kind {
        case .parapetTop, .parapetSide:
            return 1.1
        case .glass, .frame, .doorLeaf, .furnitureTop:
            return 0.8
        default:
            return 0
        }
    }
}

/// Richiesta di anteprima: il documento viaggia per valore, così il foglio non
/// tiene vivo il modello SwiftData mentre è aperto.
struct Preview3DRequest: Identifiable {
    let id = UUID()
    let document: DrawingDocument
    let title: String
    /// Marker della planimetria, in coordinate normalizzate sull'immagine.
    let markers: [(position: CGPoint, name: String)]
    /// Servono a **ricavare** la trasformazione: una stanza esiste in entrambi
    /// gli spazi — normalizzata qui, in coordinate canvas nel disegno — e due
    /// rappresentazioni della stessa cosa sono tutto ciò che serve per passare
    /// dall'una all'altra.
    let linkedRooms: [LinkedRoom]
}
