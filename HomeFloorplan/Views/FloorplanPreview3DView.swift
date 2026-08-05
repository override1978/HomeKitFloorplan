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
/// Proiezione isometrica calcolata a mano su `Canvas`: nessun framework nuovo.
struct FloorplanPreview3DView: View {

    let document: DrawingDocument
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var ceilingHeight: Double = 2.4
    /// Rotazioni di 90°. Un'isometrica non ruota liberamente, ma quattro angoli
    /// bastano a girare intorno alla casa — ed è l'unica cosa che serve per
    /// capire se una stanza è dietro o davanti.
    @State private var quarterTurns = 0

    private var faces: [FloorplanExtruder.Face] {
        FloorplanExtruder.faces(from: document,
                               heights: .init(ceiling: ceilingHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Canvas { context, size in
                    draw(faces, in: context, size: size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            controls
        }
        .background(Color(white: 0.08))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        quarterTurns = (quarterTurns + 1) % 4
                    }
                } label: {
                    Image(systemName: "rotate.3d")
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.and.down")
                .foregroundStyle(.secondary)
            // L'unico dato che una pianta non può contenere: quanto è alto il
            // soffitto. Tutto il resto viene dal disegno.
            Slider(value: $ceilingHeight, in: 2.0...4.0, step: 0.1)
            Text(ceilingHeight.formatted(.number.precision(.fractionLength(1))) + " m")
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Disegno

    private func draw(_ faces: [FloorplanExtruder.Face],
                      in context: GraphicsContext,
                      size: CGSize) {
        guard !faces.isEmpty else { return }

        let projected = faces.map { face -> (face: FloorplanExtruder.Face, points: [CGPoint], depth: Double) in
            (face, face.points.map(project), depth(of: face.centroid))
        }

        let allPoints = projected.flatMap(\.points)
        guard let minX = allPoints.map(\.x).min(), let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(), let maxY = allPoints.map(\.y).max(),
              maxX > minX, maxY > minY else { return }

        let inset: CGFloat = 32
        let scale = min((size.width - inset * 2) / (maxX - minX),
                        (size.height - inset * 2) / (maxY - minY))
        let offset = CGPoint(x: (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                             y: (size.height - (maxY - minY) * scale) / 2 - minY * scale)

        // Algoritmo del pittore: dal più lontano al più vicino. Con volumi
        // convessi e separati basta, e costa un ordinamento invece di uno
        // z-buffer.
        for entry in projected.sorted(by: { $0.depth > $1.depth }) {
            var path = Path()
            let screen = entry.points.map {
                CGPoint(x: $0.x * scale + offset.x, y: $0.y * scale + offset.y)
            }
            path.move(to: screen[0])
            for point in screen.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()

            context.fill(path, with: .color(color(for: entry.face)))
            context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
        }
    }

    /// Isometrica classica: due assi a 30°, la quota che sale verticale.
    private func project(_ point: SIMD3<Double>) -> CGPoint {
        let angle = Double(quarterTurns) * Double.pi / 2
        let x = point.x * cos(angle) - point.y * sin(angle)
        let y = point.x * sin(angle) + point.y * cos(angle)
        let cosine = cos(Double.pi / 6)
        let sine = sin(Double.pi / 6)
        return CGPoint(x: (x - y) * cosine,
                       y: (x + y) * sine - point.z)
    }

    private func depth(of point: SIMD3<Double>) -> Double {
        let angle = Double(quarterTurns) * Double.pi / 2
        let x = point.x * cos(angle) - point.y * sin(angle)
        let y = point.x * sin(angle) + point.y * cos(angle)
        return -(x + y) - point.z
    }

    /// Facce superiori più chiare, fiancate più scure: è tutto ciò che serve a
    /// leggere un volume, senza calcolare nessuna illuminazione.
    private func color(for face: FloorplanExtruder.Face) -> Color {
        switch face.kind {
        case .floor:
            guard let index = face.roomColorIndex else { return Color(white: 0.22) }
            let palette = RoomLabelPalette.colors
            return Color(cgColor: palette[index % palette.count]).opacity(0.55)
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
