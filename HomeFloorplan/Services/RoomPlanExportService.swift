import Foundation
import RoomPlan
import UIKit
import SwiftUI
import SceneKit
import simd

// MARK: - 2D Models

/// Modello 2D di un muro con spessore reale.
struct Wall2D: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var thickness: CGFloat   // spessore muro in metri (da dimensions.z)

    var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    var angle: CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }

    var center: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }
}

struct Opening2D: Identifiable {
    enum Kind { case door, window, opening }
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var kind: Kind
}

/// Floorplan 2D pronto per rendering Canvas.
struct Floorplan2D {
    var walls: [Wall2D]
    var openings: [Opening2D]
    var bounds: CGRect
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

    /// Esporta CapturedStructure come immagine PNG 2D del floorplan.
    static func exportAsImage(structure: CapturedStructure,
                              size: CGSize = CGSize(width: 1500, height: 1500)) throws -> UIImage {
        let walls = structure.rooms.flatMap { $0.walls }
        let doors = structure.rooms.flatMap { $0.doors }
        let openings = structure.rooms.flatMap { $0.openings }
        let windows = structure.rooms.flatMap { $0.windows }

        let plan = try buildFloorplan2D(walls: walls, doors: doors,
                                        openings: openings, windows: windows)
        return try renderToImage(plan: plan, size: size)
    }

    /// Esporta singolo CapturedRoom come PNG.
    static func exportAsImage(room: CapturedRoom,
                              size: CGSize = CGSize(width: 1500, height: 1500)) throws -> UIImage {
        let plan = try buildFloorplan2D(walls: room.walls, doors: room.doors,
                                        openings: room.openings, windows: room.windows)
        return try renderToImage(plan: plan, size: size)
    }

    // MARK: - 3D Top-Down Render (SceneKit)

    /// Renderizza la CapturedStructure come immagine planimetrica 3D
    /// usando una camera ortografica dall'alto (top-down view).
    /// Questo approccio usa direttamente i transform 3D di RoomPlan senza
    /// nessuna conversione manuale — la qualità è molto superiore al render 2D.
    static func exportAs3DTopDown(structure: CapturedStructure,
                                   size: CGSize = CGSize(width: 1500, height: 1500)) -> UIImage {
        let allRooms = structure.rooms
        let scene = buildScene(rooms: allRooms)
        return renderTopDown(scene: scene, size: size)
    }

    /// Variante per singola stanza.
    static func exportAs3DTopDown(room: CapturedRoom,
                                   size: CGSize = CGSize(width: 1500, height: 1500)) -> UIImage {
        let scene = buildScene(rooms: [room])
        return renderTopDown(scene: scene, size: size)
    }

    // MARK: - SceneKit Scene Builder

    private static func buildScene(rooms: [CapturedRoom]) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.white

        // Materiali riutilizzabili
        let wallMaterial = SCNMaterial()
        wallMaterial.diffuse.contents = UIColor(white: 0.15, alpha: 1.0)
        wallMaterial.lightingModel = .constant  // Nessuna illuminazione — colore piatto

        let doorMaterial = SCNMaterial()
        doorMaterial.diffuse.contents = UIColor(red: 0.95, green: 0.85, blue: 0.65, alpha: 1.0)
        doorMaterial.lightingModel = .constant

        let windowMaterial = SCNMaterial()
        windowMaterial.diffuse.contents = UIColor(red: 0.55, green: 0.78, blue: 0.95, alpha: 0.85)
        windowMaterial.lightingModel = .constant

        let openingMaterial = SCNMaterial()
        openingMaterial.diffuse.contents = UIColor(white: 0.85, alpha: 1.0)
        openingMaterial.lightingModel = .constant

        // Altezza di taglio: rendiamo solo 0.5m dal pavimento per avere
        // la sezione classica della planimetria (taglia le pareti a metà)
        let cutHeight: Float = 0.5

        // RoomPlan tratta i muri come superfici (dimensions.z ≈ 0).
        // Usiamo uno spessore fisso realistico per il rendering 2D top-down.
        let wallThickness: Float = 0.20    // 20cm — spessore tipico parete interna
        let openingThickness: Float = 0.22 // leggermente più largo per coprire il muro

