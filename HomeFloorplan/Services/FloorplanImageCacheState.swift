import SwiftUI

struct FloorplanImageCacheState {
    var image: UIImage?
    var imageDate: Date = .distantPast
    var isLoading = false
    /// Stamp della decodifica attualmente in volo. Serve a distinguere "sto già
    /// caricando proprio questa immagine" (da ignorare) da "ne è arrivata una
    /// più recente mentre caricavo" (da ricaricare).
    var loadingDate: Date?
}

struct FloorplanImageLoader {
    @Binding var cache: FloorplanImageCacheState

    func refresh(for floorplan: Floorplan) {
        let stamp = floorplan.updatedAt

        // Già a schermo e aggiornata: niente da fare.
        if stamp == cache.imageDate, cache.image != nil { return }

        // Decodifica già in corso PER QUESTO stesso stamp: senza questa guardia
        // ogni chiamata ne avviava un'altra — `imageDate` veniva scritta subito
        // ma `image` restava nil per tutta la durata, quindi la vecchia
        // condizione passava sempre. Sul campo si vedevano tre decodifiche
        // simultanee della stessa immagine (2674/2671/2168 ms), cioè tre bitmap
        // da ~25 MB allocati in parallelo.
        if cache.isLoading, cache.loadingDate == stamp { return }

        cache.imageDate = stamp

        guard let data = floorplan.currentImageData else {
            cache.isLoading = false
            cache.loadingDate = nil
            return
        }

        cache.isLoading = true
        cache.loadingDate = stamp
        let cacheBinding = $cache

        Task {
            #if DEBUG
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            #endif
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let decoded = UIImage(data: data) else { return nil }
                // `UIImage(data:)` è pigra: tiene i byte e rasterizza solo quando
                // la si disegna, cioè nel render pass di SwiftUI — sul main
                // thread. `byPreparingForDisplay()` forza la decodifica qui, in
                // background, così al momento di disegnare non resta lavoro.
                return await decoded.byPreparingForDisplay() ?? decoded
            }.value
            #if DEBUG
            // Diagnostica freeze: peso del file e dimensioni in pixel dell'immagine.
            // L'export planimetria è passato a PNG lossless (fix cucitura colore):
            // un file molto grande costa in decodifica e soprattutto alla prima
            // rasterizzazione sulla GPU, che avviene nel render pass di SwiftUI.
            let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000
            let megabytes = Double(data.count) / 1_048_576
            let pixels = image.map { "\(Int($0.size.width * $0.scale))×\(Int($0.size.height * $0.scale))" } ?? "n/d"
            dprint(String(format: "🖼 [FloorplanImage] %.1f MB · %@ px · decode %dms",
                          megabytes, pixels, Int(decodeMs)))
            #endif

            await MainActor.run {
                // Una decodifica più recente può aver già consegnato: non
                // sovrascriverla con un risultato vecchio.
                guard cacheBinding.wrappedValue.loadingDate == stamp else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    cacheBinding.wrappedValue.image = image
                    cacheBinding.wrappedValue.isLoading = false
                    cacheBinding.wrappedValue.loadingDate = nil
                }
            }
        }
    }
}
