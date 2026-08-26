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
        case .intelligence: return true
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
    var hasIntelligenceSuggestions: Bool

    static let none = FloorplanOverlayContext(
        hasEnvironmentData: false,
        hasSecurityDevices: false,
        hasAIService: false,
        hasIntelligenceSuggestions: false
    )
}

// MARK: - Theme extensions

extension FloorplanOverlayMode {
    /// Accento del modo, dal registro token del redesign
    /// (`FloorplanTokens.Mode`) — colori del design handoff, non più quelli
    /// di sistema.
    var accentColor: Color {
        FloorplanTokens.Mode.accent(self)
    }

    /// Sfondo del segmento attivo nella pill dei modi.
    var activeBackgroundColor: Color {
        FloorplanTokens.Mode.activeBackground(self)
    }

    /// Testo/glifo del segmento attivo, a contrasto con `activeBackgroundColor`.
    var activeForegroundColor: Color {
        FloorplanTokens.Mode.activeForeground(self)
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
        case .controls:     return String(localized: "overlay.mode.controls",     defaultValue: "Controls")
        case .environment:  return String(localized: "overlay.mode.environment",  defaultValue: "Environment")
        case .security:     return String(localized: "overlay.mode.security",     defaultValue: "Security")
        case .intelligence: return String(localized: "overlay.mode.intelligence", defaultValue: "Intelligence")
        }
    }
}
