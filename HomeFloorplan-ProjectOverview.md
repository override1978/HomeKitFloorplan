# HomeFloorplan — Project Overview
> Documento di riferimento architetturale e tecnico  
> Versione: 2026-06-11 | Framework: SwiftUI + SwiftData + HomeKit | iOS 17.0+

---

## Indice

1. [Struttura File](#1-struttura-file)
2. [Architettura e Pattern Principali](#2-architettura-e-pattern-principali)
3. [Componente AI Ambientale](#3-componente-ai-ambientale)
4. [Componente AI Abitudini](#4-componente-ai-abitudini)
5. [Rule Engine e Opportunità](#5-rule-engine-e-opportunità)
6. [Sistema Notifiche Proattive](#6-sistema-notifiche-proattive)
7. [Energy Tracking](#7-energy-tracking)
8. [Persistenza Dati](#8-persistenza-dati)
9. [Theming e Brand Color](#9-theming-e-brand-color)
10. [Punti Critici, Problematiche e Punti Deboli](#10-punti-critici-problematiche-e-punti-deboli)

---

## 1. Struttura File

### Views/
| File | Responsabilità |
|------|----------------|
| `ContentView.swift` | App root: guard onboarding, HomeKit, NavigationSplitView, screensaver |
| `HomeIntelligenceDashboardView.swift` | Dashboard principale AI (≈1800 righe): 7 sezioni, phase hero, habits, feed |
| `HabitsView.swift` | Vista dedicata alle abitudini: 3 tier (Suggested, Listening, Active) |
| `IntelligenceFeedView.swift` | Timeline cronologica di tutti gli eventi AI con filtri per categoria |
| `SecurityView.swift` | Security health score, sensori, azioni rapide arm/disarm/lock |
| `RuleEditorView.swift` | Editor manuale di regole di automazione |
| `ActiveRulesView.swift` | Lista regole attive con toggle enable/disable |
| `SidebarView.swift` | Navigazione laterale app |
| `SettingsView.swift` | AI provider, consent, home selection |
| `AISettingsView.swift` | Configurazione API key, provider, feature flags |
| `AIConsentView.swift` | Flusso consenso invio dati a LLM |

### Environment/
| File | Responsabilità |
|------|----------------|
| `EnvironmentDashboardView.swift` | Orchestratore schermata Ambiente (hero, outdoor, digest, room grid) |
| `EnvironmentAIDigestCard.swift` | Card carosello con insight AI per stanza (TabView paginato) |
| `EnergyDashboardCard.swift` | Widget consumo energetico per stanza con anomalie |
| `AmbientalAIService.swift` | Service AI per analisi ambientale per stanza (993 righe) |
| `AmbientalAIInsight.swift` | Modello output del LLM ambientale (insight per stanza) |
| `EnvironmentViewModel.swift` | ViewModel che aggrega letture sensori |
| `EnvironmentPreProcessor.swift` | Pre-elaborazione deterministica prima del LLM |
| `AlertNotificationService.swift` | Notifiche push per soglie sensori superati |
| `AlertThresholdSettingsView.swift` | Settings soglie personalizzate per categoria |
| `RoomSectionView.swift` | Card per singola stanza con sensori |
| `SensorDetailSheet.swift` | Sheet dettaglio sensore con grafico storico |
| `SensorLogger.swift` | Salva SensorReading in SwiftData |

### Services/
| File | Responsabilità |
|------|----------------|
| **AI Engine** | |
| `HabitAnalysisService.swift` | Pipeline AI (LLM) per habit detection da 14gg di storico |
| `BehavioralAnalysisService.swift` | Orchestratore on-device behavioral learning (30gg) |
| `PatternDetectionEngine.swift` | Algoritmi puri: temporal + sequential pattern detection |
| `BehavioralDeviationDetector.swift` | Rileva abitudini saltate (deviazioni dai pattern stabili) |
| `ProactiveIntelligenceService.swift` | Master orchestrator di tutti i segnali → ProactiveNotification |
| `AIService.swift` | HTTP layer unificato Claude/OpenAI con retry esponenziale |
| `AISettings.swift` | Configurazione AI persista in UserDefaults + Keychain |
| `AIPromptVersion.swift` | Versioning prompt per cache invalidation |
| `AITraceLogger.swift` | Log debug delle chiamate AI |
| **HomeKit Core** | |
| `HomeKitService.swift` | Interfaccia unificata HMHomeManager, accessori, delegate |
| `HomeKitScenesService.swift` | Gestione scene HomeKit |
| `HomeKitAutomationsService.swift` | Gestione automazioni HomeKit native |
| **Automazioni** | |
| `RuleEngineService.swift` | Creazione, valutazione ed esecuzione regole di automazione |
| `ActionExecutionService.swift` | Esegue azioni HomeKit da regole o insight |
| `ActionResolver.swift` | Risolve ActionIntent → HMAccessory + characteristic target |
| `ActionIntentInferrer.swift` | Inferisce ActionIntent da contesto (es. coolRoom → fan/AC) |
| **Data** | |
| `AccessoryEventStore.swift` | CRUD AccessoryEvent in SwiftData con cleanup rolling 30gg |
| `ActivityLoggerService.swift` | Salva ActivityEvent (scene execution, rule execution) |
| `DataLifecycleService.swift` | Aggregazione e pruning dati storici (daily background task) |
| `EnergyUsageTracker.swift` | Calcola ore di utilizzo per accessorio da eventi ON/OFF |
| `EnergyInsightBuilder.swift` | Rileva anomalie energetiche (alwaysOn, anomalousRuntime) |
| `EnergyIgnoreStore.swift` | Set di accessoryID esclusi dal monitoraggio energetico |
| **Prediction** | |
| `HomeKnowledgeService.swift` | Learning phase e knowledge score per dominio |
| `WeatherKitService.swift` | Forecast WeatherKit integrato |
| `EnvironmentalAlertBuilder.swift` | Genera alert ambientali da letture sensori |
| `EnvironmentalPatternAnalyzer.swift` | Rileva pattern stagionali nelle letture |
| `SecurityScoreService.swift` | Calcola security health score |
| **Adapter** | |
| `AccessoryAdapter.swift` | Protocollo base per tutti gli adapter HomeKit |
| `AccessoryAdapterFactory.swift` | Factory che istanzia l'adapter corretto per ogni HMAccessory |
| `AccessoryAppearance.swift` | Icon override e colori personalizzati per accessorio |
| `AccessoryCategorizer.swift` | Classifica HMAccessory per categoria funzionale |

### Models/
| File | Tipo | Persistenza |
|------|------|-------------|
| `AccessoryEvent.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `ProactiveNotification.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `Rule.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `PersistedInsight.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `RoomAnalysisState.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `ActionEffectivenessEvent.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `SensorReading.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `ActivityEvent.swift` | `@Model` SwiftData | SQLite via SwiftData |
| `HabitPattern.swift` | `Codable struct` | UserDefaults (JSON) |
| `BehavioralPattern.swift` | `Codable struct` | UserDefaults (JSON) |
| `AutomationOpportunity.swift` | `Codable struct` | UserDefaults (JSON) |
| `BehavioralEvent.swift` | `Codable struct` | Non persistito (calcolato in memoria) |
| `EnergyUsageRecord.swift` | `struct` | Non persistito (calcolato al volo) |
| `AmbientalAIInsight.swift` | `struct` | Non persistito (calcolato in memoria) |

### Accessories/
| File | Responsabilità |
|------|----------------|
| `AccessoriesTabView.swift` | Tab principale lista accessori con filtri |
| `AccessoriesHeroView.swift` | Hero card con sommario casa |
| `AccessoriesViewModel.swift` | ViewModel per gestione accessori |
| `AccessoryRoomDetailView.swift` | Dettaglio stanza con lista accessori e controlli |
| `RoomAccessoryData.swift` | Struttura dati aggregata per stanza |
| `AccessoryHealthEngine.swift` | Calcola "salute" accessori (battery, reachability, lastSeen) |

---

## 2. Architettura e Pattern Principali

### 2.1 Pattern Architetturale: Service-Oriented MVVM

L'app non usa un'architettura MVVM classica con ViewModel 1:1 per ogni view. Si basa su **Observable Services** iniettati come environment:

```
HomeFloorplanApp
  └── Environment injection:
        HomeKitService           (@Observable)
        HabitAnalysisService     (@Observable)
        BehavioralAnalysisService(@Observable)
        ProactiveIntelligenceService (@Observable)
        RuleEngineService        (@Observable)
        AmbientalAIService       (@Observable)
        ...
```

Le View leggono stato direttamente dai service via `@Environment(ServiceType.self)`. Non esiste un layer ViewModel separato nelle view principali — il service stesso è il "ViewModel".

### 2.2 Adapter Pattern (Accessori HomeKit)

Il progetto usa un pattern Adapter classico per astrarre la complessità dei device HomeKit:

```
HMAccessory
     │
     ▼
AccessoryAdapterFactory.adapter(for: accessory)
     │
     ├── LightAdapter         (PowerState + Brightness)
     ├── DoorLockAdapter      (LockCurrentState)
     ├── ThermostatAdapter    (TargetTemperature)
     ├── BlindAdapter         (CurrentPosition)
     ├── ContactSensorAdapter (ContactState)
     ├── GarageDoorAdapter    (CurrentDoorState)
     ├── CameraAdapter        (Streaming + Motion)
     ├── AirPurifierAdapter   (Active + TargetAirPurifierState)
     ├── SecuritySystemAdapter(SecuritySystemCurrentState)
     └── SensorAdapter        (temperatura/umidità/CO₂/qualità aria)
```

**Protocollo:**
```swift
protocol AccessoryAdapter {
    var canRead: Bool { get }
    var canWrite: Bool { get }
    func readCurrentValue() async throws -> Any?
    func writeValue(_ value: Any, type: HMCharacteristicType?) async throws
}
```

### 2.3 HomeKitService: Gestione Centralizzata

`HomeKitService` è il punto di accesso unico a HomeKit:

- `HMHomeManagerDelegate` per aggiornamenti casa (casa aggiunta/rimossa)
- `HMAccessoryDelegate` per state changes accessori
- `characteristicValues: [UUID: Any]` — dizionario in memoria con lo stato attuale di ogni caratteristica
- `reachabilityMap: [UUID: Bool]` — traccia online/offline di ogni accessorio
- `allAccessories` — lista piatta di tutti gli accessori in tutti i servizi
- **Grace period**: nelle prime ~12 secondi dopo il launch `isReachable()` ritorna sempre `true` per compensare il tempo di stabilizzazione HomeKit
- `isAlarmSystemTriggered: Bool` — property diretta aggiornata dal delegate, evita computed chains fragili

**Subscription:** Le caratteristiche sono osservate via `HMAccessoryDelegate.accessory(_:service:didUpdateValueFor:)`. Ogni update passa per `AccessoryEventStore.makeDTO()` che decide se salvare l'evento.

### 2.4 HAP UUIDs Rilevanti

```
PowerState   (luci/switch):      00000025-0000-1000-8000-0026bb765291
Active       (thermostat/fan):   000000b0-0000-1000-8000-0026bb765291
Brightness:                      00000008-0000-1000-8000-0026bb765291
ContactState:                    0000006a-0000-1000-8000-0026bb765291
MotionDetected:                  00000022-0000-1000-8000-0026bb765291
TargetPosition (tapparelle):     0000007c-0000-1000-8000-0026bb765291
SecurityCurrentState:            00000066-0000-1000-8000-0026bb765291
  └── valore 4 = triggered (allarme scattato)
```

### 2.5 Persistenza: SwiftData + UserDefaults (doppio layer)

Il progetto usa **due layer di persistenza separati** con responsabilità distinte:

| Layer | Cosa persiste | Motivazione |
|-------|---------------|-------------|
| **SwiftData (SQLite)** | AccessoryEvent, SensorReading, ProactiveNotification, Rule, ActivityEvent, PersistedInsight, RoomAnalysisState, ActionEffectivenessEvent | Dati time-series, query predicato, lookup efficiente |
| **UserDefaults (JSON)** | BehavioralPattern[], HabitPattern[], AutomationOpportunity[] | Strutture dati complesse, non-relazionali, nessuna query range |

**Rischio noto:** I dati in UserDefaults non partecipano alle migration di SwiftData. Se cambiano le strutture `BehavioralPattern` o `HabitPattern`, i dati codificati diventano incompatibili silenziosamente. Non esiste un meccanismo di versioning per queste strutture.

**Migration safety (SwiftData):** `HomeFloorplanApp` gestisce il caso di migration failure: se il `ModelContainer` non si inizializza, cancella lo store e riparte da zero (dati storici persi).

### 2.6 Background Tasks

Tre `BGProcessingTask` schedulati dal sistema iOS:

| Task ID | Servizio | Frequenza | Azione |
|---------|----------|-----------|--------|
| `sensorSampleTaskID` | HomeKitService | ~15 min | Campiona valori sensori e li salva |
| `ruleEvaluationTaskID` | RuleEngineService | ~15 min | Valuta regole `inApp` e le esegue se condizione vera |
| `lifecycleTaskID` | DataLifecycleService | ~24h | Aggregazione + pruning dati storici |

**Caveat:** I BGProcessingTask vengono schedulati da iOS in base a disponibilità (device in carica, connesso, attività di rete). Non sono garantiti all'ora esatta.

### 2.7 Theming e Brand Color

`BrandColor` è definito come estensione `Color` (non trovato un file dedicato):

```swift
// Usato in tutto il progetto:
BrandColor.primary          // colore brand principale (blu/indigo)
Color.accentColor           // tint globale iOS
```

I colori categoriali per le notifiche sono mappati in `notificationColor(for:)` in `IntelligenceFeedView.swift`:

```swift
"blue"   → .blue
"purple" → .purple
"red"    → .red
"yellow" → Color(red: 0.85, green: 0.70, blue: 0.0)
"amber"  → Color(red: 0.90, green: 0.60, blue: 0.10)
"teal"   → .teal
"orange" → .orange
"indigo" → .indigo
"green"  → .green
```

Non esiste un design token system centralizzato o un file di tema dedicato. I valori cromatici sono inline nei file di view.

---

## 3. Componente AI Ambientale

### 3.1 Panoramica

Il sistema AI ambientale analizza **ogni stanza singolarmente** e genera insight testuali con suggerimenti di azione. È il componente AI con il ciclo più breve (15 minuti per stanza) e il più visibile all'utente finale.

**Pipeline completa: dal dato grezzo all'insight in UI**

```
SensorReading (SwiftData)
       │
       ▼ [1. AGGREGAZIONE]
EnvironmentPreProcessor
  ├── calcola urgency (normal/warning/danger) per ogni sensore
  ├── devia sigma rispetto al baseline 7-day personale
  └── genera sensorStatus[] normalizzato
       │
       ▼ [2. FINGERPRINT CHECK]
RoomAnalysisState (SwiftData)
  └── se semantic fingerprint == precedente → SKIP LLM (risparmio quota)
      Eccezione: danger-level con intents vuoti → retry obbligatorio
       │
       ▼ [3. PAYLOAD CONSTRUCTION]
Payload JSON al LLM:
  ├── sensorStatus[]       urgency + sigma deviance per sensore
  ├── periods[]            ultime 12h divise in 3 fasce da 4h (trend)
  ├── baseline7d           media e stdDev 7 giorni personali per stanza
  ├── presence             people_home | sleeping | home_empty
  ├── localTime, season, roomType
  └── outdoor              weather context (Sprint 31, se disponibile)
       │
       ▼ [4. LLM CALL]
AIService.sendPrompt()
  ├── Provider: Claude claude-haiku-4-5 o OpenAI gpt-4o-mini
  ├── System prompt versionato (AIPromptVersion.currentEnvironmental = "env_v3")
  ├── Retry esponenziale (1s, 2s, 4s + jitter)
  └── Output: JSON con message, severity, intents[], intelligenceLevel, patternKey, why
       │
       ▼ [5. SEVERITY GATE]
EnvironmentPreProcessor.clampSeverity()
  └── LLM severity viene cappata al ceiling deterministico calcolato in step 1
      (LLM non può dichiarare "anomaly" se dati dicono "normal")
       │
       ▼ [6. INTENT FILTERING]
AmbientalAIService
  ├── rimuove HVAC/ventilazione per stanze outdoor (logica room-type aware)
  └── rimuove intenti incompatibili con sensori non presenti nella stanza
       │
       ▼ [7. INTENT DEDUPLICATION]
AmbientalAIService
  └── se nuovi intents == intents precedenti → non ri-surfaced (evita UI churn)
       │
       ▼ [8. PERSISTENZA]
PersistedInsight (SwiftData)
  └── insight salvato con promptVersion, fingerprint, lastSeverity, lastIntents
       │
       ▼ [9. UI]
EnvironmentAIDigestCard
  └── carosello di InsightPageView (max 3 insight, ordinati per severità)
```

### 3.2 EnvironmentPreProcessor

Componente **completamente deterministico** (no LLM). Converte letture raw in urgency classificata:

```
Urgency levels:
  normal   → valore nella norma (entro 1.5σ dalla baseline personale)
  warning  → valore elevato/basso (1.5–3σ)
  danger   → valore critico (>3σ o oltre soglie assolute di sicurezza)
```

**Soglie assolute di sicurezza (indipendenti dalla baseline):**
- CO₂ > 1500 ppm → danger
- Umidità > 85% → danger
- Temperatura < 10°C o > 35°C → danger

### 3.3 AmbientalAIInsight (Modello Output)

```swift
struct AmbientalAIInsight {
    let roomName: String
    let message: String              // max 14 parole, in lingua UI
    let severity: InsightSeverity    // info | warning | anomaly
    let nextActions: [AINextAction]  // azioni eseguibili (tap → HomeKit action)
    let intelligenceLevel: IntelligenceLevel
    // observation: singola lettura anomala
    // pattern: trend ricorrente
    // prediction: stato atteso prima che accada
    // recommendation: suggerimento proattivo
    let patternKey: String?          // chiave stabile per dedup semantica
    let whyExplanation: String       // "Perché questo insight?"
    var isDismissed: Bool
}
```

### 3.4 Frequenza e Rate Limiting

- **15 minuti** tra analisi per stanza (throttle in `AmbientalAIService`)
- Fingerprint deduplication elimina chiamate LLM quando stato ambientale non cambia
- Una stanza non viene rielaborata se la sua `RoomAnalysisState.semanticFingerprint` coincide

### 3.5 Intelligence Level Distribution

Il LLM assegna un `intelligenceLevel` all'insight che riflette la "profondità" dell'analisi:

| Livello | Significato | Quando |
|---------|-------------|--------|
| `observation` | Semplice lettura anomala | Singolo sensore fuori range adesso |
| `pattern` | Trend storico riconosciuto | Umidità sempre alta dopo la doccia, da settimane |
| `prediction` | Anomalia attesa prima che accada | "Camera diventerà troppo calda tra 2h" |
| `recommendation` | Suggerimento proattivo | "Apri finestra ora per prevenire accumulo CO₂" |

---

## 4. Componente AI Abitudini

### 4.1 Panoramica Architetturale

Il sistema abitudini è **dual-pipeline**: una pipeline on-device deterministica e una pipeline AI cloud-based che si arricchisce vicendevolmente.

```
Pipeline 1: On-Device (BehavioralAnalysisService)
AccessoryEvent / ActivityEvent (30gg)
        │
        ▼ BehavioralEventPreprocessor
BehavioralEvent[] (normalized, context-enriched)
        │
        ▼ PatternDetectionEngine.detect()
BehavioralPattern[] (with confidence tier)
        │
        ▼ rebuildOpportunities()
AutomationOpportunity[] (quando tier ≥ forming, conf ≥ 0.60, obs ≥ 3)

Pipeline 2: AI Cloud (HabitAnalysisService)
AccessoryEvent / ActivityEvent (14gg)
        │
        ▼ payload JSON (statistiche orarie, frequenza, brightness)
AIService.sendPrompt()
        │
        ▼ JSON parsing + confidence gate (≥ 0.75)
HabitPattern[] (AI-generated, pending user approval)
        │
        ▼ Merge con pattern noti (dedup + confidence update)
HabitPattern[] aggiornati (UserDefaults)
```

### 4.2 PatternDetectionEngine — Algoritmo Dettagliato

**Temporal Pattern Detection:**

```
Per ogni combinazione (accessoryName, action, dayType):
  1. Raccoglie tutti gli eventi del gruppo
  2. Estrae minuteOfDay (0–1439) da ogni evento
  3. Calcola mean e stdDev dei minuti
  4. GATE: stdDev ≤ 60 min (comportamento umano realistico)
     (valore precedente era 25 min — troppo restrittivo)
  5. Classifica dayType:
     - weekday-only: eventi solo in giorni 2-6 (lun-ven)
     - weekend-only: eventi solo in giorni 1,7 (dom-sab)
     - daily: entrambi
  6. Genera BehavioralPattern con observations, stabilityDays, weekdays[]
```

**Sequential Pattern Detection:**

```
Per ogni evento "causa":
  1. Cerca tutti gli eventi "effetto" nei successivi 600 secondi (10 min)
  2. Conta hit rate = occorrenze(B dopo A) / occorrenze(A)
  3. GATE: hitRate ≥ 0.65 E occorrenze ≥ 3
  4. Calcola gap medio causa→effetto
  5. Genera BehavioralPattern di tipo .sequential
```

**Merge Logic:**

```
Nuovi pattern vs pattern esistenti:
  ├── Preserved: dismissed/approved/dormant → mai toccati
  ├── Se deduplicationKey + avgMinuteOfDay coincide (±30 min):
  │     → aggiorna observations, validations, stabilityDays, weekdays
  │     → smooth del avgMinuteOfDay ((vecchio+nuovo)/2)
  │     → re-valuta dormancy:
  │         daysSinceLast ≥ 30 → .dormant
  │         daysSinceLast ≥ 7  → .decaying
  │         altrimenti         → .active
  └── Altrimenti: inserisce come nuovo pattern
```

### 4.3 Confidence Model (BehavioralPattern)

```
confidence = min(0.97, baseRate × stabilityFactor × recencyFactor)

baseRate       = validations / max(1, observations)
stabilityFactor = min(1.0, stabilityDays / 14.0)  // satura a 14 giorni
recencyFactor  = exp(-max(0.0, daysSinceLast - 1.0) / 7.0)  // decade in 7gg
```

**Confidence Tier:**

| Tier | Range | isVisible | Opportunità |
|------|-------|-----------|-------------|
| `.emerging` | < 0.60 | ❌ | No |
| `.forming` | 0.60–0.74 | ✅ | Sì (soglia attuale) |
| `.stable` | 0.75–0.89 | ✅ | Sì |
| `.highConfidence` | 0.90–0.97 | ✅ | Sì |
| `.decaying` | — (nessuna obs da 7gg) | ⚠️ | No (staging) |
| `.dormant` | — (nessuna obs da 30gg) | ❌ | No (stagionale?) |

### 4.4 BehavioralDeviationDetector

Monitora pattern con `confidence ≥ 0.80` (tier stable/highConfidence) e verifica se l'azione attesa è stata eseguita nella finestra temporale.

```
Per ogni pattern .active con confidence ≥ 0.80:
  1. Verifica se ora corrente è dentro [expectedTime ± toleranceMinutes]
  2. Se dentro la finestra → controlla se l'azione è stata osservata di recente
  3. Se NON osservata → incrementa consecutiveMisses
  4. Dopo N miss consecutivi:
     → emette DeviationSignal con priorità escalata
     → ProactiveIntelligenceService crea ProactiveNotification categoria .behavioralAI
```

**Output:** headline tipo "La luce soggiorno non si è accesa alle 22:00 come di solito"

### 4.5 HabitAnalysisService — Integrazione LLM

**Throttle:** 60 minuti tra analisi (se app attiva)

**Payload al LLM (14 giorni):**
- Statistiche orarie per accessorio (quando on/off, durata media sessione)
- Frequenza settimanale per giorno (es. "acceso 5/7 giorni")
- Brightness media per le luci dimmerabili
- Pattern già noti (scafold) per non rigenerare suggerimenti già rilevati
- Scene attivate e frequenza

**Gate post-LLM:**
- `confidence ≥ 0.75` — pattern sotto soglia scartati silenziosamente
- Merge con pattern esistenti: se stesso accessoryID + stessa action → aggiorna confidence, non duplica

**Graceful degradation:** Se AI non configurata (`!aiSettings.isOperational`) → skip call, patterns rimangono invariati da precedente analisi

### 4.6 Ciclo di Vita di un Pattern

```
Rilevamento on-device
    ↓
BehavioralPattern (tier: .forming)
    ↓ [confidence sale con osservazioni accumulate]
BehavioralPattern (tier: .stable, confidence ≥ 0.60, obs ≥ 3)
    ↓ [rebuildOpportunities()]
AutomationOpportunity (status: .pending)
    ↓
UI: behavioralOpportunityRow() in HabitsView
    ↓
[Utente approva]
    ↓
BehavioralAnalysisService.approve() → Rule
    ↓
RuleEngineService.insertRule()
    ↓
Rule (status: active, executionMode: homeKit o inApp)
    ↓ [eseguita]
ActionEffectivenessEvent → EffectivenessSummary
```

### 4.7 Persistenza del Sistema Abitudini

| Dato | Dove | Chiave |
|------|------|--------|
| `[BehavioralPattern]` | UserDefaults | `behavioral.patterns.v1` (o `.v1.{profileID}`) |
| `[AutomationOpportunity]` | UserDefaults | `behavioral.opportunities.v1` (o `.v1.{profileID}`) |
| `[HabitPattern]` | UserDefaults | `habitPatterns.persisted` |
| `Rule` | SwiftData | Modello persistito |

---

## 5. Rule Engine e Opportunità

### 5.1 Rule Engine

`RuleEngineService` gestisce il ciclo di vita completo delle regole:

**Execution Modes:**

| Modalità | Quando | Meccanismo |
|----------|--------|------------|
| `homeKit` | Trigger calendar (ora + giorni settimana) | Delega a HMEventTrigger |
| `inApp` | Trigger characteristic-based o inApp | App valuta ogni ~15 minuti via BGTask |

**Selezione automatica executionMode:**
- Se trigger = `"calendar"` AND HomeKit disponibile → tenta delega `HMEventTrigger`
- Se HomeKit non disponibile o trigger = `"characteristic"` o `"inApp"` → `inApp`

**Sync isEnabled con HomeKit:**
- `toggleRule(_:home:)` chiama `trigger.enable(rule.isEnabled)` su HMEventTrigger
- Previene "ghost automations" HomeKit attive anche quando la regola è disabilitata in-app

**Evaluated Today Guard:**
- Prima di eseguire una regola `inApp`, verifica se è già stata eseguita oggi (via `cal.isDateInToday(lastExecutedAt)`)
- Evita esecuzioni multiple nello stesso giorno per regole daily

### 5.2 Struttura Rule

```swift
Rule (SwiftData @Model)
  ├── triggerType: "calendar" | "characteristic" | "inApp"
  ├── triggerTime: "22:18"              // per calendar
  ├── triggerWeekdays: "1,2,3,4,5,6,7" // serializzati
  ├── triggerCharacteristicID: UUID     // per characteristic-based
  ├── triggerThreshold: Double          // valore soglia
  ├── actionAccessoryID: UUID           // target HomeKit
  ├── actionType: "on" | "off" | "dim" | "open" | "close" | "setMode"
  ├── actionValue: Double?              // es. 0.3 per dim al 30%
  ├── executionMode: "homeKit" | "inApp"
  ├── homeKitTriggerID: UUID?           // se delegato
  └── isEnabled: Bool
```

### 5.3 AutomationOpportunity → Rule

Il metodo `buildRule()` su `AutomationOpportunity` genera automaticamente:
- `triggerType` dal `patternType` del pattern (es. `.temporal` → `"calendar"`)
- `triggerTime` dall'`avgTimeString` del pattern
- `triggerWeekdays` dal `triggerWeekdaysRaw`
- `actionType` dall'`effectActionRaw`
- Tutto il necessario per `RuleEngineService.insertRule()`

---

## 6. Sistema Notifiche Proattive

### 6.1 ProactiveIntelligenceService

**Orchestrator master** di 11+ sorgenti di segnale. Ogni ciclo (min 5 minuti):

| Sorgente | Categoria | Descrizione |
|----------|-----------|-------------|
| Behavioral deviations | `.behavioralAI` | Abitudini saltate |
| Automation opportunities | `.automationOpportunity` | Pattern pronti per regola |
| Environmental alerts | `.environment/.comfort/.hvac` | Anomalie sensori |
| Auto-resolve | — | Chiude alert quando problema risolto |
| Learning milestones | `.learning/.aiDiscovery` | Pattern raggiunge nuovo tier |
| Occupancy prediction | `.presence` | Pre-heat HVAC prima del rientro |
| Arrival automation | `.presence` | Suggerimento automazione al rientro |
| Predictive alerts | `.environment` | Anomalia ambientale attesa |
| Sensor anomalies | `.deviceHealth` | Device con dati stale/oscillanti |
| Maintenance prediction | `.maintenance` | Device con usage anomala |
| Energy anomalies | `.energy` | alwaysOn, anomalousRuntime |
| Weather prediction | `.weather` | Pro-cool/heat per forecast estremo |

### 6.2 IntelligenceScore

Ogni `ProactiveNotification` ha un punteggio 5-dimensionale:

```
composite = 0.25×relevance + 0.25×confidence + 0.20×urgency + 0.20×actionability + 0.10×novelty

Delivery gate: composite ≥ 0.25 per entrare nel feed
```

### 6.3 Deduplication

`semanticKey` è la chiave stabile per evitare notifiche duplicate:
```
"environment|Cucina|humidity"
"behavioral|LivingRoom|on"
"energy|alwaysOn|{accessoryUUID}"
"energy|runtime|{accessoryUUID}"
```

Se una notifica con la stessa `semanticKey` esiste già con status `live/pending`, viene aggiornata (non creata di nuovo).

### 6.4 Ciclo di Vita Notifica

```
pending → live → updated → acknowledged → actedOn
                                        → snoozed (→ pending dopo X giorni)
                                        → dismissed
                                        → resolved
                          expired (> 30 giorni)
```

### 6.5 Feed View

`IntelligenceFeedView` organizza le notifiche in:
- **Sezioni temporali:** Today / Yesterday / This Week / Earlier
- **Filtri per categoria:** All, Active, AI, Environment, Security, Automations, Energy
- **Ogni riga espandibile** con: headline, body, score breakdown, recommendation, azioni (Done/Later/Dismiss/Always On per energy)
- **Legenda azioni** (`ActionLegendSheet`) accessibile via pulsante `?` nelle action buttons

---

## 7. Energy Tracking

### 7.1 Pipeline Energetica

```
AccessoryEvent (SwiftData)
      │
      ▼ EnergyUsageTracker.analyze()
         ├── Fetch eventi ON/OFF ultimi 7 giorni
         ├── Raggruppa per accessoryID
         ├── Costruisce sessioni ON→OFF (con gap filling)
         ├── Riconciliazione real-time HomeKit:
         │     HomeKit ON + storia OFF → sessione sintetica da adesso
         │     HomeKit OFF + storia ON → cappa sessione a max 24h
         └── Calcola totalHoursToday, totalHoursWeek, activeDays
EnergyUsageRecord[] per accessorio
      │
      ▼ EnergyInsightBuilder.build()
         ├── Filtra per energyEventTypes (light, switch, thermostat, fan, airPurifier, outlet)
         │     — esclude: motion, contact, blind, camera
         ├── alwaysOn: currentSessionHours ≥ 3h AND > baseline
         └── anomalousRuntime: todayHours > 2× baseline AND activeDays ≥ 3
EnergySignal[] (alwaysOn / anomalousRuntime)
      │
      ▼ ProactiveIntelligenceService → ProactiveNotification (.energy)
```

### 7.2 Soglie

```
alwaysOn threshold:          3.0 ore sessione continua
anomaly multiplier:          2.0× baseline giornaliero
min baseline hours:          0.5 ore (evita device raramente usati)
min absolute hours today:    1.5 ore
min active days:             3 giorni (evita false positives su device nuovi)
open session cap:            24 ore (sessioni senza OFF cappate)
```

### 7.3 EnergyIgnoreStore

Permette all'utente di escludere permanentemente un device (es. frigo sempre acceso):
- Persiste `Set<UUID>` in UserDefaults
- Filtro applicato sia in `EnergyDashboardCard` che in `EnergyInsightBuilder`

---

## 8. Persistenza Dati

### 8.1 Policy di Retention

| Tipo dato | Retention | Meccanismo |
|-----------|-----------|------------|
| SensorReading (raw) | 30 giorni | DataLifecycleService prune |
| AccessoryEvent (raw) | 30 giorni | DataLifecycleService prune + on-write in AccessoryEventStore |
| ActivityEvent | 30 giorni | DataLifecycleService prune |
| ActionEffectivenessEvent | 90 giorni | DataLifecycleService prune post-aggregazione |
| ProactiveNotification | 30 giorni (se expired/archived) | DataLifecycleService |
| PersistedInsight | 30 giorni | DataLifecycleService |
| Rule | Permanente | Non prunato |
| DailySensorSummary | Permanente | Aggregato da SensorReading raw |
| AccessoryUsageSummary | Permanente | Aggregato da AccessoryEvent raw |

### 8.2 Aggregazione DataLifecycleService

Il ciclo giornaliero (`runFullCycle`) esegue in ordine:
1. Aggrega SensorReading → DailySensorSummary (media, stdDev, min, max per sensore per giorno)
2. Aggrega AccessoryEvent → AccessoryUsageSummary (counts on/off, session length)
3. Aggrega ActionEffectivenessEvent → EffectivenessSummary (tasso successo per intent)
4. Prune raw readings già aggregati
5. Prune PersistedInsight scaduti
6. Prune ProactiveNotification scadute
7. Prune RoomAnalysisState orfani

---

## 9. Theming e Brand Color

Il progetto non ha un sistema di design token centralizzato. I colori sono distribuiti:

- `BrandColor.primary` — definito come `Color` extension (probabilmente in un file non separato)
- Colori categoriali nelle notifiche: mappati in `notificationColor(for:)` in `IntelligenceFeedView.swift`
- Accent color iOS standard per button/highlight

**Nota:** L'assenza di un file di tema dedicato rende difficile il refactoring dei colori. Un cambiamento di brand richiederebbe modifiche in numerosi file.

---

## 10. Punti Critici, Problematiche e Punti Deboli

### 10.1 🔴 CRITICI (possono causare comportamenti errati)

**[C1] Tado X / Valvole termostatiche — Accensione involontaria**
- Le valvole usano `Active` (0xB0) invece di `PowerState` (0x25). Il vecchio codice non le monitorava come energy device, generando sessioni "aperte" senza evento OFF. Con la reconciliazione real-time introdotta, se HomeKit vede le valvole come ON ma il database non ha evento ON recente, genera una sessione sintetica che potrebbe creare notifiche spurie.
- **Rischio:** Falsi alert energetici per le valvole nei primi giorni di dati.

**[C2] HMEventTrigger non sincronizzato con isEnabled**
- Prima del fix (sprint corrente), disabilitare una regola in-app non disabilitava il corrispondente `HMEventTrigger` in HomeKit. HomeKit continuava a eseguire l'automazione indipendentemente dall'app.
- **Status:** Fix applicato in `RuleEngineService.toggleRule(_:home:)`.

**[C3] Schema SwiftData — Migration Failure**
- In caso di migration fallita, l'app cancella l'intero store e ricomincia da zero. L'utente perde tutti gli eventi storici, le regole e le notifiche.
- **Rischio:** Deploy con schema non compatibile = perdita dati permanente per tutti gli utenti.

**[C4] Persistence BehavioralPattern / HabitPattern in UserDefaults**
- Non esiste versioning delle strutture `Codable`. Se un campo viene rinominato o cambiato tipo, il `JSONDecoder` fallisce silenziosamente e i pattern persisted si perdono senza alcun feedback all'utente.
- **Rischio:** Ogni refactoring di `BehavioralPattern` o `HabitPattern` azzera il learning.

---

### 10.2 🟠 PROBLEMATICHE (impattano user experience)

**[P1] Habit Detection — Latenza del feedback**
- L'utente non sa che cosa sta imparando il sistema finché un pattern non raggiunge il tier `.forming`. Con la finestra temporale precedente di 25 minuti, pochissimi pattern venivano mai rilevati. Con 60 minuti (fix attuale), la situazione è migliorata ma ci vogliono comunque ≥3 osservazioni distinte prima di vedere qualsiasi cosa in UI.
- **Attenuante:** Aggiunta sezione "Monitoraggio" in HabitsView che mostra sempre il conteggio pattern per tier.

**[P2] BGProcessingTask non garantiti**
- I background task di iOS si attivano solo quando il device è in carica, connesso a WiFi e non in uso. `BehavioralAnalysisService.analyze()` (chiamato dal lifecycle task giornaliero) potrebbe non girare per giorni se l'utente usa il device in mobilità.
- **Impatto:** Il learning è molto più lento di quanto atteso in scenari di uso mobile.

**[P3] Notifiche energetiche persistenti non rivalutate retroattivamente**
- Le `ProactiveNotification` generate con dati errati (prima del fix reconciliazione HomeKit) rimangono nel feed con i valori sbagliati. L'utente deve dismissarle manualmente o aspettarne la scadenza naturale (30 giorni).

**[P4] AI non operativa = HabitsView inutilizzabile**
- Se l'API key non è configurata o `suggestionsEnabled = false`, `HabitsView` mostra solo un banner "Set up AI" e non espone la pipeline on-device (BehavioralAnalysisService) che non richiede AI. L'utente non può accedere alle opportunità on-device.
- **Soluzione suggerita:** Mostrare sempre Tier 2 (Listening) e Tier 3 (Active) indipendentemente dalla configurazione AI. Tier 1 mostra solo behavioral opportunities (no AI), o messaggio contestuale.

**[P5] EnergyDashboardCard — Refresh solo all'apertura**
- Il card si aggiorna solo via `.task` (una volta all'apertura della schermata Ambiente). Se i dispositivi cambiano stato mentre la view è aperta, i dati non si aggiornano automaticamente.

**[P6] ProactiveNotification — Nessun push notification nativo**
- Tutte le notifiche sono in-app only. Se l'utente non apre l'app, non vede gli alert di energia, sicurezza o anomalie ambientali in tempo reale. `AlertNotificationService` gestisce push solo per soglie ambientali configurate manualmente, non per gli insight AI.

---

### 10.3 🟡 PUNTI DEBOLI (qualità del codice / manutenibilità)

**[D1] HomeIntelligenceDashboardView — File monolitico**
- `HomeIntelligenceDashboardView.swift` è circa 1800 righe. Contiene UI, logica di filtering, computed properties complesse, e strutture helper private. Difficile da mantenere e testare.

**[D2] Nessun sistema di design token**
- Colori, spaziature e font weight sono inline nei file di view. Un rebranding richiederebbe modifiche in decine di file.

**[D3] AmbientalAIService — File monolitico**
- `AmbientalAIService.swift` è circa 993 righe. Contiene: preprocessing, payload building, LLM call, post-processing, persistence, dismissal logic, UI state. Responsabilità troppo concentrate.

**[D4] BehavioralEvent — Non persistito**
- `BehavioralEvent` è ricreato da zero ad ogni chiamata `analyze()`. Su 30 giorni di dati con molti accessori, questa operazione di normalizzazione viene ripetuta ogni ora. Con dataset grandi, potrebbe essere un bottleneck.

**[D5] Pattern deduplication key fragile**
- `BehavioralPattern.deduplicationKey` è basato su `accessoryName` (stringa) + `action` + `dayType`. Se l'utente rinomina un accessorio in HomeKit, tutti i pattern di quel device vengono persi e ricreati da zero alla prossima analisi.

**[D6] Sequential pattern — Stabilità limitata**
- Il `stabilityDays` per i pattern sequenziali è inizializzato a `1` e non viene aggiornato correttamente nel merge (usa `lastObservedAt` = `exEffect.timestamp` fisso al momento della detection, non alla data dell'ultima osservazione). I pattern sequenziali non "invecchiano" correttamente.

**[D7] HomeKitService — Grace period hardcoded**
- Il grace period di 12 secondi per la reachability è hardcoded come costante. In ambienti HomeKit complessi (molti device, reti lente), potrebbe non essere sufficiente, generando falsi "device offline" all'avvio.

**[D8] Nessun test per la pipeline AI principale**
- I test esistenti coprono: `CircularMean`, `BehavioralPattern confidence`, `EnvironmentPreProcessor`. Non esistono test per `PatternDetectionEngine`, `HabitAnalysisService` (mock LLM), `ProactiveIntelligenceService`, `RuleEngineService`. Le regressioni in questi componenti sono rilevabili solo tramite uso manuale.

**[D9] Prompt non localizzato**
- Il system prompt inviato al LLM è in inglese fisso. L'app supporta l'italiano in UI, ma le risposte AI potrebbero essere generate in inglese se il LLM non inferisce la lingua dall'contesto.

**[D10] EnergyUsageTracker — Sessioni aperte con cap 24h**
- Accessori come termostati o purificatori che rimangono ON per più di 24h consecutive vengono cappati artificialmente a 24h. Questo è un workaround corretto per sessioni fantoma, ma potrebbe sottostimare device genuinamente always-on (come un purificatore d'aria che funziona 36h continuative).

---

### 10.4 📋 BACKLOG TECNICO SUGGERITO

| Priorità | Item | Impatto |
|----------|------|---------|
| Alta | Aggiungere versioning JSON per BehavioralPattern/HabitPattern | Evita reset learning su ogni deploy |
| Alta | Mostrare behavioral opportunities indipendentemente dalla configurazione AI | UX: HabitsView funziona senza API key |
| Media | Separare AmbientalAIService in ≥3 file (preprocessing, payload, postprocessing) | Manutenibilità |
| Media | Aggiungere test per PatternDetectionEngine | Regressioni rilevabili automaticamente |
| Media | Design token centralizati (BrandColor, spacing) | Facilita rebranding |
| Media | Refresh EnergyDashboardCard su timer (ogni 5 min) | Dati energetici in tempo reale |
| Bassa | Push notification native per alert AI critici | Engagement utente |
| Bassa | Aggiornare deduplicationKey a include accessoryID invece di accessoryName | Resilienza a rename |

---

*Documento generato automaticamente il 2026-06-11. Non modificare manualmente — potrebbe diventare stale.*
