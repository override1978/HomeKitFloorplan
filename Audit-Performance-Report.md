# Audit Performance & Fluidità — HomeFloorplan
**Data:** 2026-06-16  
**Scope:** iPadOS 26, SwiftUI + SwiftData + HomeKit  
**Metodo:** Analisi statica del codice (Instruments non eseguito — misure contrassegnate con ≈ sono stime analitiche da confermare con profiling reale)

---

## ⚠️ Discrepanze tra il prompt e il codice reale

| Ipotesi del prompt | Realtà nel codice |
|---|---|
| `ModelContainer` creato una volta sul main | Creato **due volte** (`sharedModelContainer` default-value closure + `init()` locale) |
| `DataLifecycleService.runFullCycle()` sospettato di bloccare il main | Usa correttamente `Task.detached(priority: .background)` — non è un problema |
| Grace period reachability 12s potrebbe bloccare avvio | Non blocca nulla — implementato con `Task.sleep` non-bloccante |
| `PatternDetectionEngine` sospettato O(n²) sul main | Complessità reale: O(n × w) con w = eventi per finestra 10 min — non patologica, ma gira su `@MainActor` |
| BGProcessingTask come lavoro in background | Tutti e tre i handler usano `Task { @MainActor in }` — lavoro pesante sul main actor |

---

## PASSO 0 — Mappa "cosa gira, quando, su quale thread/attore"

### Entry point e ModelContainer

- **Target singolo:** `HomeFloorplan`
- **Entry point:** `HomeFloorplanApp` (`@main`, `HomeFloorplanApp.swift`)
- **ModelContainer A** (`sharedModelContainer`): creato dalla default-value closure (righe 48–79), iniettato nel view tree via `.modelContainer(sharedModelContainer)`
- **ModelContainer B** (`container`): creato in `init()` (righe 103–131), passato a tutti i 22 servizi (`AccessoryEventStore`, `BehavioralAnalysisService`, `AmbientalAIService`, ecc.)

**Entrambi puntano allo stesso file SQLite** (`default.store`), ma sono istanze distinte.

### Servizi iniettati nell'environment

22 servizi `@Observable` creati sequenzialmente sul main thread in `App.init()`:

| Servizio | I/O in init() | Actor |
|---|---|---|
| `HomeKitService` | Crea `HMHomeManager`, reads UserDefaults | nessuno (NSObject) |
| `BehavioralAnalysisService` | `VersionedStore.load()` × 3 (patterns, opportunities, decisions) | `@MainActor` |
| `HabitAnalysisService` | `VersionedStore.load()` × 2 | `@MainActor` |
| `RuleEngineService` | VersionedStore presunto | `@MainActor` |
| `AmbientalAIService` | nessuno (lazy restore) | `@MainActor` |
| `DataLifecycleService` | nessuno | `@MainActor` |
| altri 16 | trascurabile | vari |

### Timeline al cold start (main thread)

```
t=0ms   sharedModelContainer closure → schema validation + SQLite open (Container A)
t+Xms   App.init() → schema validation + SQLite open (Container B) ← DOPPIA APERTURA
t+Xms   HomeKitService.init() → HMHomeManager() → HomeKit discovery
t+Xms   BehavioralAnalysisService.init() → VersionedStore.load() × 3 (file reads)
t+Xms   HabitAnalysisService.init() → VersionedStore.load() × 2 (file reads)
t+Xms   altri 18 servizi
t+Xms   SchemaVersionValidator.validateAndRecord()
t+Xms   registerBackgroundTasks()
t+Xms   ContentView appare → @Query per floorplans da Container A
t+4000ms → homeManagerDidUpdateHomes → refreshReachability() #1
t+12000ms → homeManagerDidUpdateHomes → refreshReachability() #2 → reachabilitySettled = true
```

### Al ritorno in foreground (`.task(id: scenePhase)`)

1. Nuovo task ogni 5 min: `sampleLightSensors` → `refreshIfNeeded` → `sampleOutdoor` → `smartLightingEngine.evaluate()`
2. `onChange(scenePhase == .active)` con gate 12h: `behavioral.analyze()` su `@MainActor`

