import Foundation

/// Coordinate normalizzate (0...1) relative all'immagine di sfondo del floorplan.
/// Usate per posizionare gli accessori in modo indipendente dalla risoluzione
/// dell'immagine e dalle dimensioni della view.
struct NormalizedPoint: Codable, Hashable {
    var x: Double
    var y: Double
    
    static let center = NormalizedPoint(x: 0.5, y: 0.5)
    
    /// Restituisce il punto in coordinate view, date le dimensioni del contenitore.
    func cgPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
    
    /// Crea un NormalizedPoint a partire da un CGPoint in coordinate view.
    init(cgPoint: CGPoint, in size: CGSize) {
        // Clamp tra 0 e 1 per sicurezza
        self.x = max(0, min(1, cgPoint.x / max(size.width, 1)))
        self.y = max(0, min(1, cgPoint.y / max(size.height, 1)))
    }
    
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
