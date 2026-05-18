import Foundation
import UIKit

/// Gestisce salvataggio, lettura e cancellazione delle immagini dei floorplan
/// nella directory Application Support/floorplans/.
///
/// Perché su disco e non in SwiftData?
/// - SwiftData con blob grandi (>1 MB) diventa lento.
/// - Le immagini sono dati "freddi": le carichi una volta e le riusi.
/// - Su disco puoi sfruttare il caching del filesystem.
struct ImageStorageService {
    
    enum StorageError: LocalizedError {
        case directoryUnavailable
        case writeFailed(underlying: Error)
        case readFailed
        case encodingFailed
        
        var errorDescription: String? {
            switch self {
            case .directoryUnavailable: return "Directory di salvataggio non disponibile."
            case .writeFailed(let e): return "Scrittura fallita: \(e.localizedDescription)"
            case .readFailed: return "Impossibile leggere l'immagine."
            case .encodingFailed: return "Codifica dell'immagine fallita."
            }
        }
    }
    
    /// Directory dedicata: Application Support/floorplans/
    /// Creata on-demand al primo accesso.
    private static var floorplansDirectory: URL {
        get throws {
            let fm = FileManager.default
            guard let base = fm.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first else {
                throw StorageError.directoryUnavailable
            }
            let dir = base.appendingPathComponent("floorplans", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }
    
    /// Salva una UIImage come JPEG (qualità 0.85) e restituisce il filename generato.
    /// Il filename è un UUID + estensione: così non ci sono mai collisioni.
    @discardableResult
    static func save(_ image: UIImage) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw StorageError.encodingFailed
        }
        let filename = "\(UUID().uuidString).jpg"
        let url = try floorplansDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed(underlying: error)
        }
        return filename
    }
    
    /// Carica un'immagine dato il suo filename. Restituisce nil se non esiste.
    static func load(filename: String) -> UIImage? {
        guard let url = try? floorplansDirectory.appendingPathComponent(filename),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }
    
    /// Cancella un'immagine. Silente se il file non esiste.
    static func delete(filename: String) {
        guard let url = try? floorplansDirectory.appendingPathComponent(filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    /// URL completo del file (utile per debug o per condivisione).
    static func url(for filename: String) -> URL? {
        try? floorplansDirectory.appendingPathComponent(filename)
    }
}
