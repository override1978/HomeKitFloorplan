# Home Floorplan 1.2 (196): materiale per App Store Connect

Rispetto alla 1.1 (build 195, spedita il 3 agosto 2026, tag `baseline-1.1-spedita`).
I limiti di lunghezza di App Store Connect sono indicati accanto a ogni campo.

---

## 1. Screenshot

Generati con `scripts/adatta-screenshot.swift` in
`~/Downloads/Home Floorplan 1.2/App Store/`:

- **iPad 13"**: 2752×2064, orizzontale, senza canale alfa. Bande in alto e in basso
  del colore di sfondo (le catture sono 1,44 e lo slot è 1,33: tagliare ai lati
  avrebbe mangiato la barra superiore).
- **iPhone 6,5"**: 1242×2688, verticale, senza alfa.

Massimo 10 per slot. Le catture sono 15 per iPad e 6 per iPhone.

### iPad: ordine proposto

| # | File | Cosa mostra | Stato |
|---|------|-------------|-------|
| 1 | IMG_1031 | Planimetria con tutti gli accessori e il nastro della giornata | ok |
| 2 | IMG_1036 | Ambiente: salute della casa per stanza | ok (vedi «Close» sotto) |
| 3 | IMG_1037 | Sicurezza: stanze aperte e protette, azione consigliata | ok, ma c'è l'anteprima di una telecamera con l'interno di casa |
| 4 | IMG_1038 | AI: priorità e situazioni attive con azioni | ok (vedi «Close») |
| 5 | IMG_1040 | Vista 3D | ok |
| 6 | IMG_1042 | Vista 3D con il livello Ambiente | ok |
| 7 | IMG_1034 | Gesti fatti a mano: «Possibile scena» | ok |
| 8 | IMG_1033 | Automazione in arrivo: «Stavolta no» | **da rifare**: nelle azioni compare un UUID |
| 9 | IMG_1032 | Filtro per tipo di dispositivo | **da rifare**: bottone in inglese «Turn off all: Prese (5 on)» |
| 10 | IMG_1028 | Schermo di riposo (orologio e meteo) | ok |

Scartate: 1029 e 1030 (passaggi intermedi della 1031), 1035 (nastro chiuso,
doppione), 1039 (menu), **1041 (mostra «Anteprima cielo (debug)», che non esiste
nella build Release)**.

### iPhone

| File | Cosa mostra | Stato |
|------|-------------|-------|
| IMG_2618 | Planimetria con le stanze e l'isola dei tab | ok |
| IMG_2621 | Zoom sulla cucina con gli accessori | ok |
| IMG_2622 | Editor di disegno con la guida | ok |
| IMG_2617 | Home con le planimetrie | da valutare: nome personale della casa («TaTi Home») |
| IMG_2619 | Pannello Controlli | **da rifare**: «1 on of 9», «All · 37» in inglese |
| IMG_2620 | Zoom sul soggiorno | **da rifare**: marker rosso «(rimosso)» sembra un errore |

Su **tutte** le catture iPhone la Dynamic Island mostra un'attività in corso (pillola
verde). Meglio rifarle con l'isola vuota. Nota anche che le iPhone sono in tema scuro
e le iPad in chiaro: va bene, ma se vuoi coerenza fra i due set conviene sceglierne uno.

### Da correggere nel codice prima di rifare le catture

- ✅ Traduzioni: 193 chiavi aggiunte al catalogo in italiano e inglese, tra cui
  «Turn off all», «N on of M», «All», «Close» e «Stavolta no» / «Not this time».
- ⏳ UUID al posto del nome nelle azioni del pannello di un'automazione in arrivo
  (IMG_1033, sezione «AZIONI»).

---

## 2. Novità di questa versione (max 4000)

### Italiano

