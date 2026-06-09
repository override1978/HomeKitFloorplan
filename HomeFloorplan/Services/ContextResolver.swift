import Foundation

// MARK: - PresenceState

enum PresenceState: String, Codable {
    case home, away, sleeping, vacation

    var localizedLabel: String {
        switch self {
        case .home:     return String(localized: "context.presence.home",     defaultValue: "Home")
        case .away:     return String(localized: "context.presence.away",     defaultValue: "Away")
        case .sleeping: return String(localized: "context.presence.sleeping", defaultValue: "Home (night)")
        case .vacation: return String(localized: "context.presence.vacation", defaultValue: "On vacation")
        }
    }
}

// MARK: - CalendarSeason

enum CalendarSeason: String, Codable {
    case spring, summer, autumn, winter

    static var current: CalendarSeason {
        let month = Calendar.current.component(.month, from: Date())
        switch month {
        case 3...5:  return .spring
        case 6...8:  return .summer
        case 9...11: return .autumn
        default:     return .winter
        }
    }

    var localizedLabel: String {
        switch self {
        case .spring: return String(localized: "context.season.spring", defaultValue: "Spring")
        case .summer: return String(localized: "context.season.summer", defaultValue: "Summer")
        case .autumn: return String(localized: "context.season.autumn", defaultValue: "Autumn")
        case .winter: return String(localized: "context.season.winter", defaultValue: "Winter")
        }
    }
}

// MARK: - ContextSnapshot

struct ContextSnapshot {
    let timeOfDay:        TimeOfDay
    let dayType:          DayType
    let presenceState:    PresenceState
    let season:           CalendarSeason
    let quietHoursActive: Bool

    /// True during nighttime quiet hours or while the user is presumed asleep.
    /// Non-critical notifications are suppressed in this state.
    var suppressNonCritical: Bool {
        quietHoursActive || presenceState == .sleeping
    }
}

// MARK: - ContextResolver

/// Resolves the current ContextSnapshot from time, calendar and user preferences.
/// All resolution is heuristic (no location permission required).
enum ContextResolver {

    /// - Parameters:
    ///   - presenceOverride: When non-nil (e.g. from LocationPresenceService geofencing),
    ///     this value takes priority over all heuristics.
    ///   - occupancyIsAway: When true (from OccupancyPredictionService.isLikelyAway),
    ///     marks presence as `.away` during waking hours if no override is set.
    ///     Nighttime hours (23:00–07:00) still resolve to `.sleeping` regardless.
    static func resolve(presenceOverride: PresenceState? = nil, occupancyIsAway: Bool = false) -> ContextSnapshot {
        let now     = Date()
        let cal     = Calendar.current
        let hour    = cal.component(.hour,    from: now)
        let weekday = cal.component(.weekday, from: now)

        let presenceState: PresenceState
        if let override = presenceOverride {
            presenceState = override
        } else if UserDefaults.standard.bool(forKey: "proactive.vacationMode") {
            presenceState = .vacation
        } else if hour >= 23 || hour < 7 {
            presenceState = .sleeping
        } else if occupancyIsAway {
            presenceState = .away
        } else {
            presenceState = .home
        }

        return ContextSnapshot(
            timeOfDay:        TimeOfDay(hour: hour),
            dayType:          DayType(weekday: weekday),
            presenceState:    presenceState,
            season:           CalendarSeason.current,
            quietHoursActive: isQuietHours(hour: hour)
        )
    }

    // MARK: - Quiet Hours

    private static func isQuietHours(hour: Int) -> Bool {
        let start = UserDefaults.standard.object(forKey: "proactive.quietStart") as? Int ?? 23
        let end   = UserDefaults.standard.object(forKey: "proactive.quietEnd")   as? Int ?? 7
        // Handle wrap-around (e.g. 23:00 → 07:00)
        return start > end
            ? (hour >= start || hour < end)
            : (hour >= start && hour < end)
    }
}
