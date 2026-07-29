import Foundation

// MARK: - SensorSampleGate

/// Decide quali letture campionate meritano una riga sul database.
///
/// Il campionamento resta invariato — si continua a leggere ogni sensore a ogni
/// giro. Cambia solo cosa si *archivia*: una lettura identica alla precedente
/// non aggiunge informazione, aggiunge peso. Con 46 sensori letti ogni 15 minuti
/// la stragrande maggioranza delle righe diceva quello che diceva già la riga
/// prima.
///
/// **Questa non è una perdita di dati.** Se la temperatura è ferma a 21,4° da
/// tre ore, l'ultima riga in archivio dice 21,4°: è la verità, semplicemente
/// scritta una volta invece di dodici. Quello che si accorcia è la frequenza
/// delle righe, non la correttezza del valore corrente.
///
/// Ci sono però due cose che una riga trasporta *oltre* al valore, e sono il
/// motivo del tetto massimo qui sotto:
/// - gli aggregati giornalieri (`DailySensorSummary`) hanno bisogno di
///   abbastanza campioni per essere rappresentativi;
/// - senza una riga periodica non si distingue "sensore fermo" da "sensore
///   sparito". Il battito orario è quel segnale di vita.
///
/// Lo stato vive in memoria e muore col processo: al primo giro dopo un
/// riavvio ogni sensore scrive. È voluto — costa una riga per sensore e
/// garantisce che l'archivio riparta sempre da uno stato noto, senza dover
/// interrogare il database per sapere cosa avevamo già scritto.
struct SensorSampleGate {

    // MARK: - Tetto massimo

    /// Oltre questo intervallo si scrive comunque, anche se il valore non si è
    /// mosso di un millesimo. È il battito che tiene in vita gli aggregati e
    /// permette di accorgersi che un sensore ha smesso di rispondere.
    static let maxGap: TimeInterval = 3600

    // MARK: - Non cancellare le prove di un blocco

    /// `SensorAnomalyDetector` riconosce un sensore bloccato da una cosa sola:
    /// il valore resta **identico** per oltre mezz'ora. Funziona perché un
    /// sensore vivo ha rumore sull'ultima cifra — oscilla tra 21,4 e 21,5 —
    /// mentre uno rotto ripete lo stesso numero.
    ///
    /// La deduplica cancella esattamente quel rumore: è il suo scopo. Senza
    /// questa regola le uniche righe superstiti di un sensore fermo sarebbero i
    /// battiti orari, troppo poche per la finestra di due ore del detector, che
    /// smetterebbe di vedere proprio il guasto per cui esiste.
    ///
    /// Quindi quando un valore si ripete identico si torna a scrivere spesso.
    /// Non serve toccare il detector: gli si rimette davanti la prova che si
    /// aspetta di trovare.

    /// Due letture entro questo scarto sono "lo stesso numero". Deve combaciare
    /// con la tolleranza che il detector usa per dire `allSame`.
    static let exactRepeatEpsilon = 0.01

    /// Da quanto un valore deve ripetersi prima di iniziare a lasciare tracce.
    /// Metà della finestra del detector: prima di allora un valore fermo è
    /// ordinaria amministrazione, non un indizio.
    static var stuckEvidenceAfter: TimeInterval { SensorAnomalyDetector.stuckDuration / 2 }

    /// Ogni quanto scrivere mentre il sospetto dura. Un quarto della finestra,
    /// così nell'arco di una finestra si accumulano le quattro righe che il
    /// detector pretende come minimo per un gruppo.
    static var stuckEvidenceGap: TimeInterval { SensorAnomalyDetector.stuckDuration / 4 }

    // MARK: - Quanto deve muoversi un valore per meritare una riga

    /// La soglia è tarata su *cosa si nota*, non su cosa il sensore sa misurare.
    /// Un termometro che riporta 21,41° invece di 21,40° non ha osservato nulla
    /// di nuovo sulla casa: ha solo rumore all'ultima cifra.
    ///
    /// Temperatura e umidità riusano di proposito gli stessi valori che
    /// `EnvironmentViewModel` adopera per decidere se un trend sale o scende
    /// (0,3° e 2%). Se una variazione è troppo piccola perché la vista la
    /// chiami "in salita", è troppo piccola anche per occupare una riga.
    static func isSignificantChange(_ type: SensorServiceType, from old: Double, to new: Double) -> Bool {
        let delta = abs(new - old)

        switch type {
        // Allarmi booleani: qualsiasi transizione conta, sempre.
        case .smoke:
            return delta > 0

        // Ordinale 1–5: non esistono variazioni "piccole", ogni gradino è un
        // cambio di giudizio sulla qualità dell'aria.
        case .airQuality:
            return delta >= 1

        case .temperature, .outdoorTemperature:
            return delta >= 0.3
        case .humidity, .outdoorHumidity:
            return delta >= 2
        case .carbonMonoxide:
            return delta >= 1
        case .carbonDioxide:
            return delta >= 25
        case .vocDensity:
            return delta >= 25
        case .pm25, .pm10:
            return delta >= 2

        // La luce è l'unico caso in cui una soglia fissa non funziona: lo
        // stesso salto di 5 lux è l'alba in una stanza buia ed è niente in
        // pieno giorno. La scala è percettivamente logaritmica, quindi la
        // soglia è relativa — con un minimo assoluto perché vicino allo zero
        // anche il 15% diventa una frazione di lux.
        case .lightSensor:
            return delta >= max(old * 0.15, 5)
        }
    }

