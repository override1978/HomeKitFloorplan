import SwiftUI

// MARK: - FloorplanOverlayMode

/// The active overlay layer shown on top of the floorplan PNG.
enum FloorplanOverlayMode: String, CaseIterable, Identifiable {
    /// Default: accessory markers and controls (existing behaviour).
    case controls
    /// Room-level environment data (temperature, humidity, air quality).
    case environment
    /// Security devices status (locks, alarms, cameras).
    case security
    /// AI-generated insights and habit patterns.
    case intelligence

    var id: String { rawValue }

    /// Whether this mode should appear in the pill given the current context.
    func isAvailable(in context: FloorplanOverlayContext) -> Bool {
        switch self {
        case .controls:     return true
        case .environment:  return context.hasEnvironmentData
        case .security:     return context.hasSecurityDevices
        case .intelligence: return context.hasAIService
        }
    }
}

// MARK: - FloorplanOverlayContext

/// Snapshot of what data sources are available for a given floorplan session.
/// Computed once from injected environment services; no global state.
struct FloorplanOverlayContext {
    var hasEnvironmentData: Bool
    var hasSecurityDevices: Bool
    var hasAIService: Bool

    static let none = FloorplanOverlayContext(
        hasEnvironmentData: false,
        hasSecurityDevices: false,
        hasAIService: false
    )
}

// MARK: - Theme extensions

extension FloorplanOverlayMode {
    /// Brand accent colour for this mode.
    var accentColor: Color {
        switch self {
        case .controls:     return BrandColor.primary
        case .environment:  return Color(.systemGreen)
        case .security:     return Color(.systemPurple)
        case .intelligence: return Color(.systemIndigo)
        }
    }

    /// SF Symbol used in the mode pill.
    var pillIcon: String {
        switch self {
        case .controls:     return "slider.horizontal.3"
        case .environment:  return "leaf.fill"
        case .security:     return "lock.shield.fill"
        case .intelligence: return "sparkles"
        }
    }

    /// Short localized label shown in the pill.
    var label: String {
        switch self {
        case .controls:     return String(localized: "overlay.mode.controls",     defaultValue: "Controlli")
        case .environment:  return String(localized: "overlay.mode.environment",  defaultValue: "Ambiente")
        case .security:     return String(localized: "overlay.mode.security",     defaultValue: "Sicurezza")
        case .intelligence: return String(localized: "overlay.mode.intelligence", defaultValue: "Intelligenza")
        }
    }
}
