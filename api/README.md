# gethomefloorplan-api

Primo namespace del service layer di Home Floorplan: `/v1/climate/`.

Il Worker risponde a **«quale fonte di calore costa meno»**, mai a «cosa deve
fare la casa». Non conosce temperatura interna, presenza, finestre, setpoint né
stato dei dispositivi, e non raggiunge mai la LAN: è la casa che chiama lui.

Implementa la spec `home-floorplan-climate-api-v2.md`, con cinque scostamenti
documentati sotto.

## Struttura

| File | Ruolo |
|---|---|
| `src/engine.ts` | Motore economico puro. Nessuna dipendenza da Cloudflare: è la controparte di `HybridHeatingCalculator.swift` |
| `src/config.ts` | Schema e validazione integrale della configurazione |
| `src/state.ts` | Stato KV, politica di scrittura, stale |
| `src/weather.ts` | Temperatura esterna da Open-Meteo |
| `src/auth.ts` | Bearer READ/ADMIN, token bridge in query string |
| `src/index.ts` | Router `/v1/*`, cron con fan-out |
| `test/*.test.ts` | 36 test: §22, §23, scostamenti, validazione, politica KV |

## Requisiti

Node ≥ 20. Su questa macchina: `nvm use 20`.

```bash
npm install
npm test
npm run typecheck
```

## Deploy

```bash
npx wrangler kv namespace create STATE
```

Riporta l'id in `wrangler.toml`, poi i tre segreti:

```bash
npx wrangler secret put CLIMATE_READ_TOKEN
npx wrangler secret put CLIMATE_ADMIN_TOKEN
npx wrangler secret put CLIMATE_BRIDGE_TOKEN
```

```bash
npx wrangler deploy
```

Infine la configurazione, che è l'unico posto dove vivono le coordinate:

```bash
curl -X PUT https://api.gethomefloorplan.app/v1/climate/config \
  -H "Authorization: Bearer $CLIMATE_ADMIN_TOKEN" \
  -H "content-type: application/json" \
  -d @config.json
```

`config.json` non va versionato: contiene la posizione di casa.

## Endpoint

| Metodo | Rotta | Auth |
|---|---|---|
| GET | `/v1/climate/health` | nessuna |
| GET | `/v1/climate/zones` | READ |
| GET | `/v1/climate/zones/:zone` | READ |
| POST | `/v1/climate/evaluate` | READ |
| GET | `/v1/climate/config` | READ |
| PUT | `/v1/climate/config` | ADMIN |
| GET | `/v1/bridge/climate/state/:zone?t=…` | BRIDGE |

## Scostamenti dalla spec v2

Tutti e cinque sono coperti da test e reversibili.

**1. `staleAfterMin` 60 invece di 30 — bug.** Con `heartbeatMin` = 30 e cron a
5 minuti, lo stato diventava stale a T+30 mentre l'heartbeat scriveva a T+35:
cinque minuti di `0` spurio ogni mezz'ora a sistema sano, cioè il compressore
che si spegne e riaccende ogni 30 minuti. La validazione ora **rifiuta** una
configurazione in cui `staleAfterMin` non supera `heartbeatMin` di almeno un
periodo di cron.

**2. `reason: "no_transition_needed"` — diagnostica.** La funzione di §20
rispondeva `held_in_hysteresis_band` anche a COP lontanissimo dalla banda,
quando semplicemente si era già sulla fonte giusta. Siccome `reason` serve al
debug, mentiva proprio nei casi estremi.

**3. Riuso dell'ultima lettura meteo entro `weatherMaxAgeMin` (120 min).** §17.5
non ricicla nulla: con Open-Meteo giù per un'ora si finiva a gas, benché una
temperatura esterna di quaranta minuti prima sia perfettamente utilizzabile.
Oltre la soglia si lascia scadere come da spec.

**4. `/evaluate` accetta `previous` opzionale.** Senza, l'endpoint restituiva il
confronto crudo mentre il cron applica l'isteresi: stessi input, risposte
diverse, e il wizard avrebbe mostrato `gas` mentre il sistema live diceva
`heat_pump`. Il confronto crudo resta il default, così i test di §22 valgono
invariati.

**6. `/evaluate`: `prices` e `performanceModel` sono opzionali.** §9 li imponeva
a ogni chiamata. Va bene per le simulazioni del wizard, ma per la domanda
normale — «cosa decide a −4 °C con i prezzi che ho configurato?» — costringeva
il chiamante a tenersi una copia dei prezzi, che diverge dalla configurazione
appena la si modifica con la PUT. Se mancano si prendono da `climate:config`,
indicando `zone` oppure `equipmentId`. Con il payload completo la chiamata
resta pura come da spec: KV non viene nemmeno letto, e un test lo verifica.

**5. `estimatedBreakevenOutdoorTempC` può essere `null`.** §21 non diceva cosa
fare quando il pareggio cade fuori dai COP tabulati. Non è un errore: è il caso
«una delle due fonti conviene sempre», e restituire un estremo lo spaccerebbe
per una soglia.

Inoltre, §12 chiedeva di valutare «in futuro» coordinate arrotondate: sono
arrotondate a 2 decimali (~1 km) già in validazione. Al meteo serve la cella,
non la casa.

## Parità con l'implementazione Swift

`src/engine.ts` e `HomeFloorplan/Services/HybridHeating/HybridHeatingCalculator.swift`
calcolano le stesse cose e sono verificati sugli stessi numeri di §22
(3,24 / 0,0689 — 2,60 / 0,0859 — 2,44 / 0,0915; pareggio 2,64 a −3,58 °C).
È il fallback locale di §27, e la parità di §34.1 è già verificabile.

## Nota sulla configurazione di riferimento

La spec usa `etaBoiler: 0.94`. Per l'impianto reale — Baxi a contatto pulito,
mandata 60 °C su radiatori — il valore realistico è **0,90**, che sposta la
soglia di pareggio da −3,6 a −4,7 °C. I test di §22 restano su 0,94 perché
verificano la matematica del documento; la configurazione di produzione no.
