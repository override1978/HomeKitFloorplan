# P2 v2 — Opportunity multi-condizione (condizioni composte + stanza outdoor)

**Stato**: spec approvata in conversazione, da implementare
**Prerequisiti**: P0 ✅, P1 ✅, P2 ✅
**Obiettivo**: pattern `.contextual` con coppie di condizioni AND (es. "chiudi Tenda Studio quando temp Studio > 27° E temp Balcone > 30°"), convertibili end-to-end in automazioni HomeKit con predicato composto. In più: promozione dei sensori fisici della stanza `outdoorRoomName` a condizioni globali e fix del wart outdoor-WeatherKit.

---

## Fase 0 — CloudKit (procedura aggiornata: il record type non esiste ancora in dev)

Siccome `AutomationOpportunity` non è mai stato salvato, il record type nasce per intero
alla prima save via just-in-time schema (solo in Development). ATTENZIONE: la just-in-time
registra SOLO i campi non-nil al primo save, e production NON fa just-in-time → uno schema
nato monco e deployato farebbe fallire i save futuri (es. il primo `snoozedUntil` reale).

- [x] Card "Schema CloudKit — seed opportunità" nella Intelligence Debug View: crea
      un'opportunità con TUTTI i campi valorizzati (inclusa coppia P2 v2) e la accoda al sync.
- [x] Run in debug su Mac → "Crea seed" → verificato in Console (Development): record type
      `AutomationOpportunity` con 40 campi = 34 custom di `toCKRecord`
      (CKRecordMapper.swift:95) + 6 di sistema. `triggerConditionsRaw` incluso.
- [ ] Deploy Schema Changes to **Production** PRIMA di distribuire qualunque build,
      incluso TestFlight (usa production).
- [ ] "Elimina seed" nella debug view (rimuove anche il record CloudKit).

## Fase 1 — Encoding multi + room-aware (fondazione pura)

`ContextualCorrelationEngine.swift` (ContextualCondition):

