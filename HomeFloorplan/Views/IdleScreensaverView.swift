import SwiftUI

// MARK: - IdleScreensaverView

/// Lo schermo di riposo del pannello a muro.
///
/// Prima era il gradiente del marchio con l'icona dell'app al centro: bello da
/// fermo, sbagliato per l'uso reale. Questo iPad sta appeso e acceso sempre, e
/// per mezza giornata quello schermo e' l'unica cosa illuminata della stanza —
/// di notte un rettangolo arancione da tredici pollici non e' una schermata, e'
/// una lampada. E il nome dell'app, ogni sera per anni, non lo legge piu'
/// nessuno.
///
/// Quindi: fondo quasi nero, e al posto del marchio le due cose che da un
/// pannello si guardano davvero **da lontano e di sfuggita** — che ore sono e
/// che tempo fa. Il resto (dentro/fuori, alba e tramonto) sta sotto, piu'
/// piccolo, per chi si avvicina.
///
/// Due accorgimenti che si vedono solo dopo mesi:
///
/// - **La deriva.** Lo stesso orologio negli stessi pixel per ore marchia il
///   pannello. Il blocco intero si sposta lentamente su un'ellisse di una
///   quarantina di punti, con un giro di quattro minuti: impercettibile
///   guardandolo, sufficiente perche' nessun pixel resti acceso allo stesso
///   modo per sempre.
/// - **La notte.** Fra tramonto e alba tutto si attenua ancora, perche' la
///   stessa luminosita' che di giorno si legge appena, al buio e' fastidiosa.
struct IdleScreensaverView: View {

    let onDismiss: () -> Void

    @Environment(WeatherKitService.self) private var weather
    @Environment(HomeState.self) private var homeState
    @AppStorage(TemperatureUnit.appStorageKey) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue

    @State private var hasAppeared = false
    @State private var isDrifting = false
    /// Token restituito da addObserver — serve per rimuovere l'observer.
    @State private var proximityObserverToken: (any NSObjectProtocol)?

    private var unit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    // MARK: Corpo

    var body: some View {
        ZStack {
            background

            TimelineView(.everyMinute) { context in
                content(now: context.date)
                    .opacity(hasAppeared ? 1 : 0)
                    // La deriva: due componenti con periodi diversi, cosi' il
                    // percorso non si ripete sulla stessa riga ogni giro.
                    .offset(x: isDrifting ? 18 : -18,
                            y: isDrifting ? -22 : 22)
                    .animation(.easeInOut(duration: 121).repeatForever(autoreverses: true),
                               value: isDrifting)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .task {
            withAnimation(.easeOut(duration: 1.1)) { hasAppeared = true }
            isDrifting = true
            // Il meteo puo' essere vecchio di ore: il pannello entra in riposo
            // proprio quando nessuno lo tocca, cioe' quando nessun'altra
            // schermata lo sta aggiornando.
            await weather.refreshIfNeeded()
            startProximityMonitoring()
        }
        .onDisappear { stopProximityMonitoring() }
    }

    private var background: some View {
        ZStack {
            Color.black
            // Un alone appena percettibile dietro il testo: toglie l'effetto
            // "schermo spento con su scritto qualcosa" senza illuminare nulla.
            RadialGradient(colors: [Color.white.opacity(isNight ? 0.03 : 0.06), .clear],
                           center: .center, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let dim = isNight ? 0.62 : 0.92

        VStack(spacing: 26) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 128, weight: .ultraLight, design: .rounded))
                // Cifre a larghezza fissa: senza, l'orologio si sposta di
                // qualche punto passando da 1 a 8 e la deriva sembra a scatti.
                .monospacedDigit()
                .foregroundStyle(.white.opacity(dim))

            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 21, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(dim * 0.6))

            if outdoor != nil || indoor != nil {
                climateRow(dim: dim)
                    .padding(.top, 10)
            }

            if let sun = sunLine {
                Text(sun)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(dim * 0.38))
            }

            Text(String(localized: "screensaver.tapToReturn", defaultValue: "Tap to return"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(dim * 0.22))
                .padding(.top, 18)
        }
    }

    private func climateRow(dim: Double) -> some View {
        HStack(spacing: 26) {
            if let outdoor {
                HStack(spacing: 10) {
                    Image(systemName: outdoor.symbol)
                        .font(.system(size: 26, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                    Text(formatted(outdoor.celsius))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(dim * 0.82))
            }

            if outdoor != nil, indoor != nil {
                Capsule()
                    .fill(.white.opacity(dim * 0.18))
                    .frame(width: 1, height: 26)
            }

            if let indoor {
                HStack(spacing: 8) {
                    Text(String(localized: "screensaver.indoor", defaultValue: "Indoor"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(dim * 0.45))
                    Text(formatted(indoor))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(dim * 0.82))
                }
            }
        }
    }

    // MARK: Dati

    private var outdoor: (celsius: Double, symbol: String)? {
        guard let snapshot = weather.currentWeather else { return nil }
        return (snapshot.outdoorTemperature, snapshot.symbolName)
    }

    /// La media delle stanze che hanno un termometro vivo.
    ///
    /// `nil` quando non ne risponde nessuno: meglio non scrivere niente che
    /// scrivere un numero vecchio di ore su uno schermo che sta li' tutta notte.
    private var indoor: Double? {
        let values = homeState.knownRoomUUIDs.compactMap {
            homeState.value(.temperature, inRoom: $0)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var sunLine: String? {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        switch (weather.todaySunrise, weather.todaySunset) {
        case let (sunrise?, sunset?):
            return "↑ \(sunrise.formatted(formatter))   ↓ \(sunset.formatted(formatter))"
        case let (sunrise?, nil):
            return "↑ \(sunrise.formatted(formatter))"
        case let (nil, sunset?):
            return "↓ \(sunset.formatted(formatter))"
        default:
            return nil
        }
    }

    /// Notte secondo il sole vero, se lo sappiamo; altrimenti secondo l'orologio.
    private var isNight: Bool {
        let now = Date()
        if let sunrise = weather.todaySunrise, let sunset = weather.todaySunset {
            return now < sunrise || now > sunset
        }
        let hour = Calendar.current.component(.hour, from: now)
        return hour < 7 || hour >= 21
    }

    private func formatted(_ celsius: Double) -> String {
        let value = unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))\(unit.symbol)"
    }

    // MARK: Prossimità

    /// Avvicinare il dispositivo al viso lo sveglia, come prima.
    private func startProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityObserverToken = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { _ in
            if UIDevice.current.proximityState { onDismiss() }
        }
    }

    private func stopProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = false
        if let token = proximityObserverToken {
            NotificationCenter.default.removeObserver(token)
            proximityObserverToken = nil
        }
    }
}