```
La 1.2 dà alla planimetria il senso del tempo.

• Il nastro della giornata. Sotto la planimetria vedi cosa è già successo e cosa succederà: automazioni, alba e tramonto, eventi del calendario (se lo attivi) e i comandi dati a mano. Tocca un momento per i dettagli, salta una sola volta un'automazione con «Stavolta no», scorri a ieri o ai prossimi giorni.
• La casa segue il sole. Lo sfondo della planimetria cambia durante la giornata e di sera sono le lampade accese a illuminare le stanze. Tieni premuto sul nastro per vedere la casa a un'altra ora.
• Planimetria riprogettata. Quattro schede, Controlli, Ambiente, Sicurezza e AI, con lo stato già scritto sotto il nome. Su iPad i dettagli si aprono in un pannello accanto alla mappa.
• Filtri per tipo di dispositivo, e un tocco per spegnere tutto ciò che hai filtrato.
• Un tocco fa la cosa più probabile: luci e prese si accendono e spengono, tutto il resto apre i controlli.
• Azioni direttamente sulla mappa: suggerimenti AI e antifurto propongono l'azione giusta dove serve.
• Posizionare i dispositivi è guidato, una stanza alla volta.
• Nuova vista 3D della casa, con i livelli Ambiente e Sicurezza.
• iPhone: non serve più girare il telefono. Tocca una stanza per ingrandirla, e controlli e schede stanno in un pannello che tiri su dal basso.
• Nuovo schermo di riposo per l'iPad a parete: orologio e meteo, e di notte si abbassa per non illuminare la stanza.
• Scene ridisegnate.
• Traduzioni italiane e inglesi più complete, e tante correzioni.
```

### English

```
What's new in 1.2

• Your home in 3D. A new 3D view built from your floorplan, with Environment and Security layers.
• A brand-new floorplan. Four tabs, Controls, Environment, Security and AI, with their status right under the name. On iPad, details open in a panel next to the map.
• The day ribbon. Below the floorplan you see what already happened and what's coming: automations, sunrise and sunset, calendar events (if you turn them on) and the commands you gave by hand. Tap a moment for details, skip an automation just once with "Not this time", and scroll back to yesterday or ahead to the next days.
• Your home follows the sun. The floorplan background changes through the day, and in the evening your lights are what light up the rooms. Press and hold the ribbon to see your home at another hour.
• Redesigned for iPhone. No more rotating your phone: tap a room to zoom in, and controls and tabs live in a panel you pull up from the bottom, one-handed.
• A tap does the most likely thing: lights and outlets toggle, everything else opens its controls.
• Filter by device type, and turn off everything you filtered with one tap.
• Actions right on the map: AI suggestions and your alarm offer the right action where it's needed.
• Placing devices is now guided, one room at a time.
• New rest screen for wall-mounted iPads: clock and weather, dimmed at night so it doesn't light up the room.
• Redesigned Scenes.
• More complete Italian and English translations, plus many fixes.
```

---

## 3. Testo promozionale (max 170, si cambia senza review)

### A: elenco diretto

IT (165):
```
Novità 1.2: la casa in 3D, una planimetria tutta nuova e il nastro della giornata con automazioni, sole e calendario. E su iPhone si usa con una mano, senza girarlo.
```

EN (160):
```
New in 1.2: your home in 3D, a brand-new floorplan and the day ribbon with automations, sun and calendar. And on iPhone it works one-handed, no rotating needed.
```

### B: «Tutta nuova!»

IT (163):
```
Tutta nuova! Vista 3D della casa, planimetria riprogettata, nastro della giornata che mostra cosa è successo e cosa accadrà. E su iPhone un'esperienza ridisegnata.
```

EN (149):
```
All new! A 3D view of your home, a redesigned floorplan, and a day ribbon showing what happened and what's next. Plus a redesigned iPhone experience.
```

### C: «cambia tutto» (la più enfatica)

IT (162):
```
La 1.2 cambia tutto: casa in 3D, nuova planimetria che segue la luce del sole, nastro della giornata con le tue automazioni. E iPhone finalmente a misura di mano.
```

EN (153):
```
1.2 changes everything: your home in 3D, a new floorplan that follows the sun, a day ribbon with your automations. And iPhone, finally made for one hand.
```

---

## 4. Descrizione: cosa aggiornare

La bozza in `APP_STORE_METADATA_DRAFT.md` è della 1.0. Nella lista «Key features»:

