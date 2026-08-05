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
        .overlay(alignment: .topLeading) { closeButton }
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
    private var closeButton: some View {
        Button { dismiss() } label: { chrome("xmark") }
            .padding()
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

    /// Scala e centratura, condivise da facce e ombre.
    private func frame(in size: CGSize) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat)? {
        let all = faces.flatMap { $0.points.map(project) }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        let inset: CGFloat = 56
        let scale = min((size.width - inset * 2) / (maxX - minX),
                        (size.height - inset * 2) / (maxY - minY))
        return (scale,
                (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                (size.height - (maxY - minY) * scale) / 2 - minY * scale)
    }

    private func screen(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard let frame = frame(in: size) else { return point }
        return CGPoint(x: point.x * frame.scale + frame.dx, y: point.y * frame.scale + frame.dy)
    }

    /// Proiezione e inquadratura in un punto solo: disegno e tocco devono vedere
    /// le stesse coordinate, e ricalcolarle in due posti è il modo sicuro per
    /// farle divergere.
    private func layout(in size: CGSize) -> [Entry] {
        let projected = faces.map { ($0, $0.points.map(project), depth(of: $0.centroid)) }
        let all = projected.flatMap(\.1)
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
              maxX > minX, maxY > minY else { return [] }

        let inset: CGFloat = 48
        let scale = min((size.width - inset * 2) / (maxX - minX),
                        (size.height - inset * 2) / (maxY - minY))
        let dx = (size.width - (maxX - minX) * scale) / 2 - minX * scale
        let dy = (size.height - (maxY - minY) * scale) / 2 - minY * scale

        return projected
            .map { Entry(face: $0.0,
                         screen: $0.1.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) },
                         depth: $0.2) }
            .sorted { $0.depth > $1.depth }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let entries = layout(in: size)

        // Ombre per prime, tutte insieme e sotto tutto: sono la proiezione a
        // terra delle facce superiori, spostate lungo la luce. Non è un calcolo
        // di illuminazione — è la stessa faccia disegnata due volte, ed è
        // sufficiente perché l'occhio cerca il contatto col pavimento, non la
        // correttezza fisica.
        for entry in entries where entry.face.kind == .wallTop
            || entry.face.kind == .parapetTop || entry.face.kind == .furnitureTop {
            var path = Path()
            let dropped = entry.face.points.map { point -> CGPoint in
                let ground = SIMD3(point.x + point.z * 0.45, point.y + point.z * 0.32, 0)
                return screen(project(ground), in: size)
            }
            path.move(to: dropped[0])
            for point in dropped.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            context.fill(path, with: .color(.black.opacity(0.16)))
        }

        for entry in entries {
            var path = Path()
            path.move(to: entry.screen[0])
            for point in entry.screen.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            // Nessun contorno: erano i bordi a far vedere le giunzioni, e con i
            // muri che ora si compenetrano non separano più niente.
            context.fill(path, with: .color(color(for: entry.face)))
        }

        drawMarkers(in: context, size: size)
    }

    /// I marker sopra tutto, non in coda alla profondità.
    ///
    /// Un accessorio dietro un muro resterebbe nascosto proprio quando lo si
    /// cerca: qui non sono oggetti della scena, sono etichette su di essa — e
    /// un'etichetta che si nasconde non serve a niente.
    private func drawMarkers(in context: GraphicsContext, size: CGSize) {
        guard let transform = imageToMetres else { return }
        let stem = 1.5

        for marker in markers {
            let x = Double(marker.position.x) * transform.scale + transform.dx
            let y = Double(marker.position.y) * transform.scale + transform.dy
            let foot = screen(project(SIMD3(x, y, 0)), in: size)
            let head = screen(project(SIMD3(x, y, stem)), in: size)

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
        }
    }

    /// La stanza sotto il dito.
    ///
    /// Prima si prova il colpo esatto, poi si **ignora ciò che sta davanti**: da
    /// questa inquadratura i muri coprono buona parte del pavimento, e chiedere
    /// di centrare il lembo scoperto trasforma una selezione in una prova di
    /// mira. Toccare il muro di una stanza vuol dire quella stanza.
    private func room(at location: CGPoint, in size: CGSize) -> UUID? {
        let entries = layout(in: size)
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
            return base.opacity(isSelected ? 0.95 : (selectedRoomID == nil ? 0.55 : 0.24))
        case .wallTop:
            return Color(white: 0.86)
        case .wallSide:
            return Color(white: 0.62)
        case .glass:
            // Trasparente sul serio: si deve vedere la stanza dietro, altrimenti
            // è un pannello azzurro e tanto valeva lasciare il buco.
            return Color(red: 0.55, green: 0.78, blue: 0.92).opacity(0.35)
        case .frame:
            return Color(white: 0.33)
        case .doorLeaf:
            // **Opaco.** Traslucido prendeva il colore di ciò che ha dietro: una
            // finestra dà sullo sfondo scuro e resta azzurra, una porta dà sul
            // pavimento della stanza accanto e diventava verde.
            //
            // Non toglie niente: da una telecamera alta si entra nelle stanze
            // scavalcando i muri, non guardando attraverso le porte.
            return Color(red: 0.62, green: 0.45, blue: 0.32)
        case .parapetTop:
            // Toni freddi contro i grigi caldi dei muri: si legge «fuori» prima
            // ancora di accorgersi che è più basso.
            return Color(red: 0.72, green: 0.78, blue: 0.83)
        case .parapetSide:
            return Color(red: 0.50, green: 0.57, blue: 0.63)
        case .furnitureTop:
            // La tinta scelta in pianta vale anche qui: un mobile riconoscibile
            // di sopra deve restarlo di sotto.
            guard let tint = face.tint else { return Color(white: 0.55) }
            return Color(cgColor: tint)
        case .furnitureSide:
            guard let tint = face.tint else { return Color(white: 0.40) }
            return Color(cgColor: tint).opacity(0.72)
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
