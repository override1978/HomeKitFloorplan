import Foundation

// MARK: - SolarCalculator

/// Alba e tramonto per un giorno qualunque, calcolati.
///
/// WeatherKit li dà solo per oggi e domani, ed è giusto che sia
/// l'autorità là dove risponde: tiene conto di rifrazione ed elevazione meglio
/// di qualunque formula chiusa. Ma il nastro deve poter mostrare ieri, e la
/// banda giorno/notte non è un dettaglio decorativo — è ciò che rende una
/// giornata riconoscibile a colpo d'occhio prima ancora di leggere le
/// etichette. Senza, un nastro del passato è una riga grigia.
///
/// Algoritmo NOAA nella forma divulgata come «sunrise equation»: preciso
/// attorno al minuto alle latitudini abitate, che è un ordine di grandezza
/// meglio di quanto un pixel su ventiquattr'ore possa mostrare.
enum SolarCalculator {

    struct Coordinates: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    /// L'angolo del sole sotto l'orizzonte quando lo diciamo sorto.
    ///
    /// Non zero: il disco solare ha un raggio apparente e l'atmosfera lo
    /// solleva di poco più di mezzo grado, quindi lo si vede prima che il
    /// centro geometrico arrivi all'orizzonte. È la stessa convenzione che
    /// usano gli almanacchi, e ignorarla sposta l'alba di parecchi minuti.
    private static let horizonAngle = -0.833

    private static let epsilon = 23.4397  // inclinazione dell'eclittica

    /// Le coordinate di casa, come le conosce il resto dell'app.
    static var homeCoordinates: Coordinates? {
        let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
        let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
        guard lat != 0 || lon != 0 else { return nil }
        return Coordinates(latitude: lat, longitude: lon)
    }

    /// Alba e tramonto del giorno che contiene `day`.
    ///
    /// Restituisce `nil` dove il sole non sorge o non tramonta affatto: oltre i
    /// circoli polari la domanda non ha risposta, e inventarne una sarebbe
    /// peggio che ammetterlo.
    static func events(on day: Date,
                       at coordinates: Coordinates,
                       calendar: Calendar = .current) -> (sunrise: Date?, sunset: Date?) {
        let noon = calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
        let julianDay = julian(from: noon)

        // Mezzogiorno solare medio, in giorni da J2000.
        let n = (julianDay - 2_451_545.0 + 0.0008).rounded()
        let meanSolarNoon = n - coordinates.longitude / 360

        let m = (357.5291 + 0.98560028 * meanSolarNoon).truncatingRemainder(dividingBy: 360)
        let mRad = m * .pi / 180

        // Equazione del centro: l'orbita è un'ellisse, non un cerchio.
        let center = 1.9148 * sin(mRad) + 0.0200 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)
        let lambda = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let lambdaRad = lambda * .pi / 180

        let transit = 2_451_545.0 + meanSolarNoon
            + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)

        let declination = asin(sin(lambdaRad) * sin(epsilon * .pi / 180))
        let latRad = coordinates.latitude * .pi / 180

        let numerator = sin(horizonAngle * .pi / 180) - sin(latRad) * sin(declination)
        let denominator = cos(latRad) * cos(declination)
        guard denominator != 0 else { return (nil, nil) }

        let cosHourAngle = numerator / denominator
        // Sole di mezzanotte o notte polare: nessun attraversamento.
        guard (-1...1).contains(cosHourAngle) else { return (nil, nil) }

        let hourAngle = acos(cosHourAngle) * 180 / .pi
        let sunset = transit + hourAngle / 360
        let sunrise = transit - hourAngle / 360

        return (date(fromJulian: sunrise), date(fromJulian: sunset))
    }

    // MARK: - Dove sta il sole

    /// Dove si trova il sole, non solo se c'è.
    ///
    /// Serve per la luce che entra dalle finestre: un'apertura non prende la
    /// stessa luce tutto il giorno — un balcone a sud-ovest è in ombra la
    /// mattina e prende tutto il pomeriggio, ed è una differenza che chi abita
    /// la casa conosce senza doverla misurare.
    ///
    /// - Returns: `azimuth` in gradi da nord in senso orario (90 = est, 180 =
    ///   sud, 270 = ovest) e `altitude` in gradi sopra l'orizzonte, negativa di
    ///   notte.
    static func position(at instant: Date,
                         coordinates: Coordinates,
                         calendar: Calendar = .current) -> (azimuth: Double, altitude: Double) {
        let julianDay = julian(from: instant)
        // Arrotondato, come nel calcolo di alba e tramonto: `n` è il **numero
        // del giorno**, non l'istante. Lasciandolo frazionario il mezzogiorno
        // solare finisce a coincidere con l'istante stesso, l'angolo orario è
        // sempre zero e il sole risulta a sud a qualunque ora — il che ha il
        // pregio di fallire in modo vistoso invece che di poco.
        let n = (julianDay - 2_451_545.0 + 0.0008).rounded()
        let meanSolarNoon = n - coordinates.longitude / 360

        let m = (357.5291 + 0.98560028 * meanSolarNoon).truncatingRemainder(dividingBy: 360)
        let mRad = m * .pi / 180
        let center = 1.9148 * sin(mRad) + 0.0200 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)
        let lambdaRad = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * .pi / 180

        let declination = asin(sin(lambdaRad) * sin(epsilon * .pi / 180))
        let transit = 2_451_545.0 + meanSolarNoon
            + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)

        // Angolo orario: quanto il sole è avanti o indietro rispetto al proprio
        // mezzogiorno, in gradi. Negativo di mattina, positivo di pomeriggio.
        let hourAngle = (julianDay - transit) * 360 * .pi / 180
        let latRad = coordinates.latitude * .pi / 180

        let sinAltitude = sin(latRad) * sin(declination)
            + cos(latRad) * cos(declination) * cos(hourAngle)
        let altitude = asin(min(max(sinAltitude, -1), 1))

        let cosAzimuth = (sin(declination) - sin(altitude) * sin(latRad))
            / max(cos(altitude) * cos(latRad), 1e-9)
        var azimuth = acos(min(max(cosAzimuth, -1), 1)) * 180 / .pi
        // `acos` non sa distinguere mattina da pomeriggio: la restituisce
        // sempre a est. È l'angolo orario a dire da che parte siamo.
        if hourAngle > 0 { azimuth = 360 - azimuth }

        return (azimuth, altitude * 180 / .pi)
    }

    // MARK: - Giorno giuliano

    nonisolated private static let julianEpoch = 2_440_587.5  // 1 gennaio 1970, 00:00 UTC

    nonisolated static func julian(from date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + julianEpoch
    }

    nonisolated static func date(fromJulian julianDay: Double) -> Date {
        Date(timeIntervalSince1970: (julianDay - julianEpoch) * 86_400)
    }
}