- **aggiungere**: nastro della giornata (automazioni, sole, calendario); planimetria
  che segue la luce del giorno; vista 3D; schermo di riposo per iPad a parete;
  posizionamento guidato dei dispositivi; iPhone con zoom sulle stanze.
- **togliere o riformulare**: «review smart home habits» e «Environmental dashboard»
  come voce a sé. **Abitudini ed Energia non esistono più nella build Release**
  (commit «Energia e Abitudini restano strumenti di sviluppo»).

Frase proposta da inserire dopo il primo paragrafo:

IT: «Sotto la planimetria, il nastro della giornata mette in fila automazioni, alba e
tramonto, eventi del calendario e i comandi dati a mano: vedi cosa è successo e cosa
sta per succedere, e puoi saltare un'automazione una sola volta.»

EN: "Below the floorplan, the day ribbon lines up automations, sunrise and sunset,
calendar events and the commands you gave by hand: see what happened and what's about
to happen, and skip an automation just once."

Parole chiave (max 100), se vuoi rinfrescarle:
```
homekit,floorplan,smart home,automazioni,planimetria,luci,sensori,scene,3d,dashboard
```

---

## 5. Note per App Review (testo completo, 3874/4000 caratteri)

Sostituisce per intero le note della 1.1. Cosa cambia:
- via la sezione «iPhone deliberately limited»: nella 1.2 l'iPhone crea e modifica le
  planimetrie, e il messaggio «ruota il dispositivo» non c'è più;
- «Stavolta no» spiegato per com'è davvero: disattiva il trigger in HomeKit e lo
  riattiva l'app all'avvio o al ritorno in primo piano;
- calendario, 3D, luce del giorno e schermo di riposo;
- Habits dichiarato rimosso; l'opzione vetro passa da Appearance a Floorplan.

```
Thank you for reviewing Home Floorplan. Some context that may help:

WHAT THE APP IS
Home Floorplan is a HomeKit companion. Users draw the floorplan of their home and see and control their existing Apple Home accessories directly on it (live markers, environment/security overlays). It is designed around iPads used as a wall-mounted home dashboard, and works fully on iPhone too.

NEW IN 1.2
- iPhone is now a full client. Floorplans can be created, drawn and edited on iPhone as well as iPad (the + button on the home screen). The portrait "rotate your device" message of 1.1 is gone: tap a room to zoom in; tabs and controls live in a bottom panel.
- Day ribbon: a timeline below the floorplan with today's HomeKit automations, sunrise/sunset and manual commands. Tap any mark for details.
- "Not this time" (in the panel of an upcoming automation) skips a single run. HomeKit has no native "skip once", so the app disables that automation's trigger and re-enables it 5 minutes after the scheduled time. The re-enable happens when the app launches or returns to the foreground; until then the ribbon shows the run as skipped, and "Turn it back on" restores it immediately. The automation itself is never deleted or edited.
- Calendar (optional, off by default): Settings → Floorplan → Day ribbon → "Events in the day". Only then does the app request calendar access. Events are read on device, never stored by the app, never transmitted and never sent to AI providers.
- 3D view: floorplan menu → "View in 3D". Generated on device from the user's 2D drawing.
- Daylight: the floorplan background follows the sun through the day (on by default).
- Rest screen: after a period of inactivity the app shows a dimmed clock and weather (Apple WeatherKit). Tap to return.

HOMEKIT DEPENDENCY
The app requires an Apple Home with accessories to show its full value. Without one:
- First launch shows onboarding and requests HomeKit permission through the system prompt.
- With no home or accessories configured, the app presents guided empty states — it does not crash or appear broken.
- A demo video showing the full experience on a real home is attached to this submission. Any HomeKit-compatible accessory (including simulated accessories from the HomeKit Accessory Simulator) added to an Apple Home will appear in the app for interactive testing.

OPTIONAL AI FEATURES
AI features (environmental suggestions, assistant) are OFF by default and require both (1) the user's explicit in-app consent and (2) the user's own API key for a third-party provider (e.g. Anthropic or OpenAI), stored in the device Keychain. No key ships with the app and no Home Floorplan server exists. All core floorplan and HomeKit features work fully without AI — reviewers do not need an API key.

DATA & PRIVACY
- Home data is processed on device; detailed history is kept locally for ~30 days.
- Optional multi-device sync uses the user's private iCloud database (CloudKit). The developer runs no server and cannot access user data.
- Weather comes from Apple WeatherKit, with Apple Weather attribution shown in-app. The optional home/away presence feature uses a single on-device geofence; coordinates are never transmitted.
- Calendar events, when enabled, stay on the device.
- Privacy policy: https://gethomefloorplan.app/privacy.html

OTHER NOTES
- There is no account or login, so no demo credentials are provided.
- If the device is not signed into iCloud, first launch briefly checks for existing data (a few seconds) and then continues locally — this is expected behavior.
- An appearance option adopts the iOS 26 glass material across the app's controls and panels. It is off by default and can be enabled under Settings → Floorplan.
- The experimental "Habits (beta)" section mentioned in 1.1 has been removed from this version.

Contact for review questions: hello@gethomefloorplan.app
```

