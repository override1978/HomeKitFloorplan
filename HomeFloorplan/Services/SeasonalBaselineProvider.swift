import Foundation

// MARK: - SeasonalBaselineProvider

/// Pure lookup table that adjusts environmental warning/danger thresholds based on season.
///
/// Summer shifts humidity tolerance up (more moisture is expected); winter shifts it down
/// (cold surfaces increase condensation risk at lower humidity levels). Temperature follows
/// the same logic: summer allows slightly higher indoor temperatures before alerting.
enum SeasonalBaselineProvider {

    /// Seasonally-adjusted warning threshold for the given sensor type.
    static func warningThreshold(for type: SensorServiceType, season: CalendarSeason) -> Double {
        type.defaultWarning + warningOffset(for: type, season: season)
    }

    /// Seasonally-adjusted danger threshold for the given sensor type.
    static func dangerThreshold(for type: SensorServiceType, season: CalendarSeason) -> Double {
        type.defaultDanger + dangerOffset(for: type, season: season)
    }

    /// Human-readable note explaining the active seasonal adjustment, or nil when no adjustment applies.
    static func contextNote(for type: SensorServiceType, season: CalendarSeason) -> String? {
        switch type {
        case .humidity:
            switch season {
            case .summer:
                return String(localized: "seasonal.humidity.summer",
                              defaultValue: "Summer threshold: humidity tolerance is slightly higher.")
            case .winter:
                return String(localized: "seasonal.humidity.winter",
                              defaultValue: "Winter threshold: higher condensation risk on cold surfaces.")
            default: return nil
            }
        case .temperature:
            switch season {
            case .summer:
                return String(localized: "seasonal.temp.summer",
                              defaultValue: "Summer threshold: higher temperatures are expected this season.")
            case .winter:
                return String(localized: "seasonal.temp.winter",
                              defaultValue: "Winter threshold: indoor overheating has greater impact in winter.")
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: - Private offsets

    private static func warningOffset(for type: SensorServiceType, season: CalendarSeason) -> Double {
        switch type {
        case .temperature:
            switch season {
            case .summer:        return  2.0    // 30 °C — heat tolerance higher
            case .winter:        return -2.0    // 26 °C — indoor overheating more noticeable
            case .spring, .autumn: return 0.0
            }
        case .humidity:
            switch season {
            case .summer:        return  5.0    // 70 % — higher ambient humidity expected
            case .winter:        return -5.0    // 60 % — condensation risk on cold surfaces
            case .spring, .autumn: return 0.0
            }
        default: return 0.0
        }
    }

    private static func dangerOffset(for type: SensorServiceType, season: CalendarSeason) -> Double {
        switch type {
        case .temperature:
            switch season {
            case .summer:        return  2.0
            case .winter:        return -2.0
            case .spring, .autumn: return 0.0
            }
        case .humidity:
            switch season {
            case .summer:        return  5.0
            case .winter:        return -5.0
            case .spring, .autumn: return 0.0
            }
        default: return 0.0
        }
    }
}
