import SwiftUI

struct FloorplanImageCacheState {
    var image: UIImage?
    var imageDate: Date = .distantPast
    var isLoading = false
}

struct FloorplanImageLoader {
    @Binding var cache: FloorplanImageCacheState

    func refresh(for floorplan: Floorplan) {
        let stamp = floorplan.updatedAt
        guard stamp != cache.imageDate || cache.image == nil else { return }
        cache.imageDate = stamp

        guard let data = floorplan.currentImageData else {
            cache.isLoading = false
            return
        }

        cache.isLoading = true
        let cacheBinding = $cache

        Task {
            #if DEBUG
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            #endif
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
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
                withAnimation(.easeIn(duration: 0.2)) {
                    cacheBinding.wrappedValue.image = image
                    cacheBinding.wrappedValue.isLoading = false
                }
            }
        }
    }
}
