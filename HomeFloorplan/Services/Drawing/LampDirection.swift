import SwiftUI

// MARK: - LampDirection

/// Dove punta una luce.
///
/// Non è un dettaglio estetico: decide che tipo di sorgente si accende e come
/// la stanza si illumina. Un faretto a soffitto e una piantana che spara in su
/// fanno due case diverse, e in pianta sono lo stesso pallino.
enum LampDirection: String, CaseIterable, Identifiable {
    case down, around, up

    var id: String { rawValue }

    var label: String {
        switch self {
        case .down:   String(localized: "lamp.direction.down", defaultValue: "Downwards")
        case .around: String(localized: "lamp.direction.around", defaultValue: "All around")
        case .up:     String(localized: "lamp.direction.up", defaultValue: "Upwards")
        }
    }

    var symbol: String {
        switch self {
        case .down:   "arrow.down.to.line"
        case .around: "circle.dotted"
        case .up:     "arrow.up.to.line"
        }
    }

    /// L'altezza a cui sta di solito una luce che punta così: un faretto è a
    /// soffitto, una lampada da appoggio all'altezza del tavolo, una piantana
    /// che illumina il soffitto sta bassa.
    func defaultHeight(ceiling: Double) -> Double {
        switch self {
        case .down:   max(1.2, ceiling - 0.1)
        case .around: 1.25
        case .up:     0.4
        }
    }
}