    // MARK: - Stato

    /// Ultima lettura effettivamente scritta, per sensore fisico e tipo.
    private var lastWritten: [String: (value: Double, at: Date)] = [:]

    /// Da quando il sensore ripete lo stesso identico numero. `nil` appena il
    /// valore si muove, anche di pochissimo.
    private var identicalSince: [String: Date] = [:]

    /// Ultima lettura **osservata**, scritta o no. Distinta da `lastWritten`
    /// perché la striscia di ripetizioni riguarda ciò che il sensore riporta,
    /// non ciò che noi archiviamo: confrontando con l'ultima riga scritta, un
    /// sensore che oscilla tra 21,4 e 21,5 sembrerebbe fermo a ogni secondo
    /// giro, visto che il riferimento resterebbe indietro su 21,4.
    private var lastObserved: [String: (value: Double, at: Date)] = [:]

    private static func key(_ accessoryUUID: String, _ type: SensorServiceType) -> String {
        "\(accessoryUUID)|\(type.rawValue)"
    }

    // MARK: - Decisione

    /// Se la lettura va archiviata. Chiamare **solo** per letture che si sta per
    /// scrivere davvero: il metodo registra l'esito, quindi un "sì" non
    /// consumato disallinea lo stato.
    mutating func shouldWrite(
        accessoryUUID: String,
        type: SensorServiceType,
        value: Double,
        now: Date = Date()
    ) -> Bool {
        let k = Self.key(accessoryUUID, type)
        stats.sampled += 1

        // Aggiorna la striscia di ripetizioni confrontando con l'osservazione
        // precedente, poi registra questa. Si tiene solo sui tipi che il
        // detector giudica statisticamente: per i lux, fermi a zero tutta la
        // notte, o per gli allarmi booleani, a zero per sempre, sarebbe solo un
        // fiume di righe che nessuno legge.
        if let previous = lastObserved[k],
           SensorAnomalyDetector.evaluatesStatistically(type),
           abs(value - previous.value) < Self.exactRepeatEpsilon {
            if identicalSince[k] == nil { identicalSince[k] = previous.at }
        } else {
            identicalSince[k] = nil
        }
        lastObserved[k] = (value, now)

        guard let last = lastWritten[k] else {
            lastWritten[k] = (value, now)
            stats.firstEver += 1
            return true                                   // mai vista: si scrive
        }

        // Finché il valore si ripete identico da abbastanza tempo, si scrive
        // con la cadenza fitta invece che al battito.
        let streak = identicalSince[k].map { now.timeIntervalSince($0) } ?? 0
        let suspectStuck = streak >= Self.stuckEvidenceAfter
        let gap = suspectStuck ? Self.stuckEvidenceGap : Self.maxGap

        let expired = now.timeIntervalSince(last.at) >= gap
        let moved   = Self.isSignificantChange(type, from: last.value, to: value)

        guard expired || moved else {
            stats.skipped += 1
            return false
        }

        // Attribuzione per la diagnostica: se il valore si è mosso quello è il
        // motivo che conta, anche se era scaduto pure il tempo.
        if moved                { stats.changed += 1 }
        else if suspectStuck    { stats.stuckEvidence += 1 }
        else                    { stats.heartbeat += 1 }

        lastWritten[k] = (value, now)
        return true
    }

    /// Dimentica tutto. Serve ai test e a chi cambia casa sotto i piedi al
    /// logger: le chiavi sono UUID di accessori, e su una casa diversa lo stato
    /// vecchio non descrive più niente.
    mutating func reset() {
        lastWritten.removeAll()
        identicalSince.removeAll()
        lastObserved.removeAll()
    }

    /// Quanti sensori il gate sta seguendo. Solo per diagnostica.
    var trackedCount: Int { lastWritten.count }

    // MARK: - Diagnostica temporanea
    //
    // TEMPORANEO — serve solo a tarare le soglie sui dati veri: quanto si
    // risparmia davvero, e quanto costa la regola sui sensori bloccati (che
    // dipende da quanto i sensori di questa casa ripetono il valore identico,
    // cosa che non si può stimare a tavolino).
    //
    // Da rimuovere insieme a `Stats`, al campo `stats` e alla riga di log in
    // `SensorLogger.sampleAllSensors` una volta lette 24-48 ore di dati.

    /// Perché una lettura è finita in archivio — o perché non ci è finita.
    struct Stats {
        var sampled = 0
        var changed = 0            // il valore si è mosso oltre soglia
        var heartbeat = 0          // battito: troppo tempo dall'ultima riga
        var stuckEvidence = 0      // valore identico da troppo: prove per il detector
        var firstEver = 0          // primo incontro con questo sensore
        var skipped = 0

        var written: Int { changed + heartbeat + stuckEvidence + firstEver }

        var summary: String {
            let ratio = sampled > 0 ? Double(written) / Double(sampled) * 100 : 0
            return String(format:
                "campionate %d · archiviate %d (%.0f%%) — variazione %d, battito %d, sospetto blocco %d, prima volta %d",
                sampled, written, ratio, changed, heartbeat, stuckEvidence, firstEver)
        }
    }

    /// Contatori cumulativi da quando l'app è partita.
    private(set) var stats = Stats()
}