        for (ri, room) in rooms.enumerated() {
            dprint("🏠 [Room \(ri)] walls=\(room.walls.count) doors=\(room.doors.count) windows=\(room.windows.count) openings=\(room.openings.count)")
            for (i, door) in room.doors.enumerated() {
                dprint("🚪 [Door \(i)] dim=\(door.dimensions) transform.t=(\(door.transform.columns.3.x), \(door.transform.columns.3.y), \(door.transform.columns.3.z))")
            }
            for (i, window) in room.windows.enumerated() {
                dprint("🪟 [Window \(i)] dim=\(window.dimensions) transform.t=(\(window.transform.columns.3.x), \(window.transform.columns.3.y), \(window.transform.columns.3.z))")
            }
            for (i, opening) in room.openings.enumerated() {
                dprint("🚪 [Opening \(i)] dim=\(opening.dimensions) transform.t=(\(opening.transform.columns.3.x), \(opening.transform.columns.3.y), \(opening.transform.columns.3.z))")
            }

            // — Pareti —
            for wall in room.walls {
                let w = wall.dimensions.x   // lunghezza
                let h = min(wall.dimensions.y, cutHeight)

                let geo = SCNBox(width: CGFloat(w), height: CGFloat(h),
                                 length: CGFloat(wallThickness), chamferRadius: 0)
                geo.materials = [wallMaterial]

                let node = SCNNode(geometry: geo)
                // Il transform di RoomPlan posiziona già il nodo nello spazio 3D corretto.
                // Non modifichiamo position dopo: causerebbe una doppia traslazione.
                node.transform = SCNMatrix4(wall.transform)
                scene.rootNode.addChildNode(node)
            }

            // — Porte: materiale beige per distinguere il vano porta —
            for door in room.doors {
                let w = door.dimensions.x
                let h = min(door.dimensions.y, cutHeight)

                let geo = SCNBox(width: CGFloat(w), height: CGFloat(h),
                                 length: CGFloat(openingThickness), chamferRadius: 0)
                geo.materials = [doorMaterial]

                let node = SCNNode(geometry: geo)
                node.transform = SCNMatrix4(door.transform)
                scene.rootNode.addChildNode(node)
            }

            // — Finestre —
            for window in room.windows {
                let w = window.dimensions.x
                let h = min(window.dimensions.y, cutHeight)

                let geo = SCNBox(width: CGFloat(w), height: CGFloat(h),
                                 length: CGFloat(openingThickness), chamferRadius: 0)
                geo.materials = [windowMaterial]

                let node = SCNNode(geometry: geo)
                node.transform = SCNMatrix4(window.transform)
                scene.rootNode.addChildNode(node)
            }

            // — Aperture (passages) —
            for opening in room.openings {
                let w = opening.dimensions.x
                let h = min(opening.dimensions.y, cutHeight)

                let geo = SCNBox(width: CGFloat(w), height: CGFloat(h),
                                 length: CGFloat(openingThickness), chamferRadius: 0)
                geo.materials = [openingMaterial]

                let node = SCNNode(geometry: geo)
                node.transform = SCNMatrix4(opening.transform)
                scene.rootNode.addChildNode(node)
            }
        }

