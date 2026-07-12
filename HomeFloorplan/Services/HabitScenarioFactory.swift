import Foundation
import SwiftData

// MARK: - Habit Scenario Factory
//
// Generatore deterministico di storia sintetica per la pipeline
// abitudini → automazioni. Produce AccessoryEvent + SensorReading + ActivityEvent
// indistinguibili dai dati reali (passano dallo stesso BehavioralEventPreprocessor),
// così l'intera catena analyze() → pattern → policy → opportunity → proposal
// è verificabile in secondi invece che in 15 giorni di telemetria vera.
//
// Ogni scenario codifica anche l'ESITO ATTESO a fine pipeline (vedi doc dei
// singoli metodi): è il contratto che PipelineEndToEndTests fa rispettare.
//
// Vincoli rispettati (BehavioralAnalysisService.analyze):
// - timestamp entro il cutoff di 30 giorni;
// - eventType nell'insieme eleggibile del motore;
// - eventi accessorio mai a ridosso di ActivityEvent scena (HabitNoiseFilter),
//   salvo negli scenari che esercitano volutamente il filtro;
// - profileID nil (compatibile con qualsiasi profilo attivo).
//
// Ricetta contestuale (collaudata in ContextualPhaseTests): 8 occorrenze, una
// ogni 2 giorni, a ore sparse 10–18 (stdDev > 60' → respinta dal gate orario,
// diventa ContextualCandidate) + baseline sensore oraria a valore neutro +
// lettura "anomala" 2' prima di ogni evento (hitRate 1.0, baseRate basso).
//
// Gli UUID sono FISSI (namespace DE30…): il seed in-app li usa per marcare i
// dati demo e il wipe li usa per rimuoverli, inclusi i derivati che
// sincronizzano via CloudKit. Nessun @Model viene modificato.

@MainActor
enum HabitScenarioFactory {

    // MARK: - Identità fisse dei dispositivi demo

    enum DemoID {
        static let climaSoggiorno   = UUID(uuidString: "DE300000-0000-4000-8000-000000000001")!
        static let termosifoneCamera = UUID(uuidString: "DE300000-0000-4000-8000-000000000002")!
        static let luceSoggiorno    = UUID(uuidString: "DE300000-0000-4000-8000-000000000003")!
        static let luceBagno        = UUID(uuidString: "DE300000-0000-4000-8000-000000000004")!
        static let tendaStudio      = UUID(uuidString: "DE300000-0000-4000-8000-000000000005")!
        static let luceIngresso     = UUID(uuidString: "DE300000-0000-4000-8000-000000000006")!

        static let sensoreTempSoggiorno = "demo-sensor-temp-soggiorno"
        static let sensoreTempCamera    = "demo-sensor-temp-camera"
        static let sensoreLuxSoggiorno  = "demo-sensor-lux-soggiorno"
        static let sensoreUmiditaBagno  = "demo-sensor-humidity-bagno"
        static let sensoreTempStudio    = "demo-sensor-temp-studio"
        static let sensoreLuxStudio     = "demo-sensor-lux-studio"

        /// Tutti gli accessoryID demo: usati dal wipe per rimuovere eventi e derivati.
        static var allAccessoryIDs: Set<UUID> {
            [climaSoggiorno, termosifoneCamera, luceSoggiorno, luceBagno, tendaStudio, luceIngresso]
        }

        static var allSensorUUIDs: Set<String> {
            [sensoreTempSoggiorno, sensoreTempCamera, sensoreLuxSoggiorno,
             sensoreUmiditaBagno, sensoreTempStudio, sensoreLuxStudio]
        }
    }

    // MARK: - Scenario

    struct Scenario {
        let name: String
        let accessoryEvents: [AccessoryEvent]
        let sensorReadings: [SensorReading]
        let activityEvents: [ActivityEvent]

        func seed(into context: ModelContext) throws {
            accessoryEvents.forEach { context.insert($0) }
            sensorReadings.forEach { context.insert($0) }
            activityEvents.forEach { context.insert($0) }
            try context.save()
        }
    }

    // MARK: - Scenari canonici

    /// POSITIVO — "Accendi il clima quando fa caldo".
    /// Atteso: pattern .contextual (temperature above ~26 @ Soggiorno → on),
    /// policy PASSA (target .climate), opportunity creata, proposal con
    /// start event a soglia + azione turnOn sul clima. isReadyForBuilder == true.
    static func coolingHabit(now: Date = Date()) -> Scenario {
        contextualScenario(
            name: "coolingHabit",
            accessoryID: DemoID.climaSoggiorno,
            accessoryName: "Demo Clima Soggiorno",
            roomName: "Demo Soggiorno",
            eventType: "thermostat",
            eventState: true,
            sensorUUID: DemoID.sensoreTempSoggiorno,
            sensorType: .temperature,
            baselineValue: 22,
            eventValue: 30,
            staggerMinutes: 0,
            now: now
        )
    }

