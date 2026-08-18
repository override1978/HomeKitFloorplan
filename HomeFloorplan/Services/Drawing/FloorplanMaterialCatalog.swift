import RealityKit
import UIKit
import Metal

// MARK: - FloorplanMaterialCatalog

enum FloorplanMaterialCatalog {
    static func material(for role: FloorplanScene.MeshFace.MaterialRole,
                         floorKind: FloorKind? = nil) -> any RealityKit.Material {
        switch role {
        case .baseSlab:
            return plinthMaterial()
        case .floor:
            return baseFloorMaterial(for: floorKind)
        case .wall:
            // A 0.90/0.92/0.95 il bianco era a un soffio dalla saturazione:
            // appena la luce saliva non restava margine perché l'ombreggiatura
            // si vedesse. Scesi di sei punti, l'intonaco restava chiaro ma le
            // facce tornavano a distinguersi.
            //
            // Poi giu' di altri sei, e stavolta per la luce: una lampada accesa
            // «brilla» solo se ha qualcosa di piu' scuro attorno — su un muro
            // quasi bianco la sua pozza non ha margine per emergere. E' il
            // trucco che fa funzionare il bagliore nel concorrente: la loro
            // scena e' in penombra. L'intonaco resta percettivamente bianco,
            // perche' il bianco lo decide il contesto, non il numero.
            // ⚠️ Il «grigio» non era la chiarezza: era la **dominante blu**.
            // A parita' di luminanza un tono freddo si legge grigio e uno caldo
            // si legge bianco — 0.81/0.83/0.87 sembrava cemento, questo sembra
            // intonaco, ed e' piu' scuro del bianco quanto basta perche' la
            // luce delle lampade abbia margine per staccare.
            // Rialzato di tre punti su richiesta esplicita («i muri sono
            // molto grigi, la concorrenza e' piu' bianca»), accettando il
            // baratto: meno margine per la pozza delle lampade. Se il glow
            // smette di leggersi, il passo indietro e' qui.
            return opaque(UIColor(red: 0.89, green: 0.88, blue: 0.86, alpha: 1), roughness: 0.94)
        case .wallTop:
            return opaque(UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1), roughness: 0.94)
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
        case .wallGlow:
            // Il colore arriva a runtime dallo stato della stanza; senza, la
            // velatura non si vede.
            return UnlitMaterial(color: .clear)
        case .wallContact:
            return contactMaterial(texture: contactFalloffTexture, opacity: 0.30)
        case .groundContact:
            return contactMaterial(texture: groundContactTexture, opacity: 0.36)
        case .shutter:
            return shutterMaterial()
        case .awning:
            return awningMaterial()
        case .furniture:
            return furnitureMaterial(tint: nil)
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
            // Grigio neutro, non azzurro: il parapetto e' vetro fume', e
            // l'azzurro stonava con l'intonaco caldo dei muri.
            return transparent(UIColor(red: 0.72, green: 0.73, blue: 0.75, alpha: 1),
                               opacity: 0.62, roughness: 0.10)
        case .balconyTop:
            return transparent(UIColor(red: 0.86, green: 0.87, blue: 0.88, alpha: 1),
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

    /// La pozza di luce che una lampada accesa getta sul pavimento.
    ///
    /// È ciò che rende una luce riconoscibile **dall'alto**, dove il bulbo lo
    /// nasconde il primo muro: da lassù il pavimento si vede sempre.
    static func lampPoolMaterial(_ colour: UIColor) -> (any RealityKit.Material)? {
        guard let texture = radialFalloffTexture else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: colour, texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        return material
    }

    /// Il vetro di una lampada. Spenta è un puntino scuro che sta lì per essere
    /// toccato; accesa è la propria tinta.
    static func bulbMaterial(colour: UIColor, isOn: Bool) -> any RealityKit.Material {
        guard isOn else {
            // Spenta e' **un oggetto**, non un simbolo: una plafoniera bianca
            // opaca, PBR, che prende la luce della scena come tutto il resto
            // della casa. La sfera grigia semitrasparente di prima non
            // assomigliava a niente di reale — chi la vedeva si chiedeva cosa
            // ci facesse li' un pallone grigio. Su una parete chiara si
            // distingue per l'ombreggiatura, che e' come si distingue una
            // plafoniera vera; e accendendola si illumina, che e' esattamente
            // cio' che fa una lampada.
            return opaque(UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1), roughness: 0.4)
        }
        // **Gialla, e con il volume.** La prima gialla era unlit: niente
        // ombreggiatura per definizione, quindi un cerchio piatto accanto alla
        // spenta che invece e' PBR e ha corpo. Emissiva: la sfera resta
        // ombreggiata come un oggetto — stessa tridimensionalita' della
        // spenta — ma emette giallo. Tinta fissa, NON quella dell'accessorio:
        // il colore vero resta a fascio e pozza.
        var lit = PhysicallyBasedMaterial()
        lit.baseColor = .init(tint: UIColor(red: 1.0, green: 0.83, blue: 0.36, alpha: 1))
        lit.emissiveColor = .init(color: UIColor(red: 1.0, green: 0.78, blue: 0.28, alpha: 1))
        lit.roughness = 0.4
        lit.metallic = 0.0
        return lit
    }

    static func lampMarkerMaterial(isOn: Bool) -> any RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        let colour = isOn
            ? UIColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1)
            : UIColor(red: 0.42, green: 0.48, blue: 0.56, alpha: 1)
        material.baseColor = .init(tint: colour)
        material.emissiveColor = .init(color: colour.withAlphaComponent(isOn ? 0.75 : 0.25))
        material.roughness = 0.32
        material.metallic = 0.0
        return material
    }

    private static func lightened(_ colour: UIColor, by amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return colour }
        return UIColor(red: red + (1 - red) * amount,
                       green: green + (1 - green) * amount,
                       blue: blue + (1 - blue) * amount,
                       alpha: 1)
    }

    /// Il fascio di luce, dal bulbo verso il pavimento.
    ///
    /// Un alone sferico attorno alla lampada sembrava un pianeta: una palla
    /// luminosa che non dice da che parte va la luce. Un cono lo dice, ed è
    /// anche ciò che si vede davvero quando la luce attraversa l'aria.
    ///
    /// La texture è la stessa sfumatura verticale delle pareti: piena
    /// all'apice, spenta alla base — un fascio è più intenso vicino alla
    /// sorgente.
    static func lampBeamMaterial(colour: UIColor, brightness: Double) -> (any RealityKit.Material)? {
        guard let texture = verticalFalloffTexture else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: colour, texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: Float(0.10 + 0.16 * brightness)))
        return material
    }

    /// Il contorno della stanza selezionata.
    ///
    /// La selezione **non tinge più il pavimento**. Con uno strato ambientale
    /// attivo l'ambra della selezione si sommava alla velatura di stato e usciva
    /// un arancione che poteva voler dire due cose diverse: «l'hai toccata tu»
    /// oppure «qui l'aria è pessima». Un contorno vive su un canale suo e non si
    /// somma a niente.
    static func selectionOutlineMaterial() -> any RealityKit.Material {
        var material = UnlitMaterial(color: UIColor(red: 1.0, green: 0.84, blue: 0.42, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.92))
        return material
    }

    /// Lo stelo della bandierina di stanza.
    static func flagStemMaterial() -> any RealityKit.Material {
        opaque(UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1), roughness: 0.35, metallic: 0.2)
    }

    /// L'etichetta in cima allo stelo, disegnata come immagine e appiccicata a
    /// un rettangolo. **Unlit**: è un'etichetta, non una superficie, e non deve
    /// scurirsi quando la stanza è in ombra — è proprio quando serve leggerla.
    /// Restituisce anche le **proporzioni** della capsula: la larghezza dipende
    /// da cosa c'e' scritto, e il piano che la porta deve seguirla o il testo
    /// nuota in una capsula vuota.
    static func flagLabelMaterial(title: String, value: String, accent: UIColor?)
        -> (material: any RealityKit.Material, aspect: CGFloat)? {
        guard let image = flagLabelImage(title: title, value: value, accent: accent),
              let texture = try? TextureResource(image: image,
                                                 withName: nil,
                                                 options: .init(semantic: .color))
        else { return nil }

        var material = UnlitMaterial(texture: texture)
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return (material, CGFloat(image.width) / CGFloat(image.height))
    }

    /// Una **capsula**, non una scheda.
    ///
    /// La versione a due righe con la barra di stato in fondo diceva le stesse
    /// cose ma pesava come una card, e sopra un modello 3D sette card sono sette
    /// oggetti che competono con la casa. Una riga sola, angoli pieni, il colore
    /// affidato a un punto e al bordo: si legge uguale e non ruba la scena.
    ///
    /// `accent` a `nil` vuol dire **non c'e' nessuno stato da dire**: niente
    /// pallino e bordo neutro. Un pallino colorato su una capsula che porta solo
    /// il nome di una stanza si legge come un semaforo, e sarebbe un semaforo
    /// che non misura niente.
    ///
    /// La larghezza segue il testo: «Cucina» e «68% Discreta» non meritano la
    /// stessa capsula, e a larghezza fissa la prima resta mezza vuota.
    private static func flagLabelImage(title: String, value: String, accent: UIColor?) -> CGImage? {
        let dotDiameter: CGFloat = 20
        let leading: CGFloat = accent == nil ? 28 : 22 + dotDiameter + 14
        let measured = composedLine(title: title, value: value, scale: 1).size().width
        let size = CGSize(width: max(200, (leading + min(measured, 560) + 28).rounded()),
                          height: 112)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let pill = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5)
            let radius = pill.height / 2

            UIColor(white: 0.07, alpha: 0.88).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: radius).fill()

            (accent?.withAlphaComponent(0.6) ?? UIColor(white: 1, alpha: 0.22)).setStroke()
            let border = UIBezierPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerRadius: radius)
            border.lineWidth = 3
            border.stroke()

            if let accent {
                // Il pallino di stato al posto della barra: stesso colore, un
                // decimo dell'ingombro.
                let dot = CGRect(x: pill.minX + 22, y: pill.midY - dotDiameter / 2,
                                 width: dotDiameter, height: dotDiameter)
                accent.setFill()
                UIBezierPath(ovalIn: dot).fill()
            }

            let textArea = CGRect(x: pill.minX + leading, y: pill.minY,
                                  width: pill.maxX - pill.minX - leading - 22, height: pill.height)
            drawRow(title: title, value: value, in: textArea)
        }
        return image.cgImage
    }

    /// Nome e valore sulla stessa riga, con il valore in evidenza. Se non ci
    /// stanno si rimpiccioliscono **insieme**, o cambierebbe la gerarchia.
    private static func drawRow(title: String, value: String, in area: CGRect) {
        var scale: CGFloat = 1
        var line = composedLine(title: title, value: value, scale: scale)
        while line.size().width > area.width && scale > 0.4 {
            scale -= 0.06
            line = composedLine(title: title, value: value, scale: scale)
        }

        let measured = line.size()
        line.draw(at: CGPoint(x: area.minX, y: area.midY - measured.height / 2))
    }

    /// Titolo vuoto vuol dire **il valore e' tutto**: niente spaziatura fantasma
    /// prima del testo.
    private static func composedLine(title: String, value: String, scale: CGFloat) -> NSAttributedString {
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40 * scale, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        guard !title.isEmpty else {
            return NSAttributedString(string: value, attributes: valueAttributes)
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34 * scale, weight: .medium),
            .foregroundColor: UIColor(white: 1, alpha: 0.66)
        ]
        let composed = NSMutableAttributedString(string: title + "  ", attributes: titleAttributes)
        composed.append(NSAttributedString(string: value, attributes: valueAttributes))
        return composed
    }

    /// Il piano su cui la casa appoggia e su cui cade la sua ombra.
    ///
    /// Della stessa tinta dello sfondo, appena più scuro: non deve leggersi come
    /// un pavimento in più, solo dare all'ombra una superficie e alla casa un
    /// appoggio invece del vuoto.
    /// Il piano su cui la casa appoggia, con la casa **in mezzo a qualcosa**.
    ///
    /// Era la stessa tinta piatta dello sfondo: nessun orizzonte, nessuno
    /// stacco, e il modello finiva sospeso in un campo uniforme — da qui
    /// l'impressione che il 3D «spenga tutto». La tinta resta quella scelta in
    /// 2D, perche' e' una scelta dell'utente: cambia che ora ha un centro
    /// chiaro sotto la casa e si spegne verso il bordo, che e' esattamente cio'
    /// che fa un orizzonte.
    /// Il plinto del diorama: un gradino della stessa famiglia del fondale,
    /// appena più chiaro — deve staccare, non brillare. Bianco pieno rubava
    /// luce alla casa (giudizio dell'utente sui primi screenshot).
    static func plinthMaterial() -> any RealityKit.Material {
        opaque(UIColor(red: 0.930, green: 0.915, blue: 0.885, alpha: 1), roughness: 0.9)
    }

    /// I tre atti del cielo, decisi dall'elevazione VERA del sole: giorno
    /// azzurro, crepuscolo d'oro e malva (alba e tramonto), notte blu con le
    /// stelle. Il fondale piatto era corretto ma non raccontava niente —
    /// questo racconta l'ora di casa tua.
    enum SkyPhase {
        case day
        case dawn
        case dusk
        case night

        /// L'azimut distingue alba (est, < 180°) da tramonto (ovest): i due
        /// crepuscoli hanno palette diverse — rosa che vira al giallo la
        /// mattina, oro e ambra la sera.
        static func forSun(elevation: Double, azimuth: Double) -> SkyPhase {
            if elevation < -8 { return .night }
            if elevation < 10 { return azimuth < 180 ? .dawn : .dusk }
            return .day
        }
    }

    static func skyBackdropMaterial(phase: SkyPhase) -> UnlitMaterial {
        var material = UnlitMaterial(color: .white)
        material.faceCulling = .front
        let texture: TextureResource? = switch phase {
        case .day: daySkyTexture
        case .dawn: dawnSkyTexture
        case .dusk: duskSkyTexture
        case .night: nightSkyTexture
        }
        guard let texture else {
            material.color = .init(tint: UIColor(red: 0.87, green: 0.86, blue: 0.83, alpha: 1))
            return material
        }
        material.color = .init(tint: .white, texture: .init(texture, sampler: clampSampler))
        return material
    }

    private static let daySkyTexture: TextureResource? = skyGradientTexture(colors: [
        UIColor(red: 0.60, green: 0.72, blue: 0.85, alpha: 1),   // zenit: azzurro vero
        UIColor(red: 0.78, green: 0.84, blue: 0.89, alpha: 1),
        UIColor(red: 0.91, green: 0.89, blue: 0.84, alpha: 1),   // orizzonte: crema caldo
        UIColor(red: 0.88, green: 0.85, blue: 0.80, alpha: 1)    // sotto l'orizzonte
    ], locations: [0, 0.38, 0.54, 1])

    /// Le basi crepuscolari sono SOBRIE su tutto il giro d'orizzonte: il
    /// colore acceso vive nel bagliore posizionato sull'azimut del sole —
    /// prima la fascia d'oro avvolgeva anche il lato dove il sole non era.
    private static let dawnSkyTexture: TextureResource? = skyGradientTexture(colors: [
        UIColor(red: 0.36, green: 0.40, blue: 0.58, alpha: 1),   // zenit ancora notte
        UIColor(red: 0.62, green: 0.55, blue: 0.62, alpha: 1),   // malva freddo
        UIColor(red: 0.88, green: 0.76, blue: 0.72, alpha: 1),   // rosa pallido
        UIColor(red: 0.55, green: 0.47, blue: 0.45, alpha: 1)
    ], locations: [0, 0.34, 0.53, 1])

    private static let duskSkyTexture: TextureResource? = skyGradientTexture(colors: [
        UIColor(red: 0.30, green: 0.34, blue: 0.52, alpha: 1),
        UIColor(red: 0.55, green: 0.46, blue: 0.55, alpha: 1),   // malva
        UIColor(red: 0.82, green: 0.66, blue: 0.55, alpha: 1),   // ambra tenue
        UIColor(red: 0.52, green: 0.42, blue: 0.38, alpha: 1)
    ], locations: [0, 0.32, 0.52, 1])

    private static let nightSkyTexture: TextureResource? = skyGradientTexture(colors: [
        UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 1),
        UIColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1),
        UIColor(red: 0.17, green: 0.18, blue: 0.24, alpha: 1),
        UIColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1)
    ], locations: [0, 0.40, 0.55, 1], stars: true)

    private static func skyGradientTexture(colors: [UIColor], locations: [CGFloat],
                                           stars: Bool = false) -> TextureResource? {
        let size = CGSize(width: 256, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors.map(\.cgColor) as CFArray,
                                            locations: locations) else { return }
            context.cgContext.drawLinearGradient(gradient,
                                                 start: .zero,
                                                 end: CGPoint(x: 0, y: size.height),
                                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            guard stars else { return }
            // Stelle deterministiche nel terzo alto del cielo: puntini,
            // qualcuno appena piu' vivo. Un cielo notturno senza stelle e'
            // solo un colore scuro.
            var seed: UInt64 = 0x5DEECE66D
            func roll() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
            }
            for _ in 0..<130 {
                let x = roll() * size.width
                let y = roll() * size.height * 0.42
                let radius = 0.5 + roll() * 0.9
                let alpha = 0.35 + roll() * 0.55
                context.cgContext.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: x, y: y,
                                                         width: radius * 2, height: radius * 2))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil,
                                    options: .init(semantic: .color))
    }

    /// Il bagliore all'orizzonte, DOVE sta il sole: un pannello unlit con
    /// gradiente radiale che il coordinatore posiziona sull'azimut solare
    /// vero — cosi' il tramonto sta a ovest e l'alba a est per costruzione.
    /// `nil` di giorno pieno e di notte.
    static func horizonGlowMaterial(phase: SkyPhase) -> UnlitMaterial? {
        let texture: TextureResource? = switch phase {
        case .dawn: dawnGlowTexture
        case .dusk: duskGlowTexture
        case .day, .night: nil
        }
        guard let texture else { return nil }
        var material = UnlitMaterial(color: .white)
        material.color = .init(tint: .white, texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(scale: 1))
        material.faceCulling = .none
        return material
    }

    /// Alba: cuore rosa salmone che vira al giallo tenue.
    private static let dawnGlowTexture: TextureResource? = radialGlowTexture(
        core: UIColor(red: 0.99, green: 0.72, blue: 0.66, alpha: 0.88),
        mid: UIColor(red: 0.99, green: 0.86, blue: 0.60, alpha: 0.45)
    )

    /// Tramonto: oro pieno che sfuma in ambra.
    private static let duskGlowTexture: TextureResource? = radialGlowTexture(
        core: UIColor(red: 0.99, green: 0.78, blue: 0.45, alpha: 0.90),
        mid: UIColor(red: 0.90, green: 0.55, blue: 0.38, alpha: 0.42)
    )

    private static func radialGlowTexture(core: UIColor, mid: UIColor) -> TextureResource? {
        let side = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { context in
            let colours = [core.cgColor, mid.cgColor, mid.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours, locations: [0, 0.45, 1]) else { return }
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            context.cgContext.drawRadialGradient(gradient,
                                                 startCenter: centre, startRadius: 0,
                                                 endCenter: centre, endRadius: CGFloat(side) / 2,
                                                 options: [])
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil,
                                    options: .init(semantic: .color))
    }

    /// Il terreno del palco segue il cielo: greige di giorno, terra brunita
    /// al crepuscolo, blu-grigio scuro di notte — cupola e terreno si
    /// fondono all'orizzonte invece di staccarsi in una banda.
    static func stageGroundMaterial(phase: SkyPhase, background: UIColor) -> any RealityKit.Material {
        switch phase {
        case .day:
            return groundMaterial(background: background)
        case .dawn, .dusk:
            return groundMaterial(background: UIColor(red: 0.48, green: 0.41, blue: 0.37, alpha: 1))
        case .night:
            return groundMaterial(background: UIColor(red: 0.155, green: 0.165, blue: 0.215, alpha: 1))
        }
    }

    static func groundMaterial(background: UIColor) -> any RealityKit.Material {
        guard let image = groundGradientImage(background),
              let texture = try? TextureResource(image: image, withName: nil,
                                                 options: .init(semantic: .color))
        else { return opaque(darkened(background, by: 0.12), roughness: 0.98) }

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture, sampler: clampSampler))
        material.roughness = 0.98
        material.metallic = 0.0
        return material
    }

    private static func groundGradientImage(_ background: UIColor) -> CGImage? {
        let side = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { context in
            let colours = [lightened(background, by: 0.12).cgColor,
                           darkened(background, by: 0.10).cgColor,
                           darkened(background, by: 0.42).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours,
                                            locations: [0, 0.28, 1]) else { return }
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            context.cgContext.drawRadialGradient(gradient,
                                                 startCenter: centre, startRadius: 0,
                                                 endCenter: centre, endRadius: CGFloat(side) * 0.62,
                                                 options: [.drawsAfterEndLocation])
        }
        return image.cgImage
    }

    private static func darkened(_ colour: UIColor, by amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return colour }
        return UIColor(red: red * (1 - amount),
                       green: green * (1 - amount),
                       blue: blue * (1 - amount),
                       alpha: 1)
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

    /// La macchia di calore sul pavimento.
    ///
    /// **Senza bordi.** Un poligono pieno che finisce netto contro le pareti si
    /// legge come vernice; una macchia che sfuma prima di arrivarci si legge
    /// come una misura. È tutta la differenza fra una stanza colorata e una
    /// stanza che sta dicendo qualcosa.
    static func roomHeatMaterial(_ colour: UIColor) -> (any RealityKit.Material)? {
        guard let texture = radialFalloffTexture else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: colour, texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        return material
    }

    /// Bianco pieno al centro, trasparente al bordo. Una sola texture per tutte
    /// le stanze: il colore lo mette il tint.
    private static let radialFalloffTexture: TextureResource? = {
        let side = 192
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { context in
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            let colours = [UIColor(white: 1, alpha: 1).cgColor,
                           UIColor(white: 1, alpha: 0.82).cgColor,
                           UIColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours,
                                            locations: [0, 0.42, 1]) else { return }
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: centre, startRadius: 0,
                endCenter: centre, endRadius: CGFloat(side) / 2,
                options: []
            )
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    private static let clampSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToZero
        descriptor.tAddressMode = .clampToZero
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        return .init(descriptor)
    }()

    /// Il campo visivo di una telecamera.
    ///
    /// Il viola della sicurezza, e non un colore nuovo: chi vede questo cono sta
    /// gia' guardando lo strato Sicurezza, e una terza tinta in quella scena
    /// vorrebbe dire una terza cosa da imparare.
    static func cameraConeMaterial() -> (any RealityKit.Material)? {
        guard let texture = verticalFalloffTexture else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(red: 0.68, green: 0.52, blue: 0.92, alpha: 1),
                               texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.34))
        return material
    }

    /// Il vetro di una stanza accesa, visto da fuori.
    ///
    /// **Unlit**: è luce che esce, non una superficie che la riceve, e
    /// ombreggiarla vorrebbe dire spegnerla proprio dove serve — di notte, che è
    /// l'unico momento in cui esiste.
    static func litWindowMaterial() -> (any RealityKit.Material)? {
        var material = UnlitMaterial(color: UIColor(red: 1.0, green: 0.87, blue: 0.62, alpha: 1))
        // Un vetro acceso resta un vetro: a 0.72 era una lastra gialla piena e
        // dentro casa non si vedeva piu' niente. A 0.38 il caldo si vede e la
        // stanza pure.
        material.blending = .transparent(opacity: .init(floatLiteral: 0.38))
        return material
    }

    /// Il respiro di una stanza abitata: un alone caldo e tenue che pulsa al
    /// punto piu' interno. Non e' una tinta di strato — quelle parlano la
    /// lingua degli avvisi — e' vita: un PIR non sa chi, quindi il modello
    /// dice solo «qui c'e' qualcuno».
    static func presenceGlowMaterial() -> (any RealityKit.Material)? {
        guard let texture = radialFalloffTexture else { return nil }
        var glow = UnlitMaterial()
        // ⚠️ **Ambra decisa, non bianco-caldo timido.** Il disco c'era ed era
        // al posto giusto — l'ha provato la diagnostica — ma bianco-caldo al
        // 30% sopra un pavimento crema in piena luce e' contrasto zero:
        // invisibile per tinta, non per posizione.
        glow.color = .init(tint: UIColor(red: 1.0, green: 0.72, blue: 0.36, alpha: 1),
                           texture: .init(texture, sampler: clampSampler))
        glow.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        return glow
    }

    /// Il muro reso vetro, **a richiesta**: per sbirciare dentro dalle
    /// inquadrature basse senza rinunciare — di default — alla casa vera.
    /// Stessa tinta dell'intonaco, cosi' accendendola la casa non cambia
    /// colore, solo corpo.
    static func ghostWallMaterial() -> any RealityKit.Material {
        transparent(UIColor(red: 0.86, green: 0.85, blue: 0.83, alpha: 1),
                    opacity: 0.26, roughness: 0.9)
    }

    /// Un pezzo d'arredo: la tinta la decide l'estrusore membro per membro —
    /// gambe scure, piani in legno, imbottiti col colore dell'oggetto.
    static func furnitureMaterial(tint: UIColor?,
                                  style: FurnitureMaterialStyle = .plain) -> any RealityKit.Material {
        let base = tint ?? UIColor(red: 0.80, green: 0.76, blue: 0.71, alpha: 1)
        switch style {
        case .wood:
            return texturedOpaque(base, texture: woodGrainTexture, roughness: 0.68)
        case .fabric:
            return texturedOpaque(base, texture: fabricWeaveTexture, roughness: 0.96)
        case .stone:
            return texturedOpaque(base, texture: stoneSpeckleTexture, roughness: 0.72)
        case .glass:
            return opaque(base, roughness: 0.14, metallic: 0.05)
        case .plain:
            return opaque(base, roughness: 0.72)
        }
    }

    /// Il corpo di un apparecchio a muro — split, radiatore, centralina.
    ///
    /// La tinta e' **lo stato gia' tradotto**: caldo/freddo per il clima,
    /// viola/rosso per l'antifurto. Il materiale non sa di chi e': sa solo
    /// che un corpo bianco e' un corpo che non ha niente da dire.
    static func deviceBodyMaterial(tint: UIColor) -> any RealityKit.Material {
        opaque(tint, roughness: 0.42)
    }

    /// Il telo di una tenda da sole: righe, che e' come si riconosce una tenda
    /// da una tettoia. Il passo lo decide la coordinata, in metri.
    private static func awningMaterial() -> PhysicallyBasedMaterial {
        var material = opaque(UIColor(red: 0.86, green: 0.80, blue: 0.72, alpha: 1), roughness: 0.86)
        guard let texture = awningStripeTexture else { return material }
        material.baseColor = .init(tint: .white, texture: .init(texture, sampler: repeatSampler))
        return material
    }

    private static func texturedOpaque(_ color: UIColor,
                                       texture: TextureResource?,
                                       roughness: Float,
                                       metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = opaque(color, roughness: roughness, metallic: metallic)
        guard let texture else { return material }
        material.baseColor = .init(tint: color, texture: .init(texture, sampler: repeatSampler))
        return material
    }

    /// Grana orizzontale molto leggera: deve dire "legno" senza trasformare un
    /// tavolo visto dall'alto in una texture rumorosa.
    private static let woodGrainTexture: TextureResource? = {
        let size = CGSize(width: 128, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.78, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            for row in stride(from: 3, to: Int(size.height), by: 5) {
                let alpha = CGFloat(0.10 + Double(row % 3) * 0.035)
                UIColor(white: 0.38, alpha: alpha).setStroke()
                let path = UIBezierPath()
                path.lineWidth = row.isMultiple(of: 2) ? 1 : 2
                path.move(to: CGPoint(x: 0, y: CGFloat(row)))
                for x in stride(from: 0, through: Int(size.width), by: 16) {
                    path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(row) + sin(CGFloat(x) * 0.18) * 1.4))
                }
                path.stroke()
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    /// Trama incrociata a basso contrasto per imbottiti: leggibile sulle
    /// poltrone, ma abbastanza fine da non sporcare la vista generale.
    private static let fabricWeaveTexture: TextureResource? = {
        let size = CGSize(width: 48, height: 48)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.74, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.56, alpha: 0.30).setFill()
            for index in stride(from: 0, to: Int(size.width), by: 6) {
                context.cgContext.fill(CGRect(x: CGFloat(index), y: 0, width: 1, height: size.height))
                context.cgContext.fill(CGRect(x: 0, y: CGFloat(index), width: size.width, height: 1))
            }
            UIColor(white: 0.92, alpha: 0.20).setFill()
            for index in stride(from: 3, to: Int(size.width), by: 6) {
                context.cgContext.fill(CGRect(x: CGFloat(index), y: 0, width: 1, height: size.height))
                context.cgContext.fill(CGRect(x: 0, y: CGFloat(index), width: size.width, height: 1))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    private static let stoneSpeckleTexture: TextureResource? = {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.72, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            for index in 0..<120 {
                let x = CGFloat((index * 17) % Int(size.width))
                let y = CGFloat((index * 31) % Int(size.height))
                let shade = CGFloat(0.50 + Double(index % 5) * 0.06)
                UIColor(white: shade, alpha: 0.24).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    private static let awningStripeTexture: TextureResource? = {
        let size = CGSize(width: 64, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.70, green: 0.55, blue: 0.44, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 30, height: size.height))
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    /// Una tapparella: stecche orizzontali, non una lastra liscia.
    ///
    /// Senza le stecche il quadrilatero si legge come «la finestra e' murata».
    /// Sono l'unica cosa che dice che quello e' un oggetto che scorre, e costano
    /// una texture da otto pixel per sessantaquattro.
    private static func shutterMaterial() -> PhysicallyBasedMaterial {
        var material = opaque(UIColor(red: 0.80, green: 0.79, blue: 0.76, alpha: 1), roughness: 0.62)
        guard let texture = shutterSlatTexture else { return material }
        material.baseColor = .init(tint: .white, texture: .init(texture, sampler: repeatSampler))
        return material
    }

    /// Una stecca chiara con la fuga scura sotto. La ripetizione la fa la
    /// coordinata, che sta in metri: cosi' il passo resta lo stesso su una
    /// finestrella del bagno e su una portafinestra.
    private static let shutterSlatTexture: TextureResource? = {
        let size = CGSize(width: 8, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.84, green: 0.83, blue: 0.79, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.55, green: 0.54, blue: 0.51, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width, height: 5))
            UIColor(red: 0.92, green: 0.91, blue: 0.88, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 5, width: size.width, height: 4))
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    /// L'ombra di contatto, di muro o di arredo.
    ///
    /// **Unlit**, e non e' una svista: e' la mancanza di luce, e illuminarla
    /// vorrebbe dire schiarirla proprio dove la luce non arriva. La tinta non e'
    /// nera ma un blu molto scuro — l'ombra prende il colore del cielo che la
    /// riempie, e un nero puro su un interno chiaro sembra sporco.
    private static func contactMaterial(texture: TextureResource?,
                                        opacity: Float) -> any RealityKit.Material {
        guard let texture else { return UnlitMaterial(color: .clear) }
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(red: 0.13, green: 0.14, blue: 0.19, alpha: 1),
                               texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    /// Piena a terra e spenta in fretta salendo.
    ///
    /// Non riusa `verticalFalloffTexture`, che sfuma quasi lineare su due metri
    /// e mezzo: un'occlusione si concentra nei primi centimetri, e la stessa
    /// curva stesa su trenta centimetri leggeva come una fascia dipinta.
    private static let contactFalloffTexture: TextureResource? = {
        let size = CGSize(width: 8, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colours = [UIColor(white: 1, alpha: 0).cgColor,
                           UIColor(white: 1, alpha: 0.08).cgColor,
                           UIColor(white: 1, alpha: 0.42).cgColor,
                           UIColor(white: 1, alpha: 1).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours,
                                            locations: [0, 0.52, 0.84, 1]) else { return }
            // Come per la velatura di stato: l'estremo pieno sta in fondo
            // all'immagine, perche' `v = 0` pesca il fondo, non la cima.
            context.cgContext.drawLinearGradient(gradient,
                                                 start: CGPoint(x: 0, y: 0),
                                                 end: CGPoint(x: 0, y: size.height),
                                                 options: [])
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    /// La macchia sotto un mobile: nucleo pieno, sfumatura solo nel margine.
    ///
    /// Un alone radiale sarebbe sbagliato su un letto, che e' lungo il doppio di
    /// quanto e' largo: alle testate si spegnerebbe molto prima che ai fianchi.
    /// Rettangoli arrotondati concentrici seguono qualsiasi proporzione, perche'
    /// la sfumatura vive nella **frazione di margine**, uguale sui due assi.
    private static let groundContactTexture: TextureResource? = {
        let side = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { _ in
            let steps = 28
            // Il margine e' un terzo del lato: fuori sta il quadrato allargato
            // a 1.5x dall'estrusore, dentro l'ingombro vero del mobile.
            let margin = CGFloat(side) / 6
            for step in 0...steps {
                let inset = margin * CGFloat(step) / CGFloat(steps)
                let rect = CGRect(x: inset, y: inset,
                                  width: CGFloat(side) - inset * 2,
                                  height: CGFloat(side) - inset * 2)
                UIColor(white: 1, alpha: 0.10).setFill()
                UIBezierPath(roundedRect: rect,
                             cornerRadius: min(rect.width, rect.height) * 0.26).fill()
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

    /// La velatura sulla parete: piena in basso, spenta salendo.
    ///
    /// Prima erano tre fasce a intensità decrescente, e i gradini si vedevano —
    /// il colore tornava a leggersi come vernice a strisce. Una texture sfumata
    /// su una superficie traslucida fa quello che fa la macchia sul pavimento:
    /// non ha bordi, quindi non ha una forma da riconoscere.
    static func wallGlowMaterial(_ colour: UIColor) -> (any RealityKit.Material)? {
        guard let texture = verticalFalloffTexture else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: colour, texture: .init(texture, sampler: clampSampler))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.42))
        return material
    }

    /// Opaca alla base, trasparente in cima. Una sola per tutte le stanze: il
    /// colore lo mette il tint.
    private static let verticalFalloffTexture: TextureResource? = {
        let size = CGSize(width: 8, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colours = [UIColor(white: 1, alpha: 0).cgColor,
                           UIColor(white: 1, alpha: 0.35).cgColor,
                           UIColor(white: 1, alpha: 1).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colours,
                                            locations: [0, 0.45, 1]) else { return }
            // Nell'immagine la y cresce verso il basso: l'estremo pieno è in
            // fondo, ed è quello che finisce a terra sul muro.
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
    }()

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
