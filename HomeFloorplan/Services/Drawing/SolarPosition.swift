import Foundation

// MARK: - SolarPosition

/// Dove si trova il sole nel cielo, da coordinate e istante.
///
/// **Formula chiusa** (algoritmo NOAA): nessuna rete, nessun framework, nessun
/// permesso, nessuna latenza. WeatherKit dà alba e tramonto ma non l'azimut — e
/// l'azimut è esattamente il dato che serve, perché dice **da che parte** arriva
/// la luce, non solo se c'è.
///
/// Puro e testabile: entrano tre numeri, escono due angoli.
enum SolarPosition {

    struct Result: Equatable {
        /// Gradi da nord in senso **orario**: 0 nord, 90 est, 180 sud, 270 ovest.
        var azimuthDegrees: Double
        /// Gradi sopra l'orizzonte. Negativo vuol dire sole tramontato.
        var elevationDegrees: Double

        var isAboveHorizon: Bool { elevationDegrees > 0 }
    }

    static func position(at date: Date, latitude: Double, longitude: Double) -> Result {
        let julianCentury = (julianDay(of: date) - 2_451_545.0) / 36_525.0
        let t = julianCentury

        let meanLongitude = wrapped(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let anomaly = radians(meanAnomaly)
        let centre = sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * t)
            + sin(3 * anomaly) * 0.000289

        let omega = 125.04 - 1_934.136 * t
        let apparentLongitude = meanLongitude + centre - 0.00569 - 0.00478 * sin(radians(omega))

        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(radians(omega))

        let declination = asin(sin(radians(obliquity)) * sin(radians(apparentLongitude)))

        // Equazione del tempo: il sole vero e l'orologio non vanno d'accordo, e
        // a metà novembre lo scarto arriva a un quarto d'ora. Ignorarla sposta
        // l'ombra di qualche grado, che su una casa si vede.
        let y = pow(tan(radians(obliquity) / 2), 2)
        let l0 = radians(meanLongitude)
        let equationOfTime = 4 * degrees(
            y * sin(2 * l0)
                - 2 * eccentricity * sin(anomaly)
                + 4 * eccentricity * y * sin(anomaly) * cos(2 * l0)
                - 0.5 * y * y * sin(4 * l0)
                - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
        )

        // Si lavora in UTC: così il termine del fuso orario si annulla da solo e
        // non c'è nessun `TimeZone` da sbagliare.
        var solarTime = minutesUTC(of: date) + equationOfTime + 4 * longitude
        solarTime = solarTime.truncatingRemainder(dividingBy: 1_440)
        if solarTime < 0 { solarTime += 1_440 }

        var hourAngle = solarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let lat = radians(latitude)
        let ha = radians(hourAngle)
        let zenith = acos(clamped(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(ha)))
        let elevation = 90 - degrees(zenith)

        let denominator = cos(lat) * sin(zenith)
        let azimuth: Double
        if abs(denominator) > 0.0001 {
            let ratio = clamped((sin(lat) * cos(zenith) - sin(declination)) / denominator)
            let base = degrees(acos(ratio))
            azimuth = hourAngle > 0 ? wrapped(base + 180) : wrapped(540 - base)
        } else {
            // Sole allo zenit o ai poli: l'azimut non è definito, e qualsiasi
            // valore va bene perché la luce arriva da sopra.
            azimuth = latitude > 0 ? 180 : 0
        }

        return Result(azimuthDegrees: azimuth, elevationDegrees: elevation)
    }

    // MARK: - Supporto

    private static func julianDay(of date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    private static func minutesUTC(of date: Date) -> Double {
        var seconds = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        if seconds < 0 { seconds += 86_400 }
        return seconds / 60
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    private static func clamped(_ value: Double) -> Double { min(max(value, -1), 1) }

    private static func wrapped(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

// MARK: - SolarClock

/// Dove sta casa e che ora è: i due ingressi non astronomici del calcolo.
enum SolarClock {

    /// Le coordinate salvate quando l'utente ha attivato la presenza.
    ///
    /// Se non le ha mai date si usa un default continentale invece di rifiutarsi
    /// di disegnare: a queste latitudini il sole si muove abbastanza uguale da
    /// far riconoscere l'esposizione, e appena la posizione vera arriva il
    /// modello si corregge da solo.
    static func homeCoordinate() -> (latitude: Double, longitude: Double) {
        let defaults = UserDefaults.standard
        let latitude = defaults.double(forKey: LocationPresenceService.homeLatKey)
        let longitude = defaults.double(forKey: LocationPresenceService.homeLonKey)
        guard latitude != 0 || longitude != 0 else { return (45.0, 9.0) }
        return (latitude, longitude)
    }

}

// MARK: - Esposizione

/// Gli otto punti cardinali, che è la granularità con cui la gente conosce casa
/// propria: nessuno dice «la mia facciata guarda a 237 gradi».
enum Exposure: String, CaseIterable, Identifiable {
    case north, northEast, east, southEast, south, southWest, west, northWest

    var id: String { rawValue }

    /// Gradi da nord in senso orario.
    var bearingDegrees: Double {
        switch self {
        case .north:     0
        case .northEast: 45
        case .east:      90
        case .southEast: 135
        case .south:     180
        case .southWest: 225
        case .west:      270
        case .northWest: 315
        }
    }

    var shortLabel: String {
        switch self {
        case .north:     String(localized: "compass.n", defaultValue: "N")
        case .northEast: String(localized: "compass.ne", defaultValue: "NE")
        case .east:      String(localized: "compass.e", defaultValue: "E")
        case .southEast: String(localized: "compass.se", defaultValue: "SE")
        case .south:     String(localized: "compass.s", defaultValue: "S")
        case .southWest: String(localized: "compass.sw", defaultValue: "SW")
        case .west:      String(localized: "compass.w", defaultValue: "W")
        case .northWest: String(localized: "compass.nw", defaultValue: "NW")
        }
    }

    /// Il punto cardinale più vicino a un rilevamento qualsiasi.
    static func nearest(to bearing: Double) -> Exposure {
        let normalized = bearing.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 45).rounded()) % 8
        return allCases[index]
    }
}