    /// POSITIVO — "Accendi il riscaldamento quando fa freddo".
    /// Atteso: .contextual (temperature below ~19 @ Camera → on), policy PASSA,
    /// proposal completa con azione turnOn sul termosifone.
    static func heatingHabit(now: Date = Date()) -> Scenario {
        contextualScenario(
            name: "heatingHabit",
            accessoryID: DemoID.termosifoneCamera,
            accessoryName: "Demo Termosifone Camera",
            roomName: "Demo Camera",
            eventType: "thermostat",
            eventState: true,
            sensorUUID: DemoID.sensoreTempCamera,
            sensorType: .temperature,
            baselineValue: 21,
            eventValue: 15,
            staggerMinutes: 33,
            now: now
        )
    }

    /// POSITIVO — "Accendi le luci quando c'è poca luce".
    /// Atteso: .contextual (lightSensor below @ Soggiorno → on), policy PASSA
    /// (lux → light è coerente), proposal completa.
    static func lightsAtLowLux(now: Date = Date()) -> Scenario {
        contextualScenario(
            name: "lightsAtLowLux",
            accessoryID: DemoID.luceSoggiorno,
            accessoryName: "Demo Luce Soggiorno",
            roomName: "Demo Soggiorno",
            eventType: "light",
            eventState: true,
            sensorUUID: DemoID.sensoreLuxSoggiorno,
            sensorType: .lightSensor,
            baselineValue: 350,
            eventValue: 40,
            staggerMinutes: 66,
            now: now
        )
    }

    /// NEGATIVO — correlazione vera nei dati ma semanticamente incoerente:
    /// "Spegni la luce del bagno quando l'umidità supera il 45%".
    /// Atteso: il motore contestuale PUÒ derivare il pattern (la correlazione
    /// esiste), ma AutomationSemanticPolicy lo BLOCCA (humidity → light non è
    /// coerente): nessuna opportunity, nessuna proposal. Il pattern resta
    /// diagnostica/osservazione.
    static func spuriousHumidityLights(now: Date = Date()) -> Scenario {
        contextualScenario(
            name: "spuriousHumidityLights",
            accessoryID: DemoID.luceBagno,
            accessoryName: "Demo Luce Bagno",
            roomName: "Demo Bagno",
            eventType: "light",
            eventState: false,
            sensorUUID: DemoID.sensoreUmiditaBagno,
            sensorType: .humidity,
            baselineValue: 38,
            eventValue: 62,
            staggerMinutes: 99,
            now: now
        )
    }

    /// POSITIVO (P2 v2) — coppia di condizioni: "Chiudi la tenda dello studio
    /// quando fa caldo E c'è tanta luce". Le due baseline sono sfasate, così
    /// l'AND restringe davvero il baseRate e la coppia vince sulla singola.
    /// Atteso: .contextual a 2 condizioni, proposal con start events multipli
    /// (OR degli attraversamenti) + condizioni in AND, azione close sulla tenda.
    static func blindPairCondition(now: Date = Date()) -> Scenario {
        let calendar = Calendar.current
        var readings: [SensorReading] = []

        // Baseline 20 giorni, una lettura/ora per entrambi i sensori, fasi disgiunte.
        for hourOffset in stride(from: 1, to: 20 * 24, by: 1) {
            let t = now.addingTimeInterval(-Double(hourOffset) * 3600)
            let tempHigh = hourOffset % 10 < 3
            let luxHigh = (hourOffset + 5) % 10 < 3
            readings.append(SensorReading(
                accessoryUUID: DemoID.sensoreTempStudio, serviceType: .temperature,
                roomName: "Demo Studio", value: tempHigh ? 30 : 21, timestamp: t
            ))
            readings.append(SensorReading(
                accessoryUUID: DemoID.sensoreLuxStudio, serviceType: .lightSensor,
                roomName: "Demo Studio", value: luxHigh ? 900 : 120, timestamp: t
            ))
        }

        var events: [AccessoryEvent] = []
        for index in 0..<10 {
            let timestamp = scatteredWeekdayTimestamp(index: index, staggerMinutes: 132, calendar: calendar, now: now)
            events.append(AccessoryEvent(
                accessoryID: DemoID.tendaStudio,
                accessoryName: "Demo Tenda Studio",
                roomName: "Demo Studio",
                state: false,
                timestamp: timestamp,
                eventType: "blind"
            ))
            let t = timestamp.addingTimeInterval(-120)
            readings.append(SensorReading(
                accessoryUUID: DemoID.sensoreTempStudio, serviceType: .temperature,
                roomName: "Demo Studio", value: 30, timestamp: t
            ))
            readings.append(SensorReading(
                accessoryUUID: DemoID.sensoreLuxStudio, serviceType: .lightSensor,
                roomName: "Demo Studio", value: 900, timestamp: t
            ))
        }

        return Scenario(name: "blindPairCondition",
                        accessoryEvents: events,
                        sensorReadings: readings,
                        activityEvents: [])
    }