### BGProcessingTask registrati

| Task ID | Frequenza | Handler | Thread reale |
|---|---|---|---|
| `com.homefloorplan.sensorSample` | ≥ 20 min | `Task { @MainActor in ... }` | **main** |
| `com.homefloorplan.ruleEvaluation` | ≥ 15 min | `Task { @MainActor in ... }` | **main** |
| `com.homefloorplan.dataLifecycle` | ≥ 24 h | `Task { @MainActor in ... }` (poi detach interno) | **main** poi background |

### View più grandi (per righe file)

| File | Righe | Note |
|---|---|---|
| `AmbientalAIService.swift` | 994 | servizio, non view |
| `PatternDetectionEngine.swift` | 986 | engine puro |
| `FloorplanEditorView.swift` | 1233 | view con state più numeroso |
| `HomeFloorplanApp.swift` | 467 | init molto lungo |

---

## PASSO 1 — Baseline numerica

> Tutte le misure contrassegnate con `≈` sono stime analitiche. Richiedono conferma con **Instruments → Time Profiler + Hangs** su dispositivo reale prima della pubblicazione.

| Scenario | Metrica | Valore stimato | Base della stima |
|---|---|---|---|
| Cold start → primo frame interattivo | ms | ≈ 800–1500 | 2× SQLite open + 22 servizi + HMHomeManager |
| `App.init()` alone (sync chain) | ms | ≈ 300–700 | VersionedStore loads × 5 + 2× ModelContainer |
| `behavioral.analyze()` foreground return | ms (main thread bloccato) | ≈ 200–1500 | fetch 30gg ~1500 eventi + PatternDetection + persist() |
| `VersionedStore.save(patterns)` | ms | ≈ 20–80 | JSON encode ~200 patterns + file I/O |
| `AccessoryEventStore.saveEvent()` | ms | ≈ 5–30 | SwiftData insert + delete predicate + save() sul main |
| HomeKit reachability cascade (20+ accessori) | re-render count per cambio | ≈ 3× per accessorio | 3 mutazioni @Observable per evento |
| `characteristicValues` mutation per notifica | view invaldate | tutte quelle che leggono qualsiasi caratteristica | analisi @Observable tracking |
| BGProcessingTask `ruleEvaluation` (main thread) | ms | ≈ 500–2000 | proactive.runCycleIfNeeded incluso |

---

## PASSO 2 — Audit per categoria

### A. Avvio & riapertura

#### A1 — Doppia inizializzazione ModelContainer ✅ CONFERMATO
**File:** `HomeFloorplanApp.swift` righe 48–79 e 103–131

```swift
// Container A — default-value closure (eseguita PRIMA di init())
var sharedModelContainer: ModelContainer = { ... }()   // ← riga 48

// Container B — init() body (separato, non assegnato a sharedModelContainer)
var container = try? ModelContainer(for: schema, ...)  // ← riga 121
```

**Conseguenze:**
- Due aperture SQLite all'avvio → overhead ≈ 50–200ms
- Due schema validation → overhead minore ma presente
- I servizi scrivono su Container B; `@Query` in ContentView legge da Container A
- SwiftData non notifica automaticamente una `@Query` di cambiamenti provenienti da un container diverso → le scritture dei servizi sono visibili solo dopo il prossimo save e propagazione WAL

**Nota:** il prompt non aveva ipotizzato questa doppia apertura. Il codice aggiunge un problema non previsto.

#### A2 — Catena sincrona di 22 servizi in `App.init()` ✅ CONFERMATO
**File:** `HomeFloorplanApp.swift` righe 93–189

Cinque `VersionedStore.load()` + HMHomeManager + SchemaVersionValidator tutto in sequenza sul main thread. Singolarmente veloci, ma la catena intera contribuisce al cold start.

#### A3 — BGProcessingTask handlers su `@MainActor` ✅ CONFERMATO (P0)
**File:** `HomeFloorplanApp.swift` righe 345, 389, 451