        return scene
    }

    // MARK: - SceneKit Top-Down Renderer

    private static func renderTopDown(scene: SCNScene, size: CGSize) -> UIImage {
        // Calcola il bounding box di tutta la scena usando SCNNode.boundingBox
        // trasformato in world space — molto più preciso del semplice worldPosition.
        var minX: Float = .infinity, maxX: Float = -.infinity
        var minZ: Float = .infinity, maxZ: Float = -.infinity

        for node in scene.rootNode.childNodes {
            // boundingBox è nel sistema di coordinate locale del nodo
            let (bMin, bMax) = node.boundingBox
            // I 4 angoli del rettangolo in XZ
            let corners: [SIMD3<Float>] = [
                SIMD3(bMin.x, 0, bMin.z),
                SIMD3(bMax.x, 0, bMin.z),
                SIMD3(bMin.x, 0, bMax.z),
                SIMD3(bMax.x, 0, bMax.z),
            ]
            for c in corners {
                // Converti in world space tramite il transform del nodo
                let world = node.convertPosition(SCNVector3(c.x, c.y, c.z), to: nil)
                minX = min(minX, world.x); maxX = max(maxX, world.x)
                minZ = min(minZ, world.z); maxZ = max(maxZ, world.z)
            }
        }

        // Fallback se la scena è vuota
        if minX == .infinity { minX = -5; maxX = 5; minZ = -5; maxZ = 5 }

        let centerX = (minX + maxX) / 2
        let centerZ = (minZ + maxZ) / 2
        let spanX = (maxX - minX) + 2.0   // +2m di margine
        let spanZ = (maxZ - minZ) + 2.0
        let span = max(spanX, spanZ)

        // Camera ortografica posizionata direttamente sopra, guarda verso il basso
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(span / 2)
        camera.zNear = 0.1
        camera.zFar = 200

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // Posiziona la camera alta sopra il centro della scena
        cameraNode.position = SCNVector3(centerX, 50, centerZ)
        // Orienta verso il basso (-Y)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        // Luce ambientale per illuminazione piatta (nessuna ombra)
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 1000
        ambientLight.color = UIColor.white
        let lightNode = SCNNode()
        lightNode.light = ambientLight
        scene.rootNode.addChildNode(lightNode)

        // Sfondo bianco
        scene.background.contents = UIColor.white

        // Render via SCNRenderer (off-screen, non richiede una view visibile)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let renderDesc = MTLRenderPassDescriptor()
        _ = renderDesc  // Non usato direttamente — SCNRenderer gestisce internamente

        let image = renderer.snapshot(atTime: 0,
                                       with: size,
                                       antialiasingMode: .multisampling4X)

        dprint("📷 [3D Render] size=\(size) span=\(span)m center=(\(centerX), \(centerZ))")
        return image
    }

    /// Solo per debug: restituisce il Floorplan2D senza renderizzare.
    static func buildPlan(structure: CapturedStructure) throws -> Floorplan2D {
        let walls = structure.rooms.flatMap { $0.walls }
        let doors = structure.rooms.flatMap { $0.doors }
        let openings = structure.rooms.flatMap { $0.openings }
        let windows = structure.rooms.flatMap { $0.windows }
        return try buildFloorplan2D(walls: walls, doors: doors,
                                    openings: openings, windows: windows)
    }

    // MARK: - Step 1: 3D → 2D

    static func buildFloorplan2D(walls: [CapturedRoom.Surface],
                                  doors: [CapturedRoom.Surface],
                                  openings: [CapturedRoom.Surface],
                                  windows: [CapturedRoom.Surface]) throws -> Floorplan2D {
        guard !walls.isEmpty else { throw ExportError.noWalls }

        var walls2D = walls.map { extractWall2D(from: $0) }

        // Ottimizza geometria con tolleranze più generose (muri reali hanno gap 0.2–0.5m)
        walls2D = GeometryOptimizer.snapTo90Degrees(walls: walls2D, tolerance: 0.20)
        walls2D = GeometryOptimizer.mergeNearbyEndpoints(walls: walls2D, tolerance: 0.35)
        walls2D = GeometryOptimizer.removeShortSegments(walls: walls2D, minLength: 0.15)

        let doors2D    = doors.map    { Opening2D(start: extractPoint(from: $0, sign: -1),
                                                  end:   extractPoint(from: $0, sign: +1), kind: .door) }
        let openings2D = openings.map { Opening2D(start: extractPoint(from: $0, sign: -1),
                                                  end:   extractPoint(from: $0, sign: +1), kind: .opening) }
        let windows2D  = windows.map  { Opening2D(start: extractPoint(from: $0, sign: -1),
                                                  end:   extractPoint(from: $0, sign: +1), kind: .window) }
        let allOpenings = doors2D + openings2D + windows2D

        let bounds = computeBounds(walls: walls2D, openings: allOpenings)

        dprint("📐 [PLAN] walls: \(walls2D.count), openings: \(allOpenings.count)")
        dprint("📐 [PLAN] bounds: \(String(format: "%.2f x %.2f m", bounds.width, bounds.height))")
        for (i, w) in walls2D.enumerated() {
            dprint("📐 [WALL \(i)] len=\(String(format: "%.2f", w.length))m thick=\(String(format: "%.2f", w.thickness))m angle=\(String(format: "%.1f", w.angle * 180 / .pi))°")
        }

        return Floorplan2D(walls: walls2D, openings: allOpenings, bounds: bounds)
    }

    // MARK: - Estrazione coordinate 3D → 2D nel piano XZ

    /// Estrae la direzione del muro (asse X locale) proiettata nel piano XZ e normalizzata.
    /// RoomPlan: Y = altezza (ignorato), piano del pavimento = XZ.
    private static func wallDirection(from surface: CapturedRoom.Surface) -> SIMD2<Float> {
        // columns.0 = asse X locale del muro (lunghezza)
        let col0 = surface.transform.columns.0
        let dir = SIMD2<Float>(col0.x, col0.z)
        let len = simd_length(dir)
        guard len > 0.001 else { return SIMD2<Float>(1, 0) }
        return dir / len
    }

    private static func wallCenter(from surface: CapturedRoom.Surface) -> SIMD2<Float> {
        let col3 = surface.transform.columns.3
        return SIMD2<Float>(col3.x, col3.z)
    }

    private static func extractWall2D(from surface: CapturedRoom.Surface) -> Wall2D {
        let center = wallCenter(from: surface)
        let dir = wallDirection(from: surface)
        let halfLen = surface.dimensions.x / 2.0
        // spessore = dimensions.z per i muri (Y è l'altezza)
        let thickness = CGFloat(surface.dimensions.z)

        let start = center - dir * halfLen
        let end   = center + dir * halfLen

        return Wall2D(
            start: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)),
            end:   CGPoint(x: CGFloat(end.x),   y: CGFloat(end.y)),
            thickness: max(thickness, 0.05)  // minimo 5cm per evitare muri di spessore zero
        )
    }

    private static func extractPoint(from surface: CapturedRoom.Surface, sign: Float) -> CGPoint {
        let center = wallCenter(from: surface)
        let dir = wallDirection(from: surface)
        let halfLen = surface.dimensions.x / 2.0
        let pt = center + dir * (halfLen * sign)
        return CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y))
    }

    private static func computeBounds(walls: [Wall2D], openings: [Opening2D]) -> CGRect {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity

        let allPoints: [CGPoint] = walls.flatMap { [$0.start, $0.end] }
                                 + openings.flatMap { [$0.start, $0.end] }
        for p in allPoints {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }

        // Aggiungi un margine pari al massimo spessore dei muri
        let maxThickness = walls.map { $0.thickness }.max() ?? 0.2
        let margin = maxThickness
        return CGRect(x: minX - margin, y: minY - margin,
                      width: (maxX - minX) + margin * 2,
                      height: (maxY - minY) + margin * 2)
    }

    // MARK: - Rendering

    private static func renderToImage(plan: Floorplan2D, size: CGSize) throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext

            // Sfondo bianco
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let padding: CGFloat = 60
            let drawArea = CGRect(x: padding, y: padding,
                                  width: size.width - padding * 2,
                                  height: size.height - padding * 2)

            guard plan.bounds.width > 0, plan.bounds.height > 0 else { return }

            let scaleX = drawArea.width  / plan.bounds.width
            let scaleY = drawArea.height / plan.bounds.height
            let scale  = min(scaleX, scaleY)

            let renderW = plan.bounds.width  * scale
            let renderH = plan.bounds.height * scale
            let dx = (drawArea.width  - renderW) / 2
            let dy = (drawArea.height - renderH) / 2

            // Proiezione 2D: flip Y perché RoomPlan Z+ è "verso lo spettatore"
            // ma in UIKit Y+ va verso il basso.
            func project(_ p: CGPoint) -> CGPoint {
                let x = (p.x - plan.bounds.minX) * scale + padding + dx
                let y = drawArea.maxY - ((p.y - plan.bounds.minY) * scale + dy)
                return CGPoint(x: x, y: y)
            }

            // — Muri come rettangoli spessi con spessore reale —
            // Questo produce un rendering architettonico molto più pulito
            // rispetto a singoli segmenti con lineWidth fissa.
            for wall in plan.walls {
                let s = project(wall.start)
                let e = project(wall.end)
                let wallScreenThickness = max(wall.thickness * scale, 8)  // minimo 8pt per visibilità

                let angle = atan2(e.y - s.y, e.x - s.x)
                let perp  = angle + .pi / 2
                let halfT = wallScreenThickness / 2

                // I 4 vertici del rettangolo del muro
                let pts: [CGPoint] = [
                    CGPoint(x: s.x + cos(perp) * halfT, y: s.y + sin(perp) * halfT),
                    CGPoint(x: e.x + cos(perp) * halfT, y: e.y + sin(perp) * halfT),
                    CGPoint(x: e.x - cos(perp) * halfT, y: e.y - sin(perp) * halfT),
                    CGPoint(x: s.x - cos(perp) * halfT, y: s.y - sin(perp) * halfT),
                ]

                let path = CGMutablePath()
                path.move(to: pts[0])
                path.addLine(to: pts[1])
                path.addLine(to: pts[2])
                path.addLine(to: pts[3])
                path.closeSubpath()

                cg.addPath(path)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fillPath()
            }

            // — Porte: rettangolo bianco (gap nel muro) + arco di apertura —
            for opening in plan.openings where opening.kind == .door {
                let s = project(opening.start)
                let e = project(opening.end)
                let gapWidth = hypot(e.x - s.x, e.y - s.y)

                // Gap bianco (elimina il muro sotto)
                let angle = atan2(e.y - s.y, e.x - s.x)
                let perp  = angle + .pi / 2
                let gapThickness: CGFloat = 28

                let gap = CGMutablePath()
                gap.move(to: CGPoint(x: s.x + cos(perp) * gapThickness / 2, y: s.y + sin(perp) * gapThickness / 2))
                gap.addLine(to: CGPoint(x: e.x + cos(perp) * gapThickness / 2, y: e.y + sin(perp) * gapThickness / 2))
                gap.addLine(to: CGPoint(x: e.x - cos(perp) * gapThickness / 2, y: e.y - sin(perp) * gapThickness / 2))
                gap.addLine(to: CGPoint(x: s.x - cos(perp) * gapThickness / 2, y: s.y - sin(perp) * gapThickness / 2))
                gap.closeSubpath()
                cg.addPath(gap)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillPath()

                // Arco di apertura porta (simbolo architettonico standard)
                cg.setStrokeColor(UIColor.black.cgColor)
                cg.setLineWidth(2)
                cg.setLineDash(phase: 0, lengths: [])

                // Linea porta
                cg.move(to: s)
                cg.addLine(to: e)
                cg.strokePath()

                // Quarto di cerchio
                let startAngle = atan2(s.y - e.y, s.x - e.x)
                cg.move(to: e)
                cg.addArc(center: e, radius: gapWidth,
                          startAngle: startAngle,
                          endAngle: startAngle - .pi / 2,
                          clockwise: true)
                cg.strokePath()
            }

            // — Aperture (passages): solo gap bianco —
            for opening in plan.openings where opening.kind == .opening {
                let s = project(opening.start)
                let e = project(opening.end)
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(24)
                cg.setLineCap(.butt)
                cg.setLineDash(phase: 0, lengths: [])
                cg.move(to: s)
                cg.addLine(to: e)
                cg.strokePath()
            }

            // — Finestre: linea azzurra tripla nel muro —
            for opening in plan.openings where opening.kind == .window {
                let s = project(opening.start)
                let e = project(opening.end)

                // Gap bianco prima
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(16)
                cg.setLineCap(.butt)
                cg.setLineDash(phase: 0, lengths: [])
                cg.move(to: s); cg.addLine(to: e); cg.strokePath()

                // Tre linee parallele sottili azzurre (simbolo finestra)
                cg.setStrokeColor(UIColor.systemBlue.cgColor)
                cg.setLineWidth(1.5)
                cg.move(to: s); cg.addLine(to: e); cg.strokePath()

                let angle = atan2(e.y - s.y, e.x - s.x)
                let perp  = angle + .pi / 2
                let offsets: [CGFloat] = [-4, 0, 4]
                for off in offsets {
                    let ps = CGPoint(x: s.x + cos(perp) * off, y: s.y + sin(perp) * off)
                    let pe = CGPoint(x: e.x + cos(perp) * off, y: e.y + sin(perp) * off)
                    cg.move(to: ps); cg.addLine(to: pe); cg.strokePath()
                }
            }

            // — Linea di contorno sottile sui muri (rifinitura) —
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.3).cgColor)
            cg.setLineWidth(0.5)
            for wall in plan.walls {
                let s = project(wall.start)
                let e = project(wall.end)
                let wallScreenThickness = max(wall.thickness * scale, 8)
                let angle = atan2(e.y - s.y, e.x - s.x)
                let perp  = angle + .pi / 2
                let halfT = wallScreenThickness / 2

                let pts: [CGPoint] = [
                    CGPoint(x: s.x + cos(perp) * halfT, y: s.y + sin(perp) * halfT),
                    CGPoint(x: e.x + cos(perp) * halfT, y: e.y + sin(perp) * halfT),
                    CGPoint(x: e.x - cos(perp) * halfT, y: e.y - sin(perp) * halfT),
                    CGPoint(x: s.x - cos(perp) * halfT, y: s.y - sin(perp) * halfT),
                ]
                let path = CGMutablePath()
                path.move(to: pts[0]); path.addLine(to: pts[1])
                path.addLine(to: pts[2]); path.addLine(to: pts[3])
                path.closeSubpath()
                cg.addPath(path)
                cg.strokePath()
            }
        }
        return image
    }
}