> I percorsi (Settings → Floorplan…) valgono con le modifiche alle Impostazioni del
> 23 settembre. Se la build non le include, diventano Settings → Appearance (vetro) e
> Settings → Calendar (calendario).
>
> Il video demo va rifatto: quello allegato alla 1.1 mostra la vecchia interfaccia.
>
> `NSCameraUsageDescription` resta nell'Info.plist ma la fotocamera si usa solo in
> DEBUG: meglio toglierla. Le note sono già a ~3900 caratteri, e non c'è spazio per
> spiegarla.

Privacy label: il calendario resta sul dispositivo e non viene raccolto, quindi la
scheda «Privacy dell'app» non cambia.

---

## 6. TestFlight: «Cosa testare» (max 4000)

### Italiano

```
Grazie per provare la 1.2! Le novità sono tante: ecco dove guardare.

NASTRO DELLA GIORNATA (sotto la planimetria)
- Le automazioni di oggi sono tutte e all'ora giusta? Ne manca qualcuna, o ce n'è qualcuna di un altro giorno?
- Tocca un'automazione in arrivo e prova «Stavolta no»: deve saltare solo quello scatto e tornare attiva subito dopo. Controlla in Casa di Apple che l'automazione sia ancora lì, intatta.
- Accendi e spegni qualcosa a mano: compare sotto l'asse? Più comandi insieme vengono riconosciuti come «Possibile scena»?
- Scorri a ieri e ai prossimi giorni.
- Impostazioni → Planimetria → Nastro della giornata → «Impegni nella giornata»: attivalo e controlla che gli eventi compaiano.

LUCE DEL GIORNO
- Lo sfondo cambia fra mattina, pomeriggio, sera e notte? Qualcosa diventa illeggibile?
- Tieni premuto sul nastro e trascina: la casa deve cambiare luce con l'ora.

PLANIMETRIA
- Schede Controlli / Ambiente / Sicurezza / AI: lo stato scritto sotto il nome corrisponde a quello che vedi?
- Un tocco su luci e prese le accende e spegne, sugli altri dispositivi apre i controlli. Tieni premuto per la scheda completa.
- Filtro per tipo: «Spegni tutte» deve spegnere solo i dispositivi filtrati.
- Menu ⋯ → «Posiziona dispositivi»: il flusso guidato è chiaro?
- Menu ⋯ → Vedi in 3D.

IPHONE
- Tocca una stanza per ingrandirla, torna indietro con il bottone del piano in alto a sinistra.
- Il pannello in basso si tira su e giù bene? Copre mai qualcosa che ti serve?

IPAD A PARETE
- Lascia l'iPad fermo: parte lo schermo di riposo? Di notte è abbastanza scuro?

Segnalami soprattutto:
- testi in inglese dentro l'app in italiano (o il contrario);
- automazioni che l'app mostra in modo diverso da Casa di Apple;
- blocchi, rallentamenti, uscite improvvise.

Note: Abitudini ed Energia non ci sono più in questa build, di proposito.
```

