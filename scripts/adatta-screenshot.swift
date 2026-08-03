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
// Uso:  swift scripts/adatta-screenshot.swift <cartella> [larghezza altezza]
//       Default 1242 2688 (6,5" verticale; in orizzontale si scambiano).
//       Scrive in <cartella>/appstore/ — gli originali non si toccano.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Uso: swift adatta-screenshot.swift <cartella> [larghezza altezza]")
    exit(1)
}

let sourceDir = URL(fileURLWithPath: args[1])
let targetW = args.count >= 4 ? Int(args[2]) ?? 1242 : 1242
let targetH = args.count >= 4 ? Int(args[3]) ?? 2688 : 2688

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

    // Si ingrandisce sul lato che richiede il fattore maggiore, così l'altro
    // resta in eccesso e non si scoprono bordi vuoti; l'eccesso viene poi
    // tagliato al centro. Nessuna deformazione: la proporzione resta quella.
    let scale = max(CGFloat(tw) / CGFloat(srcW), CGFloat(th) / CGFloat(srcH))
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
