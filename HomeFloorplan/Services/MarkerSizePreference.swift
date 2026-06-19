import SwiftUI

/// Dimensione preferita dei marker sul floorplan.
/// L'utente sceglierà questo nelle settings (futuro).
/// Salvato in UserDefaults via @AppStorage.
enum MarkerSize: String, CaseIterable, Identifiable {
    case compact
    case regular
    case large
    
    var id: String { rawValue }
    
    var localized: String {
        switch self {
        case .compact: return String(localized: "marker.size.compact", defaultValue: "Small")
        case .regular: return String(localized: "marker.size.regular", defaultValue: "Medium")
        case .large:   return String(localized: "marker.size.large",   defaultValue: "Large")
        }
    }

    var localizationKey: LocalizedStringKey {
        switch self {
        case .compact: return "marker.size.compact"
        case .regular: return "marker.size.regular"
        case .large:   return "marker.size.large"
        }
    }
    
    /// Diametro del marker per accessori controllabili (luci, prese, ecc.).
    var controllableDiameter: CGFloat {
        switch self {
        case .compact: return 28
        case .regular: return 36
        case .large: return 44
        }
    }
    
    /// Diametro del marker per sensori booleani (porta, movimento, ecc.).
    var sensorBoolDiameter: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 28
        case .large: return 36
        }
    }
    
    /// Dimensione della pill per sensori numerici (temp, umidità).
    var sensorNumericSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 38, height: 22)
        case .regular: return CGSize(width: 48, height: 26)
        case .large: return CGSize(width: 60, height: 32)
        }
    }
    
    /// Dimensione del marker camera (rettangolo 16:9).
    var cameraMarkerSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 88,  height: 50)
        case .regular: return CGSize(width: 112, height: 63)
        case .large:   return CGSize(width: 136, height: 76)
        }
    }

    /// Font dell'icona dentro il cerchio.
    var iconFont: Font {
        switch self {
        case .compact: return .system(size: 16, weight: .semibold)
        case .regular: return .system(size: 20, weight: .semibold)
        case .large: return .system(size: 26, weight: .semibold)
        }
    }
    
    /// Font dell'icona per sensori booleani (più piccola).
    var sensorBoolIconFont: Font {
        switch self {
        case .compact: return .system(size: 11, weight: .semibold)
        case .regular: return .system(size: 14, weight: .semibold)
        case .large: return .system(size: 18, weight: .semibold)
        }
    }
    
    /// Font del valore dentro la pill numerica (temp/umidità).
    var numericValueFont: Font {
        switch self {
        case .compact: return .system(size: 11, weight: .semibold)
        case .regular: return .system(size: 13, weight: .semibold)
        case .large: return .system(size: 16, weight: .semibold)
        }
    }
}

/// Chiave per @AppStorage.
extension MarkerSize {
    static let appStorageKey = "markerSizePreference"
}
