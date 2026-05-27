import Foundation
import RoomPlan
import UIKit
import SwiftUI
import simd

// MARK: - 2D Models

/// Modello 2D semplificato di un muro: due punti nel piano (no 3D, no transform).
struct Wall2D: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    
    var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
    
    /// Angolo in radianti rispetto all'asse X.
    var angle: CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }
}

struct Opening2D: Identifiable {
    enum Kind { case door, window, opening }
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var kind: Kind
}

/// Floorplan 2D semplificato, pronto per rendering Canvas.
struct Floorplan2D {
    var walls: [Wall2D]
    var openings: [Opening2D]
    var bounds: CGRect   // bounding box di tutti gli elementi
}

// MARK: - Service

@MainActor
enum RoomPlanExportService {
    
    enum ExportError: LocalizedError {
        case noWalls
        case imageRenderFailed
        
        var errorDescription: String? {
            switch self {
            case .noWalls: return "Nessun muro rilevato nella scansione."
            case .imageRenderFailed: return "Impossibile renderizzare la planimetria."
            }
        }
    }
    
    /// API pubblica: esporta CapturedStructure come PNG.
    static func exportAsImage(structure: CapturedStructure,
                              size: CGSize = CGSize(width: 1500, height: 1500)) throws -> UIImage {
        let walls = structure.rooms.flatMap { $0.walls }
        let doors = structure.rooms.flatMap { $0.doors }
        let openings = structure.rooms.flatMap { $0.openings }
        let windows = structure.rooms.flatMap { $0.windows }
        
        let plan = try buildFloorplan2D(walls: walls,
                                        doors: doors,
                                        openings: openings,
                                        windows: windows)
        return try renderToImage(plan: plan, size: size)
    }
    
    /// API pubblica: esporta singolo CapturedRoom come PNG.
    static func exportAsImage(room: CapturedRoom,
                              size: CGSize = CGSize(width: 1500, height: 1500)) throws -> UIImage {
        let plan = try buildFloorplan2D(walls: room.walls,
                                        doors: room.doors,
                                        openings: room.openings,
                                        windows: room.windows)
        return try renderToImage(plan: plan, size: size)
    }
    
    // MARK: - Step 1: estrazione 3D → 2D
    
    /// Da un set di Surface (muri/porte/finestre 3D di RoomPlan) costruisce un Floorplan2D.
    /// I muri sono "lunghezze" rispetto al centro + transform; noi estraiamo start/end nel piano XZ.
     static func buildFloorplan2D(walls: [CapturedRoom.Surface],
                                         doors: [CapturedRoom.Surface],
                                         openings: [CapturedRoom.Surface],
                                         windows: [CapturedRoom.Surface]) throws -> Floorplan2D {
        guard !walls.isEmpty else {
            throw ExportError.noWalls
        }
        
        // Estrai walls 2D nel piano XZ (Y ignorato)
        var wallsRaw = walls.map { extractWall2D(from: $0) }
        
        // Step 2: ottimizza geometria
        wallsRaw = GeometryOptimizer.snapTo90Degrees(walls: wallsRaw, tolerance: 0.15)
        wallsRaw = GeometryOptimizer.mergeNearbyEndpoints(walls: wallsRaw, tolerance: 0.15)
        wallsRaw = GeometryOptimizer.removeShortSegments(walls: wallsRaw, minLength: 0.20)
        
        let doors2D = doors.map { Opening2D(start: extractStart(from: $0),
                                            end: extractEnd(from: $0),
                                            kind: .door) }
        let openings2D = openings.map { Opening2D(start: extractStart(from: $0),
                                                  end: extractEnd(from: $0),
                                                  kind: .opening) }
        let windows2D = windows.map { Opening2D(start: extractStart(from: $0),
                                                end: extractEnd(from: $0),
                                                kind: .window) }
        let allOpenings = doors2D + openings2D + windows2D
        
        // Calcola bounding box
        let bounds = computeBounds(walls: wallsRaw, openings: allOpenings)
        
        print("📐 [PLAN] walls: \(wallsRaw.count)")
        print("📐 [PLAN] openings: \(allOpenings.count)")
        print("📐 [PLAN] bounds: \(bounds)")
        
        return Floorplan2D(walls: wallsRaw, openings: allOpenings, bounds: bounds)
    }
    