// MARK: - Geometry Optimizer

enum GeometryOptimizer {

    /// Snap muri vicini a 0/90/180/270°.
    /// tolerance in radianti: 0.20 rad ≈ 11.5°
    static func snapTo90Degrees(walls: [Wall2D], tolerance: CGFloat) -> [Wall2D] {
        walls.map { wall in
            let angle = wall.angle
            let snapAngles: [CGFloat] = [0, .pi / 2, .pi, -.pi / 2, -.pi]
            guard let closest = snapAngles.min(by: {
                abs(angleDelta($0, angle)) < abs(angleDelta($1, angle))
            }) else { return wall }

            let delta = abs(angleDelta(closest, angle))
            guard delta < tolerance else { return wall }

            let center  = wall.center
            let halfLen = wall.length / 2
            let newStart = CGPoint(x: center.x - cos(closest) * halfLen,
                                   y: center.y - sin(closest) * halfLen)
            let newEnd   = CGPoint(x: center.x + cos(closest) * halfLen,
                                   y: center.y + sin(closest) * halfLen)
            return Wall2D(start: newStart, end: newEnd, thickness: wall.thickness)
        }
    }

    /// Unisce endpoint vicini (tolerance in metri).
    /// Con muri reali usare 0.30–0.40m.
    static func mergeNearbyEndpoints(walls: [Wall2D], tolerance: CGFloat) -> [Wall2D] {
        // Raccoglie tutti i punti con riferimento al muro
        struct PointRef {
            let wallIndex: Int
            let isStart: Bool
            var point: CGPoint
        }

        var points: [PointRef] = []
        for (i, wall) in walls.enumerated() {
            points.append(PointRef(wallIndex: i, isStart: true,  point: wall.start))
            points.append(PointRef(wallIndex: i, isStart: false, point: wall.end))
        }

        var assigned = Set<Int>()
        var newWalls = walls

        for i in 0..<points.count {
            guard !assigned.contains(i) else { continue }
            var cluster = [i]
            assigned.insert(i)
            for j in (i + 1)..<points.count {
                guard !assigned.contains(j) else { continue }
                if distance(points[i].point, points[j].point) < tolerance {
                    cluster.append(j)
                    assigned.insert(j)
                }
            }
            guard cluster.count > 1 else { continue }

            let cx = cluster.map { points[$0].point.x }.reduce(0, +) / CGFloat(cluster.count)
            let cy = cluster.map { points[$0].point.y }.reduce(0, +) / CGFloat(cluster.count)
            let centroid = CGPoint(x: cx, y: cy)

            for idx in cluster {
                let ref = points[idx]
                if ref.isStart {
                    newWalls[ref.wallIndex].start = centroid
                } else {
                    newWalls[ref.wallIndex].end = centroid
                }
            }
        }
        return newWalls
    }

    /// Rimuove segmenti più corti di minLength (metri).
    static func removeShortSegments(walls: [Wall2D], minLength: CGFloat) -> [Wall2D] {
        walls.filter { $0.length >= minLength }
    }

    // MARK: - Math

    private static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi  { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