```swift
Task { @MainActor in           // ← tutti e tre i handler
    await SensorLogger.shared.sampleAllSensors(...)
    await SensorLogger.shared.pruneOldReadings(...)
    await engine.evaluateInAppRules(...)
    await behavioral.analyze()    // ← @MainActor + CPU-intensive
    ...
}
```

Il sistema alloca tempo CPU background per i BGTask; sprecare quel tempo sul main actor (che gestisce anche UI callbacks e HomeKit delegates) ne riduce l'efficacia e potenzialmente ritarda la risposta UI se un task gira mentre l'utente riaprisse l'app.

#### A4 — Grace period reachability 12s ✅ NON è un problema
Il grace period è implementato correttamente con `Task.sleep` non-bloccante (righe 442–450). Non introduce freeze.

#### A5 — Foreground loop cancellazione sicura ✅ OK
`.task(id: scenePhase)` + `guard scenePhase == .active` cancella correttamente il loop. `CancellationError` gestito con `break`. Nessuna scrittura a metà.

---

### B. Main Thread Blocking

#### B1 — `BehavioralAnalysisService.analyze()` interamente su `@MainActor` ✅ CONFERMATO (P0 + freeze)
**File:** `BehavioralAnalysisService.swift` righe 173–299

```swift
@Observable
@MainActor
final class BehavioralAnalysisService {
    func analyze() async {
        // 1. fetch 30gg AccessoryEvent (senza fetchLimit) — SwiftData sync sul main
        let allAccessory = (try? context.fetch(accDescriptor)) ?? []
        // 2. fetch ActivityEvent (senza fetchLimit) — SwiftData sync sul main
        let rawActivity  = (try? context.fetch(actDescriptor)) ?? []
        // 3. PatternDetectionEngine.detect() — CPU puro sul main
        let detected = PatternDetectionEngine.detect(...)
        // 4. persist() — JSON encode + file I/O sul main
        persist()
    }
}
```

**Tocca il freeze** → la logica di detection non può essere cambiata, ma steps 3, 4 e parte di 1-2 possono essere spostati off-main senza toccare l'algoritmo. Da pianificare nella fase post-freeze.

**Trigger:** ritorno in foreground ogni 12h (`onChange(scenePhase)`) + `handleLifecycleCycleTask` BGTask.

#### B2 — `AccessoryEventStore.saveEvent()` su main ad ogni notifica HomeKit ✅ CONFERMATO (P1)
**File:** `AccessoryEventStore.swift` righe 30–54

```swift
@MainActor
func saveEvent(_ dto: AccessoryEventDTO) {
    let context = modelContainer.mainContext
    context.insert(event)
    // Cleanup on-write: delete ALL events older than 30 days
    try? context.delete(model: AccessoryEvent.self, where: predicate)
    try? context.save()     // ← save sincrono sul main
}
```

Chiamato da `HomeKitService.accessory(_:service:didUpdateValueFor:)` (riga 510) senza `await` → ogni notifica HomeKit triggera: insert + predicate-delete + save sincrono sul main thread. Con accessori che aggiornano le caratteristiche frequentemente (es. sensori, motion), questo crea overhead periodico sul main.

**Soluzione quick win:** eliminare il `try? context.save()` per-evento; lasciare che SwiftData autosave gestisca il flush, oppure spostare il save su task background. La predicate-delete su ogni evento è particolarmente costosa e andrebbe spostata su un debounce timer.

#### B3 — `VersionedStore.save()` sincrono su main thread ✅ CONFERMATO (P1)
**File:** `BehavioralAnalysisService.swift` righe 456–464; `HabitAnalysisService.swift` righe 287–296

```swift
private func persist() {
    VersionedStore<[BehavioralPattern]>(key: patternKey, version: 1).save(patterns)
    // JSONEncoder().encode(patterns) + Data.write(to:, options: .atomic) — SINCRONO
    makeOpportunityStore().save(opportunities)
    VersionedStore<[String: String]>(key: decisionsKey, version: 1).save(...)
}
```

