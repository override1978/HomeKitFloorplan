import SwiftUI

struct FloorplanDebugView: View {
    let plan: Floorplan2D
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Debug")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(plan.walls.count) muri • bounds: \(Int(plan.bounds.width))×\(Int(plan.bounds.height))m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Canvas { context, size in
                let padding: CGFloat = 20
                let drawArea = CGRect(
                    x: padding, y: padding,
                    width: size.width - padding * 2,
                    height: size.height - padding * 2
                )
                let scaleX = drawArea.width / max(plan.bounds.width, 0.01)
                let scaleY = drawArea.height / max(plan.bounds.height, 0.01)
                let scale = min(scaleX, scaleY)
                
                let renderW = plan.bounds.width * scale
                let renderH = plan.bounds.height * scale
                let dx = (drawArea.width - renderW) / 2
                let dy = (drawArea.height - renderH) / 2
                
                func project(_ p: CGPoint) -> CGPoint {
                    let x = (p.x - plan.bounds.minX) * scale + padding + dx
                    let y = (p.y - plan.bounds.minY) * scale + padding + dy
                    return CGPoint(x: x, y: y)
                }
                
                // Pareti come linee colorate (gradiente da inizio a fine per vedere direzione)
                for (i, wall) in plan.walls.enumerated() {
                    let s = project(wall.start)
                    let e = project(wall.end)
                    
                    var path = Path()
                    path.move(to: s)
                    path.addLine(to: e)
                    context.stroke(path,
                                   with: .color(.black),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    
                    // Pallino verde su start
                    context.fill(
                        Path(ellipseIn: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10)),
                        with: .color(.green)
                    )
                    
                    // Pallino rosso su end
                    context.fill(
                        Path(ellipseIn: CGRect(x: e.x - 5, y: e.y - 5, width: 10, height: 10)),
                        with: .color(.red)
                    )
                    
                    // Numero del muro a metà
                    let midX = (s.x + e.x) / 2
                    let midY = (s.y + e.y) / 2
                    context.draw(
                        Text("\(i)").font(.caption2.bold()).foregroundColor(.blue),
                        at: CGPoint(x: midX, y: midY)
                    )
                }
                
                // Openings come linee colorate
                for opening in plan.openings {
                    let s = project(opening.start)
                    let e = project(opening.end)
                    
                    var path = Path()
                    path.move(to: s)
                    path.addLine(to: e)
                    
                    let color: Color = {
                        switch opening.kind {
                        case .door: return .orange
                        case .window: return .blue
                        case .opening: return .purple
                        }
                    }()
                    
                    context.stroke(path,
                                   with: .color(color),
                                   style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                }
            }
            .frame(height: 400)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Lista dump testuale dei muri
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.walls.enumerated()), id: \.element.id) { index, wall in
                        Text("[\(index)] s=(\(format(wall.start.x)), \(format(wall.start.y))) → e=(\(format(wall.end.x)), \(format(wall.end.y))) len=\(format(wall.length))m")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}
