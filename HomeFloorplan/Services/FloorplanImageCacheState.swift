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
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value

            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    cacheBinding.wrappedValue.image = image
                    cacheBinding.wrappedValue.isLoading = false
                }
            }
        }
    }
}
