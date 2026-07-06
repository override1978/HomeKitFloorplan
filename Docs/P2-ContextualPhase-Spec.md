# P2 — Contextual Phase: abitudini guidate dall'ambiente

**Stato**: spec approvata, da implementare
**Prerequisiti**: P0 (anti-duplicazione) ✅ e P1 (sequenze A→B) ✅ già in produzione
**Obiettivo**: trasformare i `ContextualCandidate` (oggi diagnostica pura) in pattern `.contextual` proponibili come automazioni HomeKit con trigger a soglia sensore.

---

## 1. Il problema che risolve

Le abitudini guidate dall'ambiente ("chiudo le tende quando fa caldo", "accendo i faretti quando è buio") **non hanno un orario fisso** → vengono respinte dal gate orario del PatternDetectionEngine (`maxTimeDeviationMinutes = 60`) e finiscono in `lastContextualCandidates` senza mai diventare proposte. Sono per definizione i pattern che l'utente non ha formalizzato, perché non vivono sull'orologio.

## 2. Perimetro

- **Effetti** (cosa viene azionato): tutti gli `habitEligibleTypes` esistenti — `light, blind, switch, thermostat, fan, airPurifier, humidifier, outlet`. Tende, clima e valvole sono già dentro.
- **Condizioni v1** (una sola, dominante): misure ambientali da `SensorReading` della stanza dell'effetto — `temperature, humidity, lightSensor (lux), carbonDioxide, airQuality, vocDensity` + outdoor (`outdoorTemperature/outdoorHumidity`, per effetti come tende/clima).
- **Fuori scope v1**: condizioni composte (AND), presenza come modificatore, stato-dispositivo come condizione (già coperto da P1). → v2.

## 3. Pipeline (dove si innesta)

```
PatternDetectionEngine.detect()
  └─ gate orario respinge un gruppo → ContextualCandidate (già esistente)
       └─ NUOVO: ContextualCorrelationEngine.analyze(candidates, readings)
            └─ pattern .contextual con condizione dominante
                 └─ BehavioralAnalysisService (tier/confidence come gli altri)
                      └─ AutomationOpportunity: triggerType "characteristic" ← GIÀ SUPPORTATO
                           └─ AutomationProposalMapper case "characteristic" ← GIÀ ESISTENTE
                                └─ Builder → HMEventTrigger a soglia ← GIÀ ESISTENTE
```

**Insight chiave**: il ponte opportunità→proposal→HomeKit per i trigger a soglia esiste già per intero (`triggerSensorType/triggerThreshold/triggerDirection` su AutomationOpportunity + `sensorSelection` nel mapper). P2 = produrre pattern contestuali ben formati; la parte a valle è fatta.

## 4. Algoritmo di correlazione (ContextualCorrelationEngine)

Per ogni `ContextualCandidate` (gruppo accessorio+azione respinto dal gate orario):

1. **Raccolta campioni-evento**: per ogni occorrenza dell'azione, la lettura più vicina (±15 min, la finestra di campionamento del SensorLogger) per ogni tipo sensore presente nella stanza dell'effetto + outdoor. Con più sensori dello stesso tipo nella stanza: mediana.
2. **Baseline di stanza**: distribuzione delle letture dello stesso tipo/stanza sull'intero periodo (30 giorni), così la condizione "sempre vera" viene smascherata.
3. **Per ogni tipo sensore candidato**:
   - `soglia` = mediana dei valori-evento, arrotondata a step leggibile per tipo (0.5°C, 5%, 25 lux, 50 ppm, 1 indice aria)
   - `direzione` = lato della baseline in cui cadono i valori-evento (evento > mediana-baseline → "above", altrimenti "below")
   - `hitRate` = frazione di eventi coerenti con (soglia, direzione)
   - `baseRate` = frazione del tempo di baseline in cui la condizione è comunque vera
   - `score = hitRate × (1 − baseRate)` — premia condizioni che spiegano gli eventi E che non sono banalmente sempre vere
4. **Condizione dominante** = score massimo, con gate minimi:
   - `observations ≥ 5` e `distinctDays ≥ 4`
   - `hitRate ≥ 0.70`
   - `baseRate ≤ 0.50`
   - `score ≥ 0.40`
5. **Pattern emesso**: `.contextual` con confidence = modello esistente (regularity × stability × recency) moltiplicato per lo score — così i tier/decay funzionano senza casi speciali.

## 5. Modello dati — ZERO schema change (stessa strategia di P1)

La condizione si codifica nei campi String esistenti di `BehavioralPattern`:

```
causeSignature = "context:<sensorTypeRaw>:<direction>:<threshold>"
                  es. "context:temperature:above:27.5"
causeName      = etichetta umana, es. "Temperatura Studio > 27.5°"
```

Helper di parsing simmetrico a P1: `ContextualCondition.parse(fromSignature:) -> (sensorType, direction, threshold)?` — testabile puro.

`AutomationOpportunity.init(from pattern:)` — caso `.contextual`:
```
triggerType       = "characteristic"
triggerSensorType = sensorTypeRaw
triggerThreshold  = threshold
triggerDirection  = direction   // "above"/"below" — già i valori che sensorSelection si aspetta
```
`isAutomationConvertible(.contextual)` = signature parsabile + effetto azionabile (stessi criteri di P1).

## 6. Anti-duplicazione (riuso P0)

- Checker esistente sull'accessorio effetto (timer ±45 min / event-trigger) — invariato.
- **Nuovo caso**: automazione esistente con trigger a soglia sullo **stesso tipo sensore + stesso accessorio effetto** → soppressa (estensione di `ExistingAutomationSnapshot` con i characteristic-event, se leggibili dal trigger; altrimenti v2).

## 7. UX

- Card opportunità esistenti: funzionano (triggerType "characteristic" ha già icona/copy).
- `naturalLanguageDescription` generata dal correlatore: *"Chiudi Tenda Studio quando la temperatura del Balcone supera i 30°"* — formato: `<azione effetto> quando <sensore> <stanza> <supera/scende sotto> <soglia>`.
- Diagnostica: sezione nel debug view con i candidati correlati e i loro score (esiste già `lastContextualCandidates`; aggiungere gli esiti).

## 8. Test plan

- `ContextualCondition.parse` round-trip (encode/decode signature).
- Correlatore con dati sintetici: (a) eventi sempre sopra soglia + baseline mista → condizione trovata con score alto; (b) condizione sempre-vera (baseRate ~1) → scartata; (c) < 5 osservazioni → scartata; (d) due sensori candidati → vince lo score maggiore.
- Opportunità da pattern contestuale → triggerType "characteristic" + strutturalmente convertibile (specchio del test P1).

## 9. Rischi e mitigazioni

| Rischio | Mitigazione |
|---|---|
| Campionamento a 15 min → lettura-evento imprecisa | Finestra ±15 min + mediana; le condizioni ambientali cambiano lentamente |
| Stanza senza sensori → nessuna condizione | Fallback outdoor per effetti clima/tende; altrimenti il candidato resta diagnostica |
| Condizione spuria (correlazione ≠ causa) | baseRate gate + score ≥ 0.40 + l'utente approva sempre esplicitamente |
| Multi-sensore stessa stanza con calibrazioni diverse | Mediana per tipo (stessa scelta già fatta per roomLux) |

## 10. Stima

- ContextualCorrelationEngine + parsing: ~mezza giornata
- Wiring service/opportunity/mapper (ricalca P1): ~2 ore
- Test + tuning gate con dati reali del master a muro: ~2 ore