    /// Estrai un Wall2D da una Surface 3D.
    /// Il centro del muro è transform.columns.3; la "direzione del muro" è transform.columns.0;
    /// la lunghezza è dimensions.x.
    private static func extractWall2D(from surface: CapturedRoom.Surface) -> Wall2D {
        let start = extractStart(from: surface)
        let end = extractEnd(from: surface)
        return Wall2D(start: start, end: end)
    }
    
    private static func extractStart(from surface: CapturedRoom.Surface) -> CGPoint {
        let center = surface.transform.columns.3
        let xAxis = simd_float3(surface.transform.columns.0.x,
                                surface.transform.columns.0.y,
                                surface.transform.columns.0.z)
        let halfLength = surface.dimensions.x / 2.0
        let direction = xAxis * halfLength
        return CGPoint(x: CGFloat(center.x - direction.x),
                       y: CGFloat(center.z - direction.z))
    }
    
    private static func extractEnd(from surface: CapturedRoom.Surface) -> CGPoint {
        let center = surface.transform.columns.3
        let xAxis = simd_float3(surface.transform.columns.0.x,
                                surface.transform.columns.0.y,
                                surface.transform.columns.0.z)
        let halfLength = surface.dimensions.x / 2.0
        let direction = xAxis * halfLength
        return CGPoint(x: CGFloat(center.x + direction.x),
                       y: CGFloat(center.z + direction.z))
    }
    
    private static func computeBounds(walls: [Wall2D], openings: [Opening2D]) -> CGRect {
        var minX: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var minY: CGFloat = .infinity
        var maxY: CGFloat = -.infinity
        
        let allPoints: [CGPoint] = walls.flatMap { [$0.start, $0.end] } +
                                   openings.flatMap { [$0.start, $0.end] }
        for p in allPoints {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    // MARK: - Step 3: rendering via UIGraphicsImageRenderer + CGContext
    
    private static func renderToImage(plan: Floorplan2D, size: CGSize) throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            
            // Sfondo bianco
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            
            // Padding e scale per far entrare il floorplan
            let padding: CGFloat = 80
            let drawArea = CGRect(x: padding, y: padding,
                                  width: size.width - padding * 2,
                                  height: size.height - padding * 2)
            
            let scaleX = drawArea.width / plan.bounds.width
            let scaleY = drawArea.height / plan.bounds.height
            let scale = min(scaleX, scaleY)
            
            let renderWidth = plan.bounds.width * scale
            let renderHeight = plan.bounds.height * scale
            let dx = (drawArea.width - renderWidth) / 2
            let dy = (drawArea.height - renderHeight) / 2
            
            func project(_ p: CGPoint) -> CGPoint {
                let x = (p.x - plan.bounds.minX) * scale + padding + dx
                // FLIP Y: nel piano XZ p.y (=Z) crescente va "su",
                // ma nello schermo Y crescente va "giù".
                let y = drawArea.maxY - ((p.y - plan.bounds.minY) * scale + dy)
                return CGPoint(x: x, y: y)
            }
            
            // 1. Pareti spesse nere
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(20)
            cg.setLineCap(.square)
            cg.setLineJoin(.miter)
            for wall in plan.walls {
                cg.move(to: project(wall.start))
                cg.addLine(to: project(wall.end))
                cg.strokePath()
            }
            
            // 2. Porte/aperture come gap bianchi (più spessi del muro)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineCap(.butt)
            for opening in plan.openings where opening.kind != .window {
                cg.setLineWidth(opening.kind == .door ? 26 : 24)
                cg.move(to: project(opening.start))
                cg.addLine(to: project(opening.end))
                cg.strokePath()
            }
            
            // 3. Finestre come segmenti azzurri tratteggiati (sovrapposti)
            cg.setStrokeColor(UIColor.systemBlue.cgColor)
            cg.setLineWidth(14)
            cg.setLineDash(phase: 0, lengths: [12, 6])
            cg.setLineCap(.round)
            for opening in plan.openings where opening.kind == .window {
                cg.move(to: project(opening.start))
                cg.addLine(to: project(opening.end))
                cg.strokePath()
            }
        }
        return image
    }
    
