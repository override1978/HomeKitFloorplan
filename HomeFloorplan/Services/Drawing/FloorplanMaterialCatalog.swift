import RealityKit
import UIKit
import Metal

// MARK: - FloorplanMaterialCatalog

enum FloorplanMaterialCatalog {
    static func material(for role: FloorplanScene.MeshFace.MaterialRole,
                         isSelected: Bool = false,
                         floorKind: FloorKind? = nil) -> any RealityKit.Material {
        switch role {
        case .floor:
            return floorMaterial(for: floorKind, isSelected: isSelected)
        case .wall:
            return opaque(UIColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1), roughness: 0.94)
        case .wallTop:
            return opaque(UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1), roughness: 0.94)
        case .glass:
            return transparent(UIColor(red: 0.72, green: 0.84, blue: 0.88, alpha: 1),
                               opacity: 0.34, roughness: 0.06)
        case .frame:
            return opaque(UIColor(white: 0.82, alpha: 1), roughness: 0.62)
        case .door:
            return opaque(UIColor(red: 0.68, green: 0.60, blue: 0.48, alpha: 1), roughness: 0.62)
        case .doorEdge:
            return opaque(UIColor(red: 0.38, green: 0.31, blue: 0.23, alpha: 1), roughness: 0.62)
        case .doorTrim:
            return opaque(UIColor(red: 0.82, green: 0.78, blue: 0.70, alpha: 1), roughness: 0.60)
        case .doorGlass:
            return doorGlassMaterial()
        case .doorHandle:
            return doorHandleMaterial()
        case .furniture:
            // Tinta unica per la prova: prima si guarda se sotto luce vera i
            // volumi semplici reggono, poi eventualmente si differenzia.
            return opaque(UIColor(red: 0.80, green: 0.76, blue: 0.71, alpha: 1), roughness: 0.72)
        case .sunPatch:
            // **Unlit**, non PBR: una macchia di luce non è una superficie, e
            // ombreggiarla vorrebbe dire scurire la luce stessa.
            var patch = UnlitMaterial(color: UIColor(red: 1.0, green: 0.95, blue: 0.78, alpha: 1))
            patch.blending = .transparent(opacity: .init(floatLiteral: 0.30))
            return patch
        case .houseShadow:
            // Non più usata: le ombre ora sono vere. Resta per compatibilità del ruolo.
            return transparent(UIColor(red: 0.06, green: 0.08, blue: 0.04, alpha: 1),
                               opacity: 0.18, roughness: 1.0)
        case .balcony:
            return transparent(UIColor(red: 0.62, green: 0.76, blue: 0.88, alpha: 1),
                               opacity: 0.62, roughness: 0.10)
        case .balconyTop:
            return transparent(UIColor(red: 0.86, green: 0.92, blue: 0.97, alpha: 1),
                               opacity: 0.85, roughness: 0.30)
        }
    }

    static func doorMaterial(openingKind: OpeningKind?, wallKind: WallKind?) -> any RealityKit.Material {
        if openingKind == .frenchDoor || openingKind == .slidingDoor {
            return opaque(UIColor(red: 0.82, green: 0.80, blue: 0.74, alpha: 1), roughness: 0.55)
        }

        if wallKind == .exterior {
            return opaque(UIColor(red: 0.78, green: 0.70, blue: 0.58, alpha: 1), roughness: 0.58)
        }

        return opaque(UIColor(red: 0.64, green: 0.54, blue: 0.39, alpha: 1), roughness: 0.60)
    }

    static func doorTrimMaterial(openingKind: OpeningKind?, wallKind: WallKind?) -> any RealityKit.Material {
        if openingKind == .frenchDoor || openingKind == .slidingDoor {
            return opaque(UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1), roughness: 0.55)
        }

        if wallKind == .exterior {
            return opaque(UIColor(red: 0.92, green: 0.88, blue: 0.78, alpha: 1), roughness: 0.55)
        }

        return opaque(UIColor(red: 0.48, green: 0.39, blue: 0.27, alpha: 1), roughness: 0.58)
    }

    static func doorGlassMaterial() -> any RealityKit.Material {
        transparent(UIColor(red: 0.76, green: 0.88, blue: 0.86, alpha: 1),
                    opacity: 0.38, roughness: 0.06)
    }

    static func doorHandleMaterial() -> any RealityKit.Material {
        opaque(UIColor(red: 0.72, green: 0.60, blue: 0.32, alpha: 1), roughness: 0.22, metallic: 0.85)
    }

    /// Il piano su cui la casa appoggia e su cui cade la sua ombra.
    ///
    /// Della stessa tinta dello sfondo, appena più scuro: non deve leggersi come
    /// un pavimento in più, solo dare all'ombra una superficie e alla casa un
    /// appoggio invece del vuoto.
    static func groundMaterial() -> any RealityKit.Material {
        opaque(UIColor(red: 0.26, green: 0.33, blue: 0.21, alpha: 1), roughness: 0.98)
    }

    static func floorDetailMaterial(for floorKind: FloorKind?) -> (any RealityKit.Material)? {
        switch floorKind {
        case .piastrelle:
            return transparent(UIColor(red: 0.50, green: 0.49, blue: 0.45, alpha: 1),
                               opacity: 0.32, roughness: 0.7)
        case .gres:
            return transparent(UIColor(red: 0.34, green: 0.34, blue: 0.32, alpha: 1),
                               opacity: 0.24, roughness: 0.7)
        case .legno, .marmo, .cemento, .erba, nil:
            return nil
        }
    }

    // MARK: - Costruttori PBR
    //
    // Si è passati da `UnlitMaterial` a `PhysicallyBasedMaterial`: unlit vuol dire
    // *senza luce*, quindi nessuna ombreggiatura, nessun rilievo e nessuna ombra.
    // Era quello — non le texture — a far sembrare il modello un diagramma.

    private static func opaque(_ color: UIColor,
                               roughness: Float,
                               metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        return material
    }

    private static func transparent(_ color: UIColor,
                                    opacity: Float,
                                    roughness: Float) -> PhysicallyBasedMaterial {
        var material = opaque(color, roughness: roughness)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    /// Texture ripetuta con **passo in metri**.
    ///
    /// Le UV dei pavimenti sono metriche, non normalizzate sulla stanza: prima
    /// una texture si stirava per riempire l'area, quindi il parquet aveva le
    /// stesse doghe in una camera da 6 m e in un bagno da 2 m. `tileSize` dice
    /// quanti metri copre una ripetizione, e il campionamento va in `.repeat`
    /// o oltre il primo metro la texture resterebbe spalmata.
    private static func textured(_ texture: TextureResource,
                                 roughness: Float,
                                 tileSize: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture, sampler: repeatSampler))
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        material.textureCoordinateTransform = .init(scale: SIMD2(1 / tileSize, 1 / tileSize))
        return material
    }

    private static let repeatSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return .init(descriptor)
    }()

    /// La selezione **tinge**, non sostituisce.
    ///
    /// Sostituire il materiale spegneva parquet e marmo proprio nella stanza che
    /// si sta guardando: si toccava il salotto e il legno spariva. Un tint si
    /// moltiplica sopra la texture, quindi la venatura resta e la stanza si
    /// accende lo stesso.
    private static func floorMaterial(for floorKind: FloorKind?,
                                      isSelected: Bool = false) -> any RealityKit.Material {
        var material = baseFloorMaterial(for: floorKind)
        guard isSelected else { return material }
        material.baseColor.tint = UIColor(red: 1.0, green: 0.86, blue: 0.50, alpha: 1)
        return material
    }

    private static func baseFloorMaterial(for floorKind: FloorKind?) -> PhysicallyBasedMaterial {
        switch floorKind {
        case .legno:
            return oakVeneerMaterial()
        case .piastrelle:
            return opaque(UIColor(red: 0.80, green: 0.79, blue: 0.74, alpha: 1), roughness: 0.45)
        case .gres:
            return opaque(UIColor(red: 0.65, green: 0.64, blue: 0.59, alpha: 1), roughness: 0.50)
        case .marmo:
            return marbleMaterial()
        case .cemento:
            return opaque(UIColor(red: 0.58, green: 0.58, blue: 0.55, alpha: 1), roughness: 0.85)
        case .erba:
            return opaque(UIColor(red: 0.42, green: 0.55, blue: 0.33, alpha: 1), roughness: 0.95)
        case nil:
            return opaque(UIColor(red: 0.74, green: 0.73, blue: 0.69, alpha: 1), roughness: 0.70)
        }
    }

    private static func marbleMaterial() -> PhysicallyBasedMaterial {
        guard let image = marbleTextureImage(),
              let texture = try? TextureResource(
                image: image,
                withName: "HabitatProceduralMarble",
                options: .init(semantic: .color)
              )
        else {
            return opaque(UIColor(red: 0.80, green: 0.78, blue: 0.68, alpha: 1), roughness: 0.30)
        }

        return textured(texture, roughness: 0.30, tileSize: 2.2)
    }

    private static func oakVeneerMaterial() -> PhysicallyBasedMaterial {
        guard let texture = try? TextureResource.load(named: "oak_veneer_01_diff_1k") else {
            return opaque(UIColor(red: 0.72, green: 0.58, blue: 0.42, alpha: 1), roughness: 0.55)
        }

        return textured(texture, roughness: 0.55, tileSize: 1.0)
    }

    private static func marbleTextureImage(size: Int = 768) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let cgContext = context.cgContext

            UIColor(red: 0.78, green: 0.76, blue: 0.66, alpha: 1).setFill()
            cgContext.fill(rect)

            let backgroundLines = 64
            for index in 0..<backgroundLines {
                let progress = CGFloat(index) / CGFloat(backgroundLines)
                let baseY = progress * CGFloat(size) + sin(progress * 21) * 42
                drawMarbleVein(
                    in: cgContext,
                    size: CGFloat(size),
                    baseY: baseY,
                    phase: CGFloat(index) * 0.91,
                    width: 1.4 + CGFloat(index % 4) * 0.55,
                    color: UIColor(red: 0.42, green: 0.40, blue: 0.35, alpha: 0.30)
                )
            }

            for index in 0..<14 {
                let progress = CGFloat(index) / 13
                drawMarbleVein(
                    in: cgContext,
                    size: CGFloat(size),
                    baseY: progress * CGFloat(size) + sin(progress * 10) * 64,
                    phase: CGFloat(index) * 1.73,
                    width: 2.8 + CGFloat(index % 3) * 1.1,
                    color: UIColor(red: 0.24, green: 0.23, blue: 0.20, alpha: 0.48)
                )
            }

            for index in 0..<10 {
                let progress = CGFloat(index) / 9
                drawMarbleVein(
                    in: cgContext,
                    size: CGFloat(size),
                    baseY: progress * CGFloat(size) + 28,
                    phase: CGFloat(index) * 2.21,
                    width: 6.0,
                    color: UIColor(red: 0.92, green: 0.89, blue: 0.78, alpha: 0.18)
                )
            }

            UIColor(red: 0.98, green: 0.94, blue: 0.82, alpha: 0.38).setFill()
            for index in 0..<34 {
                let x = CGFloat((index * 97) % size)
                let y = CGFloat((index * 211) % size)
                cgContext.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
            }
        }

        return image.cgImage
    }

    private static func drawMarbleVein(in context: CGContext,
                                       size: CGFloat,
                                       baseY: CGFloat,
                                       phase: CGFloat,
                                       width: CGFloat,
                                       color: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -size * 0.18, y: baseY - size * 0.08))

        for step in 0...22 {
            let progress = CGFloat(step) / 22
            let x = -size * 0.18 + progress * size * 1.36
            let wave = sin(progress * 22 + phase) * 22
                + sin(progress * 8 + phase * 0.47) * 50
            let diagonal = (progress - 0.5) * size * 0.34
            path.addLine(to: CGPoint(x: x, y: baseY + wave + diagonal))
        }

        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