    /// REGRESSIONE — abitudine temporale classica: "Luce ingresso alle 07:00".
    /// Orari compatti (stdDev < 60') su 14 giorni: NON deve diventare candidato
    /// contestuale. 14 giorni saturano lo stabilityFactor della confidence
    /// (con 10 il pattern si fermava a 0.59, sotto il gate 0.60 delle opportunity).
    /// Atteso: pattern .temporal, proposal calendar completa.
    static func morningRoutine(now: Date = Date()) -> Scenario {
        let calendar = Calendar.current
        var events: [AccessoryEvent] = []

        // 21 giorni: il motore separa feriali e weekend, quindi il gruppo feriale
        // deve reggersi da solo (~15 giorni → confidence sopra il gate 0.60 con
        // margine; con 10-14 si fermava a 0.58 sul device reale).
        for dayOffset in 1...21 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: now)!
            // 07:00 ± ~10': variazione deterministica dal giorno.
            let minute = [0, 8, 3, 12, 6, 1, 10, 4, 9, 2][dayOffset % 10]
            let timestamp = calendar.date(bySettingHour: 7, minute: minute, second: 0, of: day)!
            events.append(AccessoryEvent(
                accessoryID: DemoID.luceIngresso,
                accessoryName: "Demo Luce Ingresso",
                roomName: "Demo Ingresso",
                state: true,
                timestamp: timestamp,
                eventType: "light"
            ))
        }

        return Scenario(name: "morningRoutine",
                        accessoryEvents: events,
                        sensorReadings: [],
                        activityEvents: [])
    }

    /// Tutti gli scenari, per il seed demo completo in-app.
    static func allScenarios(now: Date = Date()) -> [Scenario] {
        [coolingHabit(now: now),
         heatingHabit(now: now),
         lightsAtLowLux(now: now),
         spuriousHumidityLights(now: now),
         blindPairCondition(now: now),
         morningRoutine(now: now)]
    }

    // MARK: - Seed & wipe (riusati da test E2E e diagnostica in-app)

    /// Inietta l'intera storia demo nello store. Idempotente: rimuove prima
    /// qualsiasi seed precedente (tap ripetuti non accumulano duplicati).
    /// Riesegui l'analisi subito dopo per vedere pattern e opportunity.
    static func seedDemoHistory(into context: ModelContext, now: Date = Date()) throws {
        try wipeDemoData(from: context)
        for scenario in allScenarios(now: now) {
            try scenario.seed(into: context)
        }
    }

    /// Rimuove TUTTO ciò che i demo hanno prodotto, inclusi i derivati che
    /// sincronizzano via CloudKit (PersistedBehavioralPattern e
    /// AutomationOpportunity): un demo seminato sul master non deve mai
    /// propagarsi come dato reale agli altri device.
    /// Fetch+filtro in memoria: volumi piccoli, niente sorprese dai #Predicate.
    static func wipeDemoData(from context: ModelContext) throws {
        let accessoryIDs = DemoID.allAccessoryIDs
        let sensorUUIDs = DemoID.allSensorUUIDs
        let idStrings = Set(accessoryIDs.map(\.uuidString))

        for event in try context.fetch(FetchDescriptor<AccessoryEvent>())
        where accessoryIDs.contains(event.accessoryID) {
            context.delete(event)
        }
        for reading in try context.fetch(FetchDescriptor<SensorReading>())
        where sensorUUIDs.contains(reading.accessoryUUID) {
            context.delete(reading)
        }
        for pattern in try context.fetch(FetchDescriptor<PersistedBehavioralPattern>()) {
            if let id = pattern.accessoryID, accessoryIDs.contains(id) {
                context.delete(pattern)
            }
        }
        for opportunity in try context.fetch(FetchDescriptor<AutomationOpportunity>()) {
            if let raw = opportunity.effectAccessoryIDString, idStrings.contains(raw) {
                context.delete(opportunity)
            }
        }
        try context.save()
    }

    // MARK: - Capability sintetiche

    /// Descrittori capability coerenti con i dispositivi demo: quello che
    /// AutomationCapabilityCatalog.descriptors(in:) produrrebbe se la casa
    /// contenesse davvero questi accessori. Permette di attraversare il ramo
    /// characteristic del mapper senza HMHome.
    static func demoCapabilityDescriptors() -> [AutomationCapabilityDescriptor] {
        [
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreTempSoggiorno),
                accessoryName: "Demo Sensore Soggiorno", roomName: "Demo Soggiorno",
                characteristicType: SensorServiceType.temperature.hmCharacteristicType ?? "",
                title: "Temperature", unit: "°C", range: -10...50
            ),
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreTempCamera),
                accessoryName: "Demo Sensore Camera", roomName: "Demo Camera",
                characteristicType: SensorServiceType.temperature.hmCharacteristicType ?? "",
                title: "Temperature", unit: "°C", range: -10...50
            ),
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreLuxSoggiorno),
                accessoryName: "Demo Sensore Soggiorno", roomName: "Demo Soggiorno",
                characteristicType: SensorServiceType.lightSensor.hmCharacteristicType ?? "",
                title: "Light", unit: "lux", range: 0...10000
            ),
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreUmiditaBagno),
                accessoryName: "Demo Sensore Bagno", roomName: "Demo Bagno",
                characteristicType: SensorServiceType.humidity.hmCharacteristicType ?? "",
                title: "Humidity", unit: "%", range: 0...100
            ),
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreTempStudio),
                accessoryName: "Demo Sensore Studio", roomName: "Demo Studio",
                characteristicType: SensorServiceType.temperature.hmCharacteristicType ?? "",
                title: "Temperature", unit: "°C", range: -10...50
            ),
            numericSensorDescriptor(
                accessoryID: uuid(fromSensor: DemoID.sensoreLuxStudio),
                accessoryName: "Demo Sensore Studio", roomName: "Demo Studio",
                characteristicType: SensorServiceType.lightSensor.hmCharacteristicType ?? "",
                title: "Light", unit: "lux", range: 0...10000
            ),
            powerDescriptor(accessoryID: DemoID.climaSoggiorno, accessoryName: "Demo Clima Soggiorno", roomName: "Demo Soggiorno"),
            powerDescriptor(accessoryID: DemoID.termosifoneCamera, accessoryName: "Demo Termosifone Camera", roomName: "Demo Camera"),
            powerDescriptor(accessoryID: DemoID.luceSoggiorno, accessoryName: "Demo Luce Soggiorno", roomName: "Demo Soggiorno"),
            powerDescriptor(accessoryID: DemoID.luceBagno, accessoryName: "Demo Luce Bagno", roomName: "Demo Bagno"),
            powerDescriptor(accessoryID: DemoID.tendaStudio, accessoryName: "Demo Tenda Studio", roomName: "Demo Studio"),
            powerDescriptor(accessoryID: DemoID.luceIngresso, accessoryName: "Demo Luce Ingresso", roomName: "Demo Ingresso")
        ]
    }

    // MARK: - Ricetta contestuale condivisa

    private static func contextualScenario(
        name: String,
        accessoryID: UUID,
        accessoryName: String,
        roomName: String,
        eventType: String,
        eventState: Bool,
        sensorUUID: String,
        sensorType: SensorServiceType,
        baselineValue: Double,
        eventValue: Double,
        staggerMinutes: Int,
        now: Date
    ) -> Scenario {
        let calendar = Calendar.current
        var readings: [SensorReading] = []

        // Baseline: una lettura/ora per 22 giorni a valore neutro.
        for hourOffset in stride(from: 1, to: 22 * 24, by: 1) {
            readings.append(SensorReading(
                accessoryUUID: sensorUUID,
                serviceType: sensorType,
                roomName: roomName,
                value: baselineValue,
                timestamp: now.addingTimeInterval(-Double(hourOffset) * 3600)
            ))
        }

        // 10 eventi SOLO FERIALI a ore sparse (stdDev > 60' → gate orario
        // respinge → ContextualCandidate) con lettura "anomala" 2' prima.
        // Solo feriali perché il motore separa i gruppi per dayType, e su una
        // casa reale il rumore ambientale assorbe 1-2 eventi nei burst: con 8
        // eventi splittati il gruppo scendeva sotto il minimo di 5 della
        // correlazione (osservato sul device: "2× Demo Clima Soggiorno, …").
        var events: [AccessoryEvent] = []
        for index in 0..<10 {
            let timestamp = scatteredWeekdayTimestamp(index: index, staggerMinutes: staggerMinutes, calendar: calendar, now: now)
            events.append(AccessoryEvent(
                accessoryID: accessoryID,
                accessoryName: accessoryName,
                roomName: roomName,
                state: eventState,
                timestamp: timestamp,
                eventType: eventType
            ))
            readings.append(SensorReading(
                accessoryUUID: sensorUUID,
                serviceType: sensorType,
                roomName: roomName,
                value: eventValue,
                timestamp: timestamp.addingTimeInterval(-120)
            ))
        }

        return Scenario(name: name,
                        accessoryEvents: events,
                        sensorReadings: readings,
                        activityEvents: [])
    }

    /// Un evento ogni 2 giorni, ore 10–18 (10, 13, 16, 10, …): la ricetta che
    /// garantisce stdDev oltre il gate dei 60' con 8 giorni distinti.
    /// staggerMinutes: sfasamento PER SCENARIO — senza, tutti gli accessori demo
    /// scattano nello stesso istante e il rilevatore di burst li assorbe come
    /// cluster-scena, senza mai farli arrivare alla fase contestuale (osservato
    /// sul device reale: "8× Clima Soggiorno, Luce Bagno, Luce Soggiorno +2").
    /// L'index-esimo giorno FERIALE andando indietro nel tempo, a ore sparse
    /// 10–18 (stdDev oltre il gate dei 60'). Solo feriali: evita lo split
    /// feriale/weekend del motore, che dimezzerebbe il gruppo.
    private static func scatteredWeekdayTimestamp(
        index: Int,
        staggerMinutes: Int,
        calendar: Calendar,
        now: Date
    ) -> Date {
        var weekdaysFound = 0
        var dayOffset = 0
        var day = now
        while true {
            dayOffset += 1
            day = calendar.date(byAdding: .day, value: -dayOffset, to: now)!
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 {
                if weekdaysFound == index { break }
                weekdaysFound += 1
            }
        }
        let hour = 10 + (index * 3) % 9
        let base = calendar.date(bySettingHour: hour, minute: 15, second: 0, of: day)!
        return base.addingTimeInterval(Double(staggerMinutes) * 60)
    }

    // MARK: - Costruzione descrittori

    private static func numericSensorDescriptor(
        accessoryID: UUID,
        accessoryName: String,
        roomName: String,
        characteristicType: String,
        title: String,
        unit: String,
        range: ClosedRange<Double>
    ) -> AutomationCapabilityDescriptor {
        let characteristicID = uuid(from: "\(accessoryID.uuidString)-\(characteristicType)")
        return AutomationCapabilityDescriptor(
            id: "\(accessoryID.uuidString)-\(characteristicID.uuidString)",
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            roomName: roomName,
            characteristicID: characteristicID,
            characteristicType: characteristicType,
            title: title,
            valueKind: .numeric(unit: unit, range: range, step: 0.5),
            supportedRoles: [.trigger, .condition],
            defaultOperator: .greaterThan
        )
    }

    private static func powerDescriptor(
        accessoryID: UUID,
        accessoryName: String,
        roomName: String
    ) -> AutomationCapabilityDescriptor {
        let characteristicID = uuid(from: "\(accessoryID.uuidString)-power")
        return AutomationCapabilityDescriptor(
            id: "\(accessoryID.uuidString)-\(characteristicID.uuidString)",
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            roomName: roomName,
            characteristicID: characteristicID,
            characteristicType: "00000025-0000-1000-8000-0026BB765291", // PowerState
            title: "Power",
            valueKind: .boolean(activeLabel: "On", inactiveLabel: "Off"),
            supportedRoles: [.trigger, .condition],
            defaultOperator: .equals
        )
    }

    // MARK: - UUID deterministici

    /// UUID stabile derivato da una stringa (FNV-1a sui 16 byte): stesso input,
    /// stesso ID a ogni run — nessuna dipendenza da RNG o da Date.
    private static func uuid(from string: String) -> UUID {
        var hash1: UInt64 = 0xcbf29ce484222325
        var hash2: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash1 = (hash1 ^ UInt64(byte)) &* 0x100000001b3
            hash2 = (hash2 &+ UInt64(byte)) &* 0xcbf29ce484222325
        }
        var bytes = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: hash1 >> shift))
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: hash2 >> shift))
        }
        // Versione/variant RFC 4122 per validità formale.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func uuid(fromSensor sensorUUID: String) -> UUID {
        uuid(from: sensorUUID)
    }
}