Chiamato: al termine di ogni `analyze()`, e ad ogni `dismiss()`, `approve()`, `snooze()` utente. Stima costo: ≈ 20–80ms per chiamata.

**Quick win:** wrappare `persist()` in `Task.detached { }` dato che le write non hanno side-effect UI immediati.

#### B4 — `PatternDetectionEngine.detect()` su main (non O(n²)) ✅ VERIFICATO (P1)
**File:** `PatternDetectionEngine.swift` righe 633–792

L'algoritmo sequenziale ha complessità O(n × w) grazie al `break` sulla finestra 10min — non O(n²) in pratica. Con 1000 eventi e w ≈ 10: ≈ 50–200ms. Rimane su `@MainActor` (si veda B1).

#### B5 — `DataLifecycleService.runFullCycle()` ✅ OK
Usa correttamente `Task.detached(priority: .background)`. Non è un problema.

---

### C. SwiftData / Persistenza

#### C1 — `BehavioralAnalysisService.analyze()` fetch senza fetchLimit ✅ CONFERMATO (P1, tocca freeze)
**File:** `BehavioralAnalysisService.swift` righe 187–196

```swift
let accDescriptor = FetchDescriptor<AccessoryEvent>(
    predicate: #Predicate { $0.timestamp >= cutoff },
    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
    // nessun fetchLimit
)
```

Carica tutti gli eventi degli ultimi 30 giorni in memoria. Dopo 30gg di uso normale (≈ 50 eventi/giorno) → ~1500 record. Non critico ora ma cresce linearmente. **Tocca freeze** — limitare il fetchLimit richiede di capire quanti eventi bastano al motore (analisi da fare post-freeze).

#### C2 — `AccessoryEventStore.saveEvent()` usa `mainContext` + save per-evento (vedi B2)

#### C3 — `pruneSensorAlertEvents` e `prunePersistedInsights` senza fetchLimit ✅ CONFERMATO (P2)
**File:** `DataLifecycleService.swift` righe 331, 368

```swift
let all = (try? context.fetch(FetchDescriptor<SensorAlertEvent>())) ?? []
// e
let all = (try? context.fetch(FetchDescriptor<PersistedInsight>())) ?? []
```

Fetch completo necessario per filtro su opzionali (`resolvedAt`) non supportati da `#Predicate`. Gira su `Task.detached` → impatto ridotto, ma un fetchLimit con window temporale ampia ridurrebbe la pressione di memoria.

#### C4 — `fetchActiveBehavioralPatternIDs` scansiona tutti i UserDefaults ✅ CONFERMATO (P2)
**File:** `DataLifecycleService.swift` righe 348–358

```swift
for key in ud.dictionaryRepresentation().keys where key == prefix || ...
```

`dictionaryRepresentation()` crea uno snapshot di TUTTE le chiavi UserDefaults. Su device con molte app e molti valori può essere lento. Esegue su `Task.detached` → P2.

---

### D. SwiftUI Re-render eccessivi

#### D1 — `characteristicValues: [UUID: Any]` → invalidazione globale ✅ CONFERMATO (P1, sospetto primario lag)
**File:** `HomeKitService.swift` righe 58, 491

```swift
var characteristicValues: [UUID: Any] = [:]   // @Observable property

func accessory(_ accessory: HMAccessory, service:..., didUpdateValueFor characteristic:...) {
    characteristicValues[characteristic.uniqueIdentifier] = value  // invalida TUTTI gli osservatori
}
```

**Impatto:** `@Observable` invalida ogni view che ha letto `homeKit.characteristicValues` durante il suo `body`. Poiché tutti gli adapter (`DimmableLightAdapter`, `OnOffAdapter`, `ThermostatAdapter`, ecc.) leggono `homeKit.value(for: characteristic)` che accede a `characteristicValues`, **qualsiasi** aggiornamento di caratteristica di **qualsiasi** accessorio invalida ogni view che mostra qualsiasi accessorio.