    /// Solo per debug: estrae il Floorplan2D dalla struttura senza renderizzarlo.
    static func buildPlan(structure: CapturedStructure) throws -> Floorplan2D {
        let walls = structure.rooms.flatMap { $0.walls }
        let doors = structure.rooms.flatMap { $0.doors }
        let openings = structure.rooms.flatMap { $0.openings }
        let windows = structure.rooms.flatMap { $0.windows }
        
        return try buildFloorplan2D(walls: walls,
                                    doors: doors,
                                    openings: openings,
                                    windows: windows)
    }
}

// MARK: - Geometry Optimizer

/// Pulisce la geometria 2D estratta da RoomPlan applicando:
/// - snap angoli vicini a 90° (orizzontali/verticali)
/// - raccordo endpoint vicini (evita gap tra muri)
/// - rimozione segmenti troppo corti
enum GeometryOptimizer {
    
    /// Snap-pa muri con angolo vicino a 0/90/180/270° all'asse rispettivo.
    /// La tolleranza è in radianti: 0.15 rad ≈ 8.6°.
    static func snapTo90Degrees(walls: [Wall2D], tolerance: CGFloat) -> [Wall2D] {
        walls.map { wall in
            let angle = wall.angle
            
            // Lista degli angoli "puliti": 0, π/2, π, -π/2, -π
            let snapAngles: [CGFloat] = [0, .pi / 2, .pi, -.pi / 2, -.pi]
            
            guard let closest = snapAngles.min(by: {
                abs(angleDelta($0, angle)) < abs(angleDelta($1, angle))
            }) else { return wall }
            
            let delta = abs(angleDelta(closest, angle))
            if delta < tolerance {
                // Ruota il muro mantenendo lo stesso centro, ma con angolo snapped
                let center = CGPoint(x: (wall.start.x + wall.end.x) / 2,
                                     y: (wall.start.y + wall.end.y) / 2)
                let length = wall.length
                let halfLen = length / 2
                
                let newStart = CGPoint(x: center.x - cos(closest) * halfLen,
                                       y: center.y - sin(closest) * halfLen)
                let newEnd = CGPoint(x: center.x + cos(closest) * halfLen,
                                     y: center.y + sin(closest) * halfLen)
                return Wall2D(start: newStart, end: newEnd)
            }
            return wall
        }
    }
    
    /// Unisce endpoint vicini: se due muri hanno punti distanti < tolerance,
    /// sposta entrambi nel punto medio.
    static func mergeNearbyEndpoints(walls: [Wall2D], tolerance: CGFloat) -> [Wall2D] {
        // Raccoglie tutti i punti
        var points: [(wallIndex: Int, isStart: Bool, point: CGPoint)] = []
        for (i, wall) in walls.enumerated() {
            points.append((i, true, wall.start))
            points.append((i, false, wall.end))
        }
        
        // Cluster punti vicini
        var clusters: [[Int]] = []  // ogni cluster contiene indici in `points`
        var assigned = Set<Int>()
        
        for i in 0..<points.count {
            guard !assigned.contains(i) else { continue }
            var cluster = [i]
            assigned.insert(i)
            for j in (i+1)..<points.count {
                guard !assigned.contains(j) else { continue }
                if distance(points[i].point, points[j].point) < tolerance {
                    cluster.append(j)
                    assigned.insert(j)
                }
            }
            clusters.append(cluster)
        }
        
        // Per ogni cluster, calcola il centroide e applica
        var newWalls = walls
        for cluster in clusters where cluster.count > 1 {
            let centroidX = cluster.map { points[$0].point.x }.reduce(0, +) / CGFloat(cluster.count)
            let centroidY = cluster.map { points[$0].point.y }.reduce(0, +) / CGFloat(cluster.count)
            let centroid = CGPoint(x: centroidX, y: centroidY)
            
            for idx in cluster {
                let entry = points[idx]
                if entry.isStart {
                    newWalls[entry.wallIndex].start = centroid
                } else {
                    newWalls[entry.wallIndex].end = centroid
                }
            }
        }
        
        return newWalls
    }
    
    /// Rimuove muri con lunghezza < minLength (probabili artefatti).
    static func removeShortSegments(walls: [Wall2D], minLength: CGFloat) -> [Wall2D] {
        walls.filter { $0.length >= minLength }
    }
    
    // MARK: - Math helpers
    
    private static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }
    
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