- [ ] `ContextualCondition` guadagna `roomName: String` — `""` = stanza dell'effetto (retro-compat) o globale.
- [ ] Nuovo formato signature: `context:<tipo>@<stanza>:<direzione>:<soglia>[+<tipo>@<stanza>:<direzione>:<soglia>]`.
- [ ] **Escaping del nome stanza**: percent-encoding dei caratteri riservati (`@ : +`) — i nomi stanza HomeKit sono liberi e possono contenerli.
- [ ] Parser lista `parseConditions(fromSignature:) -> [ContextualCondition]?` che accetta ANCHE il formato legacy a 3 parti (`context:temperature:above:27.5` → 1 condizione, room "").
- [ ] **Emissione retro-compatibile**: 1 condizione nella stanza dell'effetto → formato legacy identico a oggi. Formato esteso SOLO con 2 condizioni o stanza esplicita diversa.
- [ ] `BehavioralAnalysisService.contextualDecisionKey`: estrae il sensorType **primario** da entrambi i formati → chiave INVARIATA per i pattern mono-condizione esistenti (le decisioni utente sopravvivono all'upgrade). Per i multi: chiave sul solo primario, così una decisione copre le varianti 1↔2 condizioni dello stesso comportamento (anti flip-flop).

Test (ContextualPhaseTests):
- [ ] Round-trip encode/decode nuovo formato (con stanza contenente caratteri riservati).
- [ ] Parse del formato legacy.
- [ ] Invarianza della decision key pre/post upgrade su pattern mono-condizione.

## Fase 2 — AutomationOpportunity (additivo, zero comportamento nuovo)

- [ ] `AutomationOpportunity.triggerConditionsRaw: String?` + parametro nell'init designato (default `nil`).
- [ ] `CKRecordMapper`: mapping del campo in entrambe le direzioni.
- [ ] `SchemaVersionValidator`: NESSUN bump (campo opzionale additivo = lightweight migration, non breaking).
- [ ] `init(from pattern:)` caso `.contextual`: scalari = condizione primaria (come oggi); `triggerConditionsRaw` = lista completa solo se >1 condizione o stanza non-default.
- [ ] `fromConversation`: nuovo parametro opzionale `triggerConditionsRaw` (default nil, nessun call-site rotto).
- [ ] `hasSupportedAutomationTrigger` caso "characteristic": convertibile solo se OGNI condizione (parsate da triggerConditionsRaw se presente, altrimenti scalari) ha `hmCharacteristicType` NON vuoto → chiude il wart outdoor-WeatherKit esistente (CTA su wizard che fallisce sempre).
- [ ] `isAutomationConvertible` (BehavioralAnalysisService:597): stesso criterio.
- [ ] `scheduleSummary`: riepilogo multi-condizione sulla card (primaria + " + N" o lista compatta).

Test:
- [ ] Opportunità da pattern multi: scalari = primaria, raw = lista completa.
- [ ] Pattern WeatherKit-only → NON convertibile (niente CTA).
- [ ] `overlayFields` preserva una chiave sconosciuta al client (simulazione client vecchio).

## Fase 3 — Mapper (proposal multi-condizione)

`AutomationProposalMapper.swift`:

- [ ] `Draft`: lista condizioni secondarie `[(tipo, stanza, direzione, soglia)]`.
- [ ] `proposal(from opportunity:...)`: parse di `triggerConditionsRaw` → draft (nil → comportamento identico a oggi).
- [ ] `proposal(from draft:)` per trigger "characteristic" multi:
  - startEvents = **entrambi** gli attraversamenti (OR di eventi — copre i due ordini di arrivo),
  - conditions = **entrambe** le condizioni via `sensorSelection(role: .condition)`, `conditionJoinMode: .all`,
  - risoluzione per (tipo, stanza) come oggi — **nessun ID HomeKit nell'encoding**, late binding.
- [ ] Condizione secondaria non risolvibile → `limitation` esplicita nel wizard, MAI drop silenzioso (l'utente non deve approvare una cosa diversa dalla card).
- [ ] Verificare che il builder (`HomeKitAutomationsService`) gestisca N start events accessorio + predicato composto (il supporto NSCompoundPredicate esiste già in lettura; confermare in scrittura).
- [ ] (Opzionale) `chatbotProposal`: parametro multi-condizione + estensione del tool `proposeOpportunity` nel dispatcher.

Test:
- [ ] `triggerConditionsRaw = nil` → proposta bit-identica a oggi (anti-regressione).
- [ ] Multi → 2 start events + 2 conditions + joinMode .all.
- [ ] Secondaria non risolvibile → limitation presente, proposta non silenziosamente mono.

## Fase 4 — Correlatore (l'unico pezzo statisticamente delicato)

`ContextualCorrelationEngine.swift`:

- [ ] `detect(...)` riceve `outdoorRoomName: String` (letto da UserDefaults in BehavioralAnalysisService e passato — il motore resta puro).
- [ ] **Promozione stanza outdoor**: le serie fisiche di quella stanza (temperature, humidity, lightSensor) valutate come candidate globali per TUTTI i gruppi. Dedupe quando la stanza dell'effetto È la stanza outdoor (stessa serie, una valutazione sola).
- [ ] **Fisico batte meteo**: con `outdoorRoomName` impostato, escludere i tipi WeatherKit (`outdoorTemperature/outdoorHumidity`) dalla correlazione. Senza, restano come fallback → pattern insight-only (non convertibili, via Fase 2).
- [ ] **Valutazione congiunta a coppie**:
  - baseline appaiata: riallineamento delle due serie su griglia comune a 15 min (bucket del SensorLogger),
  - hitRate/baseRate congiunti sui campioni appaiati,
  - gate: `score_joint ≥ score_migliore_singola + 0.15`, `hitRate ≥ 0.70`, `baseRate_joint` nettamente < `min(baseRate_A, baseRate_B)` (l'AND deve restringere davvero — anti sensori correlati), `observations ≥ 8`, `distinctDays ≥ 6`.
  - la coppia vince sulla singola SOLO se passa tutti i gate; altrimenti si emette la singola come oggi (isteresi anti flip-flop).
- [ ] `naturalLanguageDescription` a due condizioni (it/en) con stanza esplicita per la condizione fuori dalla stanza dell'effetto.
- [ ] `lastOutcomes` esteso con gli esiti delle coppie (per la debug view).
- [ ] Anti-dup P0: invariato (la copertura dell'accessorio effetto basta, le condizioni extra non cambiano il verdetto).

Test (dati sintetici):
- [ ] Coppia genuina (entrambe restringono) → emessa.
- [ ] Coppia di sensori correlati (temp+umidità stessa stanza) → respinta (baseRate_joint non scende).
- [ ] Sotto le osservazioni minime → resta la singola.
- [ ] Dedupe effetto-in-stanza-outdoor.
- [ ] Con outdoorRoomName impostato: serie fisica del balcone spiega un effetto in un'ALTRA stanza → pattern convertibile con stanza esplicita nella signature.

## Chiusura

- [ ] Save di prova in debug (Mac) con campo valorizzato → verifica round-trip in Console dev.
- [ ] Deploy schema in production.
- [ ] Nota release: le card contestuali con condizione solo-meteo perdono la CTA di conversione (era rotta by design — il wizard falliva sempre).

## Note per l'implementazione (trappole note del progetto)

- **`BehavioralPattern` è una `struct` Codable, NON un @Model** — persiste via `PersistedBehavioralPattern`. Nessuna migrazione SwiftData per la signature.
- **L'enum di stato si chiama `BehavioralPatternStatus`** (non `PatternStatus`).
- **Test con TEST_HOST**: `ModelConfiguration` richiede `groupContainer: .none` e `cloudKitDatabase: .none`, altrimenti errore `loadIssueModelContainer`. I test esistenti sono in `HomeFloorplanTests/ContextualPhaseTests.swift` — estenderli, non creare un file parallelo.
- **Matching stanza non uniforme**: il correlatore normalizza con `folding(.diacriticInsensitive, .caseInsensitive)` (`normalizedRoom`), il mapper con `localizedCaseInsensitiveCompare`. Nell'encoding salvare il nome stanza ORIGINALE (serve al mapper), non quello normalizzato.
- **I pattern contestuali sono effimeri**: `removeAll` + ri-derivazione con `UUID()` fresco a ogni run. MAI far dipendere il mapper dal pattern sorgente per il contestuale (per i sequenziali P1 invece è corretto: hanno identità stabile).
- **`ContextualCorrelationEngine` è `@MainActor enum` con stato statico** (`lastOutcomes`) — mantenere lo stile, niente istanze.
- **Non cambiare il formato legacy in scrittura per il caso mono-condizione**: `contextualDecisionKey` e le decisioni utente persistite dipendono dall'estrazione del sensorType dalla signature attuale.
- **`hmCharacteristicType` restituisce `""` (stringa vuota, non nil)** per i tipi outdoor — il check di convertibilità deve testare `.isEmpty`.
- **Verifica del builder (Fase 3, punto sui start events multipli)**: è un'INDAGINE, non un'assunzione — leggere `HomeKitAutomationsService` e confermare che la scrittura di `HMEventTrigger` gestisca N eventi + `NSCompoundPredicate` prima di dipenderci; in caso contrario, fallback: primaria come trigger, secondaria solo condizione.

## Decisioni chiave già prese (non rilitigare)

1. Niente ID HomeKit nell'encoding: late binding per (tipo, stanza) contro le capability live, come oggi.
2. AutomationOpportunity torna **autosufficiente**: il mapper NON dipende dal pattern sorgente per il contestuale (patternID effimero → dangling su snoozed/cross-device).
3. Scalari = condizione primaria per sempre (degradazione elegante per client vecchi).
4. Il formato legacy resta il formato di scrittura per il caso mono-condizione.