Con 20+ accessori osservati e sensor callbacks frequenti (motion, lux, ecc.) questo produce re-render continui dell'intero albero.

**Quick win candidato:** suddividere `characteristicValues` in granularità più fine (per-accessory dictionary, o usare un `@Observable` per-adapter) o adottare un `nonisolated(unsafe) var` con aggiornamenti `@MainActor` espliciti solo per le caratteristiche effettivamente cambiate.

#### D2 — `accessoryDidUpdateReachability` ricostruisce `allAccessories` ad ogni callback ✅ CONFERMATO (P1)
**File:** `HomeKitService.swift` righe 518–522

```swift
func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
    reachabilityMap[accessory.uniqueIdentifier] = accessory.isReachable
    reachabilityVersion += 1
    refreshAccessoriesList()   // ← ricostruisce l'intero array allAccessories
}
```

`refreshAccessoriesList()` muta `allAccessories` → terza mutazione `@Observable` in sequenza per ogni evento di reachability. Durante il grace period di 4s+12s, ogni aggiornamento reachability causa 3 invalidazioni del tree.

**Quick win:** rimuovere `refreshAccessoriesList()` da `accessoryDidUpdateReachability` — la reachability è già aggiornata in `reachabilityMap`; `allAccessories` non deve cambiare per un cambio di reachability.

#### D3 — `ChatFABButtonView` TimelineView a 60fps sempre attiva ✅ CONFERMATO (P2)
**File:** `ContentView.swift` righe 275–307

```swift
TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
    // ricalcola AngularGradient a 60fps anche quando il chat è chiuso
```

