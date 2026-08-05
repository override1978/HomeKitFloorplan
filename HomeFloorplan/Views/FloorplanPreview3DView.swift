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

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.08).ignoresSafeArea()

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
                azimuth = origin.azimuth - value.translation.width * 0.006
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
        for entry in layout(in: size) {
            var path = Path()
            path.move(to: entry.screen[0])
            for point in entry.screen.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            // Nessun contorno: erano i bordi a far vedere le giunzioni, e con i
            // muri che ora si compenetrano non separano più niente.
            context.fill(path, with: .color(color(for: entry.face)))
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
    private func project(_ point: SIMD3<Double>) -> CGPoint {
        let forward = point.x * cos(azimuth) + point.y * sin(azimuth)
        return CGPoint(x: -point.x * sin(azimuth) + point.y * cos(azimuth),
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
        }
    }
}

/// Richiesta di anteprima: il documento viaggia per valore, così il foglio non
/// tiene vivo il modello SwiftData mentre è aperto.
struct Preview3DRequest: Identifiable {
    let id = UUID()
    let document: DrawingDocument
    let title: String
}