### English

```
Thanks for testing 1.2! There's a lot new, here's where to look.

DAY RIBBON (below the floorplan)
- Are all of today's automations there, at the right time? Anything missing, or anything from another day?
- Tap an upcoming automation and try "Not this time": it should skip that single run and be active again right after. Check in Apple Home that the automation is still there, unchanged.
- Turn something on or off by hand: does it show up under the axis? Are several commands together recognised as a "Possible scene"?
- Scroll back to yesterday and ahead to the next days.
- Settings → Floorplan → Day ribbon → "Events in the day": turn it on and check your events appear.

DAYLIGHT
- Does the background change through morning, afternoon, evening and night? Does anything become hard to read?
- Press and hold the ribbon and drag: your home should change light with the hour.

FLOORPLAN
- Controls / Environment / Security / AI tabs: does the status under each name match what you see?
- A tap on lights and outlets toggles them, on other devices it opens their controls. Press and hold for the full card.
- Filter by type: "Turn off all" must only turn off the filtered devices.
- ⋯ menu → "Place devices": is the guided flow clear?
- ⋯ menu → View in 3D.

IPHONE
- Tap a room to zoom in, go back with the floor button at the top left.
- Does the bottom panel pull up and down smoothly? Does it ever cover something you need?

WALL-MOUNTED IPAD
- Leave the iPad idle: does the rest screen start? Is it dark enough at night?

Please report especially:
- English text inside the Italian app (or the other way round);
- automations shown differently from Apple Home;
- freezes, slowdowns, crashes.

Note: Habits and Energy are intentionally not in this build.
```

---

## 7. CloudKit: allineare Production (prima di TestFlight)

Container `iCloud.com.override1978.HomeFloorplan`, database privato, sincronizzazione
manuale con `CKSyncEngine` (SwiftData ha `cloudKitDatabase: .none`). Nessuna query,
quindi nessun indice da creare.

Differenza con la 1.1, solo aggiunte:

| Tipo di record | Campo | Tipo CloudKit |
|---|---|---|
| `Floorplan` | `northBearingDegrees` | Double |
| `Floorplan` | `ceilingHeightMetres` | Double |
| `EnergySample` (nuovo) | `id`, `deviceID`, `accessoryUUID`, `accessoryName`, `roomName`, `sourceRaw` | String |
| `EnergySample` | `timestamp` | Date/Time |
| `EnergySample` | `cumulativeKilowattHours`, `activePowerWatts` | Double |

`EnergySample` serve anche se la schermata Energia è solo di debug: la Release legge
l'energia Matter e ne sincronizza i campioni.

1. [CloudKit Console](https://icloud.developer.apple.com) → container → **Schema** →
   ambiente **Development** → Record Types: controlla che `EnergySample` esista e che
   `Floorplan` abbia i due campi. Se mancano, avvia una build Debug su un dispositivo
   collegato a iCloud, apri una planimetria in 3D e aspetta una lettura energia:
   Development crea da solo tipi e campi alla prima scrittura.
2. **Deploy Schema Changes…** → la schermata mostra la differenza con Production.
   Deve contenere **solo** le aggiunte della tabella sopra. Se compare altro
   (per esempio un tipo di prova), fermati: in Production non si cancella niente.
3. Conferma il deploy. Poi, in ambiente **Production**, controlla che i tipi ci siano.

## 8. Archivio e caricamento (Xcode)

1. Schema **HomeFloorplan**, destinazione **Any iOS Device (arm64)**.
2. Product → **Archive** (configurazione Release).
3. Organizer → **Distribute App** → App Store Connect → Upload.
   L'esportazione trasforma da sola `aps-environment` e l'ambiente iCloud in Production.
4. In App Store Connect, quando la build 197 finisce l'elaborazione:
   - TestFlight: incolla «Cosa testare» (sezione 6);
   - versione 1.2: seleziona la build 197, poi screenshot, testo promozionale,
     Novità e note per la revisione (sezioni 1–5);
   - allega il nuovo video demo.
