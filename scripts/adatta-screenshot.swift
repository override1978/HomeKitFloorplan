#!/usr/bin/env swift
//
// Adatta le catture schermo dell'iPhone alle misure che App Store Connect
// pretende, riconoscendo da sé verticale e orizzontale, e **togliendo il canale
// alfa**.
//
// Perché serve, e perché non basta `sips`:
//
// 1. Nessun iPhone cattura in una misura accettata. Il 17 Pro fa 1206x2622, e
//    nessuno slot vuole quel numero.
// 2. Le catture di iOS sono RGBA anche quando sono completamente opache, e
//    App Store Connect le **rifiuta**: «Le immagini non possono contenere
//    canali alfa o trasparenze». `sips` non ha alcuna opzione per rimuoverlo, e
//    il giro attraverso JPEG per perderlo degrada il testo.
//
// Qui l'immagine viene ridisegnata in un contesto senza alfa: nessuna perdita,
// nessun artefatto.
//
// ⚠️ LE MISURE RICHIESTE CAMBIANO. Ad agosto 2026 lo slot obbligatorio era il
// 6,5"; poco prima era il 6,9". **Guarda i pixel che la pagina di caricamento
// chiede** e passali come argomenti se non corrispondono al default.
//
// DUE MODI, e la scelta conta:
//
//   riempi (default)  ingrandisce fino a coprire e ritaglia l'eccesso al centro.
//                     Giusto quando la proporzione di partenza è quasi quella
//                     d'arrivo — iPhone: 0,4600 contro 0,4620, si perde nulla.
//
//   --adatta          rimpicciolisce fino a farci stare tutto e riempie il
//                     resto con bande del colore dell'angolo dell'immagine.
//                     Necessario quando le proporzioni divergono — iPad: da
//                     1,44 (2360x1640) a 1,33 servirebbero ~107 pixel per lato,
//                     e lì ci vivono i comandi della barra superiore.
//
// Il colore delle bande è campionato dall'angolo in alto a sinistra, così su
// uno sfondo scuro non si vedono affatto.
//
// Uso:  swift scripts/adatta-screenshot.swift <cartella> [larghezza altezza] [--adatta]
//       Default 1242 2688 (6,5" verticale; in orizzontale si scambiano).
//       Scrive in <cartella>/appstore/ — gli originali non si toccano.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var args = CommandLine.arguments
let padInsteadOfCrop = args.contains("--adatta")
args.removeAll { $0 == "--adatta" }

guard args.count >= 2 else {
    print("Uso: swift adatta-screenshot.swift <cartella> [larghezza altezza] [--adatta]")
    exit(1)
}

let sourceDir = URL(fileURLWithPath: args[1])
let givenW = args.count >= 4 ? Int(args[2]) ?? 1242 : 1242
let givenH = args.count >= 4 ? Int(args[3]) ?? 2688 : 2688

// Le due misure vengono normalizzate a verticale, e sarà l'orientamento di
// ciascuna immagine a scambiarle. Senza questo, passando "2732 2048" per delle
// catture orizzontali si ottiene silenziosamente il verticale: lo scambio
// avviene due volte. Ora l'ordine in cui le scrivi non conta.
let targetW = min(givenW, givenH)
let targetH = max(givenW, givenH)

let outDir = sourceDir.appendingPathComponent("appstore")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let extensions: Set<String> = ["png", "jpg", "jpeg"]
let files = ((try? FileManager.default.contentsOfDirectory(at: sourceDir,
                                                          includingPropertiesForKeys: nil)) ?? [])
    .filter { extensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    print("Nessuna immagine in \(sourceDir.path)")
    exit(1)
}

/// Colore dello sfondo, campionato sul **bordo sinistro a metà altezza**.
///
/// NON sull'angolo: le catture di iOS riproducono gli angoli arrotondati dello
/// schermo, quindi il pixel (0,0) è nero puro qualunque cosa mostri l'app. Su
/// una planimetria scura quel nero somigliava allo sfondo e l'errore passava
/// inosservato; su una chiara ha prodotto bande nere attorno a un'immagine
/// color crema.
func backgroundColor(of image: CGImage) -> CGColor? {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &pixel,
                              width: 1, height: 1,
                              bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    // Si trasla l'immagine così che il pixel voluto cada nel contesto 1x1.
    // L'asse y di CoreGraphics parte dal basso, da cui height - 1 - y.
    let y = image.height / 2
    ctx.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1 - y),
                               width: CGFloat(image.width), height: CGFloat(image.height)))
    return CGColor(red: CGFloat(pixel[0]) / 255,
                   green: CGFloat(pixel[1]) / 255,
                   blue: CGFloat(pixel[2]) / 255,
                   alpha: 1)
}

var failures = 0

for file in files {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("\(file.lastPathComponent): non leggibile")
        failures += 1
        continue
    }

    let srcW = image.width
    let srcH = image.height
    // In orizzontale il bersaglio è lo stesso con i due numeri scambiati.
    let (tw, th) = srcW < srcH ? (targetW, targetH) : (targetH, targetW)

    // Riempi: si ingrandisce sul lato che richiede il fattore maggiore, l'altro
    // resta in eccesso e viene tagliato al centro.
    // Adatta: si sceglie il fattore minore, così l'immagine ci sta tutta e
    // avanza spazio ai lati o sopra e sotto.
    // In entrambi i casi il fattore è uno solo per le due dimensioni: la
    // proporzione non viene mai forzata.
    let scale = padInsteadOfCrop
        ? min(CGFloat(tw) / CGFloat(srcW), CGFloat(th) / CGFloat(srcH))
        : max(CGFloat(tw) / CGFloat(srcW), CGFloat(th) / CGFloat(srcH))
    let drawW = CGFloat(srcW) * scale
    let drawH = CGFloat(srcH) * scale
    let originX = (CGFloat(tw) - drawW) / 2
    let originY = (CGFloat(th) - drawH) / 2

    // `noneSkipLast` è il punto: il contesto non ha canale alfa, quindi ciò che
    // ne esce non può averlo.
    guard let context = CGContext(data: nil,
                                  width: tw,
                                  height: th,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        print("\(file.lastPathComponent): contesto non creato")
        failures += 1
        continue
    }

    // Le bande prendono il colore di sfondo dell'immagine stessa, così si
    // fondono col disegno invece di incorniciarlo.
    if padInsteadOfCrop, let background = backgroundColor(of: image) {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: tw, height: th))
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))

    guard let output = context.makeImage() else {
        print("\(file.lastPathComponent): immagine non generata")
        failures += 1
        continue
    }

    let destURL = outDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png")
    guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1, nil) else {
        print("\(file.lastPathComponent): destinazione non creata")
        failures += 1
        continue
    }
    CGImageDestinationAddImage(destination, output, nil)

    let ok = CGImageDestinationFinalize(destination)
    let name = file.lastPathComponent.padding(toLength: max(40, file.lastPathComponent.count),
                                              withPad: " ", startingAt: 0)
    if ok && output.width == tw && output.height == th {
        print("\(name) \(srcW)x\(srcH) -> \(tw)x\(th)  ok, senza alfa")
    } else {
        print("\(name) \(srcW)x\(srcH) -> FALLITO")
        failures += 1
    }
}

print("\nPronti in: \(outDir.path)")
if failures > 0 {
    print("\(failures) file non convertiti.")
    exit(1)
}