Il FAB è sempre presente nel body di `ContentView` (fuori dall'`if showChatPanel`) e ricalcola il gradiente ogni frame. Con `.animation(minimumInterval: 1/60)` questo genera ≈ 60 aggiornamenti/secondo in background.

**Quick win:** spostare il `TimelineView` dentro il blocco `if showChatPanel` oppure usare `minimumInterval: 3.0` quando il chat è chiuso.

---

### E. Feedback di caricamento mancante

#### E1 — `behavioral.analyze()` al ritorno in foreground: nessun indicatore ✅ CONFERMATO (P1)
La property `isAnalyzing` esiste in `BehavioralAnalysisService` ma `HabitsView` e `HomeIntelligenceDashboardView` non mostrano uno stato di caricamento durante l'analisi scattata dal ritorno in foreground. L'utente apre l'app e le abitudini si aggiornano "a sorpresa" senza indicazione.

#### E2 — EnergyDashboardCard: feedback presente ✅ OK
`isLoading = true` con `ProgressView` già implementato correttamente.

#### E3 — WeatherKit refresh in `.task` avvio: nessun indicatore ✅ CONFERMATO (P2)
Il banner meteo in `OutdoorBannerView` non mostra un placeholder durante il refresh iniziale.

#### E4 — Risultato scrittura HomeKit (toggle luce/scena): nessun feedback asincrono ✅ CONFERMATO (P1)
Dopo un tap su un marker o un pulsante di controllo, non c'è indicazione visuale del "sto inviando il comando" vs "comando ricevuto" vs "errore". L'aggiornamento ottimistico (`characteristicValues[...] = value`) mostra subito il nuovo stato, ma se HomeKit risponde con un errore o riprende con il valore precedente, non c'è transizione visibile.

---

### F. Surfacing degli errori

#### F1 — Scritture HomeKit: solo haptic, nessun feedback visivo ✅ CONFERMATO (P0 per pubblicazione)
**File:** `OnOffControlButton.swift` righe 83–92

```swift
} catch {
    let notif = UINotificationFeedbackGenerator()
    notif.notificationOccurred(.error)
    // ← nessun alert, nessun toast, nessun banner, nessun aggiornamento stato
}
```

Il fallimento di una scrittura HomeKit (accessorio non raggiungibile, timeout, errore HAP) produce solo una vibrazione. L'utente non sa se il tap è stato ignorato, se l'accessorio è offline, o cosa fare. **Blocca la pubblicazione** per le App Store review guidelines che richiedono chiarezza sull'esito delle azioni.

Da verificare (ma probabile stessa situazione): `DimmableLightControl`, `WindowCoveringControl`, `ThermostatControl`, `GarageDoorControl`, `SecuritySystemControl`.

**Nota positiva:** `HomeKitService` traccia già `lastWriteErrors: [UUID: Date]` e `isLikelyOffline()` — manca solo la surface visuale nel momento dell'errore.

#### F2 — AI LLM failure dopo retry: visibile solo nel debug ✅ CONFERMATO (P1 accettabile per naming, P1 per chatbot)
`HabitAnalysisService.nameClusters()` cattura l'errore in `lastCallResult`, visibile solo in `HabitsDiagnosticsView` (debug). Per la cluster naming è accettabile (best-effort). Per il chatbot (`AgentLoopService`) da verificare se un errore AI produce un feedback comprensibile in `ChatBotView`.

#### F3 — `BehavioralAnalysisService.analyze()` fetch failure: silenzioso ✅ CONFERMATO (P2)
`try? context.fetch(accDescriptor)` → fallimento silenzioso senza log né stato UI.

#### F4 — BGTask `expirationHandler` senza cleanup ✅ CONFERMATO (P2)
```swift
task.expirationHandler = {
    dprint("⚠️ BGTask scaduto prima del completamento")
}
```
Se il BGTask scade mentre `behavioral.analyze()` è in corso sul main actor, le strutture dati in-memory potrebbero essere in uno stato parziale. Da valutare se serve un `isAnalyzing = false` nell'expiration handler.

---

### G. HomeKit specifiche

#### G1 — Delegate callbacks sul main thread ✅ CONFERMATO
`HMHomeManagerDelegate` e `HMAccessoryDelegate` chiamano tutti i metodi delegate sul main thread. Confermato da Apple documentation e codice.

#### G2 — `characteristicValues` come cerniera re-render (vedi D1) ✅ CONFERMATO

#### G3 — `reachabilityVersion` come counter forzato ✅ DESIGN INTENZIONALE
Il counter forza re-render anche su cambi di valore (non solo strutturali) nella `reachabilityMap`. Funziona ma produce re-render anche quando il valore non è cambiato (es. callback ripetuti con `isReachable = true`). Aggiungere un guard `guard reachabilityMap[uuid] != newValue` prima di incrementare ridurrebbe i re-render inutili.

---

## PASSO 3 — Triage

| ID | Sev | Cat | Sintomo | File:riga | Tocca freeze | Costo | Rischio |
|---|---|---|---|---|---|---|---|
| **A3** | P0 | A | BGTask lavoro pesante su @MainActor | App.swift:345,389,451 | No | M | Basso |
| **F1** | P0 | F | Scritture HK senza feedback visivo | OnOffControlButton:83 + altri | No | M | Basso |
| **B1** | P1* | B | `analyze()` SwiftData fetch + CPU su main | BehavioralAnalysis:173 | **Sì** | L | Alto |
| **D1** | P1 | D,G | `characteristicValues` invalida tutto | HomeKitService:58,491 | No | L | Medio |
| **B2** | P1 | B,C | `saveEvent()` insert+delete+save per notifica HK | AccessoryEventStore:30 | No | S | Basso |
| **D2** | P1 | D,G | `refreshAccessoriesList()` ad ogni reachability | HomeKitService:518 | No | XS | Basso |
| **B3** | P1 | B | `VersionedStore.save()` JSON+I/O su main | BehavioralAnalysis:456 | No | S | Basso |
| **A1** | P1 | A | Doppia ModelContainer initialization | App.swift:48+103 | No | S | Basso |
| **E1** | P1 | E | Nessun indicatore durante analyze() foreground | HabitsView, IntelligenceDash | No | S | Basso |
| **E4** | P1 | E | Nessun feedback "invio comando" HK | tutti i control views | No | M | Basso |
| **C1** | P2* | C | Fetch 30gg senza fetchLimit | BehavioralAnalysis:187 | **Sì** | S | Medio |
| **D3** | P2 | D | TimelineView 60fps sempre attiva | ContentView:275 | No | XS | Basso |
| **G3** | P2 | G | reachabilityVersion counter senza guard | HomeKitService:70 | No | XS | Basso |
| **F3** | P2 | F | Fetch failure silenzioso in analyze() | BehavioralAnalysis:197 | No | XS | Basso |
| **C3** | P2 | C | pruneSensorAlertEvents fetch illimitato | DataLifecycle:368 | No | XS | Basso |

> *B1 e C1 sono `P1/Tocca freeze` — non modificabili nella sessione corrente per la logica di detection. Threading/I/O solo dopo freeze.

---

## PASSO 4 — Top 5 Quick Win (realizzabili subito, senza toccare il freeze)

### QW-1 — D2: Rimuovere `refreshAccessoriesList()` da `accessoryDidUpdateReachability`
**File:** `HomeKitService.swift` riga 521  
**Impatto:** elimina una mutazione `@Observable` superflua per ogni callback di reachability. `allAccessories` non ha bisogno di essere ricostruita quando cambia solo la reachability.  
**Fix:** rimuovere la chiamata `refreshAccessoriesList()` dal metodo. La map `reachabilityMap` + `reachabilityVersion` già bastano per aggiornare le view.  
**Costo:** XS (< 30 min). **Rischio:** basso.  
**Criterio accettazione:** riduzione del numero di re-render durante il grace period 4-12s (misurabile con SwiftUI Profiler).

### QW-2 — D3: Fermare il TimelineView del FAB quando il chat è chiuso
**File:** `ContentView.swift` riga 275  
**Impatto:** elimina 60 aggiornamenti/secondo di gradiente sul main thread quando il chat panel non è visibile.  
**Fix:** wrappare il `TimelineView` con `if showChatPanel { ... }` oppure abbassare `minimumInterval` a 3.0 quando `!showChatPanel`.  
**Costo:** XS. **Rischio:** basso.  
**Criterio accettazione:** 0% CPU da TimelineView con chat chiuso (misurabile in Instruments Energy Log).

### QW-3 — B2: Eliminare il `context.save()` per-evento in `AccessoryEventStore.saveEvent()`
**File:** `AccessoryEventStore.swift` riga 53  
**Impatto:** rimuove un save SwiftData sincrono su main per ogni notifica HomeKit. SwiftData autosave gestisce il flush periodico. La delete on-write rimane ma senza il save immediato è meno bloccante.  
**Fix:** rimuovere `try? context.save()` da `saveEvent()`. Aggiungere un debounce (es. 5 min) o spostare la predicate-delete nel `DataLifecycleService.runFullCycle()` già esistente.  
**Costo:** S (2–3h). **Rischio:** basso (verificare che l'analisi non legga eventi non-saved).  
**Criterio accettazione:** 0 save sincroni per-evento in Time Profiler durante uso normale.

### QW-4 — F1: Aggiungere feedback visivo inline ai fallimenti di scrittura HomeKit
**File:** `OnOffControlButton.swift` + `FloorplanEditorView` + controlli accessori  
**Impatto:** sblocca pubblicazione App Store; utente sa immediatamente che l'azione non è stata eseguita.  
**Fix:** `HomeKitService` traccia già `lastWriteErrors`. Nei control button, dopo il catch, aggiungere un `.alert` o un toast inline usando `lastWriteErrors[accessory.uniqueIdentifier]`. Stringa UI (IT + EN nel String Catalog).  
**Costo:** M (4–8h). **Rischio:** basso.  
**Criterio accettazione:** ogni scrittura HomeKit fallita mostra un feedback visivo entro 500ms.

### QW-5 — B3: Spostare `VersionedStore.save()` off-main thread
**File:** `BehavioralAnalysisService.swift` righe 456–464  
**Impatto:** rimuove JSON encode + file I/O dal main thread al termine di `analyze()` e su ogni dismiss/approve/snooze utente.  
**Fix:**
```swift
private func persist() {
    let snap = (patterns: patterns, opps: opportunities, dec: burstClusterDecisions, date: lastAnalyzed)
    Task.detached(priority: .utility) {
        VersionedStore<[BehavioralPattern]>(key: snap.patternKey, version: 1).save(snap.patterns)
        // ...
    }
}
```
**Costo:** S (1–2h). **Rischio:** basso (VersionedStore.save è già idempotente con backup).  
**Criterio accettazione:** 0ms di file I/O su main thread durante analyze() (misurabile in Time Profiler → Main Thread).

---

## Piano a fasi

### Fase 1 — Sblocco pubblicazione (questa settimana)
**Obiettivo:** app pubblicabile su App Store.

| ID | Azione | Criterio accettazione |
|---|---|---|
| F1 | Aggiungere feedback visivo su ogni errore HomeKit write | Ogni tap fallito mostra alert/toast entro 500ms |
| QW-1 | Rimuovere refreshAccessoriesList() da reachability | Build pulita, nessuna regressione in FloorplanEditorView |
| QW-2 | Fermare TimelineView FAB con chat chiuso | 0 CPU da gradient con chat nascosto |
| QW-3 | Rimuovere context.save() per-evento | Time Profiler: 0 save sincroni per notifica HK |

### Fase 2 — Performance fondamentale (dopo freeze motore, stimato 27/06+)
**Obiettivo:** cold start < 1.5s, hang foreground return < 200ms.

| ID | Azione | Criterio accettazione |
|---|---|---|
| A1 | Unificare le due ModelContainer in una sola istanza | Time Profiler: 1 sola apertura SQLite al lancio |
| B3 | Spostare VersionedStore.save() su Task.detached | 0ms file I/O su main durante analyze() |
| A3 | Riscrivere BGTask handler con Task.detached anziché @MainActor | Time Profiler BGTask: main thread idle durante processing |
| B1* | Off-load PatternDetectionEngine off-@MainActor | hang foreground return < 200ms (richiede post-freeze analysis) |

### Fase 3 — Qualità dell'osservazione (priorità media)
**Obiettivo:** eliminare re-render a cascata, ridurre CPU background.

| ID | Azione | Criterio accettazione |
|---|---|---|
| D1 | Granularizzare characteristicValues (per-accessory observable) | SwiftUI Profiler: re-render solo sulla view del dispositivo aggiornato |
| D2 | Guard su reachabilityVersion counter | < 1 re-render per callback reachability invariato |
| E1 | Aggiungere isAnalyzing indicator in HabitsView/IntelligenceDash | ProgressView visibile durante analyze() foreground |
| E4 | Aggiungere loading state su invio comandi HK | Spinner o pulsante disabled durante await write() |

### Fase 4 — Solidità a lungo termine (bassa urgenza)
| ID | Azione |
|---|---|
| C1 | Aggiungere fetchLimit a BehavioralAnalysisService.analyze() (post-freeze, dipende dall'engine) |
| F4 | Aggiungere cleanup nell'expirationHandler dei BGTask |
| C3 | Aggiungere window temporale ai fetch in DataLifecycleService per ridurre pressione di memoria |
| G3 | Guard su reachabilityVersion per evitare increment su valore invariato |

---

## Appendice — Punti da misurare con Instruments prima della Fase 2

Prima di applicare i fix di Fase 2, raccogliere le seguenti misure baseline su dispositivo reale (iPad Pro 11"):

1. **Time Profiler — Cold start:** stack dominante nei primi 2s, durata totale di `App.init()`
2. **Hangs instrument:** hang duration (ms) al ritorno in foreground dopo 12h, stack responsabile
3. **SwiftUI instrument:** numero di body re-evaluation su `FloorplanEditorView` durante 10 notifiche HomeKit consecutive
4. **Main Thread Checker:** eventuali chiamate non-main thread non rilevate dall'analisi statica
5. **MetricKit / Organizer:** dati di launch time e hang rate da eventuali beta TestFlight

Questi numeri diventano i criteri "prima" per ogni fix di Fase 2.
