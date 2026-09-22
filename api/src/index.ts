/**
 * `api.gethomefloorplan.app` — router `/v1/*` e Climate Economics Engine.
 *
 * Il Worker pubblica una raccomandazione, non un comando (§0.2). Non conosce
 * temperatura interna, presenza, finestre, setpoint né stato dei dispositivi,
 * e non raggiunge mai la LAN dell'utente (§0.4): è la casa che chiama lui.
 */

import {
  EngineError,
  computeEconomics,
  estimatedCopAt,
  breakevenOutdoorTempC,
  heatPumpCostPerKwhThermal,
  nextRecommendation,
  evaluate,
  round,
  type Recommendation,
} from "./engine";
import {
  CONFIG_KEY,
  ConfigError,
  validateConfig,
  type ClimateConfig,
} from "./config";
import {
  STATE_KEY,
  ageMinutes,
  carrySince,
  isStale,
  shouldWrite,
  type ClimateState,
  type OutdoorReading,
  type ZoneState,
} from "./state";
import { hasAdminAccess, hasBridgeAccess, hasReadAccess, type Env } from "./auth";
import { fetchOutdoorTemperature } from "./weather";

// MARK: - Risposte

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function apiError(code: string, message: string, status: number): Response {
  return json({ error: { code, message } }, status);
}

/** Il bridge risponde testo nudo, e in ogni caso di errore risponde `0` (§7). */
function bridgeBody(value: "0" | "1", status = 200): Response {
  return new Response(value, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
}

// MARK: - Accesso a KV

async function readConfig(env: Env): Promise<ClimateConfig | null> {
  const raw = await env.STATE.get(CONFIG_KEY, "json");
  if (!raw) return null;
  try {
    return validateConfig(raw);
  } catch {
    // Configurazione salvata ma non più valida: meglio nessuna raccomandazione
    // che una raccomandazione calcolata su numeri corrotti.
    return null;
  }
}

async function readState(env: Env): Promise<ClimateState | null> {
  return (await env.STATE.get(STATE_KEY, "json")) as ClimateState | null;
}

// MARK: - Ciclo di calcolo (§17)

export async function runClimateCycle(env: Env, now: Date): Promise<ClimateState | null> {
  const config = await readConfig(env);
  if (!config) return null;

  const previous = await readState(env);

  let outdoor: OutdoorReading;
  try {
    outdoor = await fetchOutdoorTemperature(config.location.lat, config.location.lon);
  } catch {
    // Scostamento dalla spec v2 (§17.5). La spec non ricicla nulla e lascia
    // scadere lo stato: con Open-Meteo giù per un'ora si finisce a gas anche se
    // la temperatura esterna di quaranta minuti fa era perfettamente
    // utilizzabile — fuori cambia un grado in un'ora. Si riusa l'ultima lettura
    // buona entro `weatherMaxAgeMin`, e oltre si lascia scadere come da spec.
    const last = previous?.outdoor;
    if (!last || ageMinutes(last.observedAt, now) > config.weatherMaxAgeMin) return null;
    outdoor = last;
  }

  const economics = computeEconomics(config.prices);
  const zones: Record<string, ZoneState> = {};

  for (const [zoneId, zone] of Object.entries(config.zones)) {
    const equipment = config.equipment[zone.equipmentId];
    const estimatedCop = estimatedCopAt(equipment.performanceModel.copTable, outdoor.tempC);

    // Cold start: `previous` assente ⇒ "gas", coerente con il fail-safe di
    // §0.3. La spec lasciava il valore iniziale indefinito.
    const before: Recommendation = previous?.zones[zoneId]?.recommendation ?? "gas";
    const transition = nextRecommendation(
      before,
      estimatedCop,
      economics.breakevenCop,
      config.hysteresisCop
    );

    zones[zoneId] = {
      equipmentId: zone.equipmentId,
      recommendation: transition.recommendation,
      heatPumpEconomicallyPreferred: transition.recommendation === "heat_pump",
      since: carrySince(previous, zoneId, transition.recommendation, now),
      estimatedCop: round(estimatedCop, 2),
      heatPumpCostPerKwhThermal: round(
        heatPumpCostPerKwhThermal(economics.electricityMarginalPrice, estimatedCop),
        4
      ),
      reason: transition.reason,
    };
  }

  const next: ClimateState = {
    schema: 2,
    computedAt: now.toISOString(),
    outdoor: { ...outdoor, tempC: round(outdoor.tempC, 1) },
    economics: {
      gasCostPerKwhThermal: round(economics.gasCostPerKwhThermal, 4),
      electricityMarginalPrice: round(economics.electricityMarginalPrice, 4),
      breakevenCop: round(economics.breakevenCop, 2),
      estimatedBreakevenOutdoorTempC: (() => {
        const t = breakevenOutdoorTempC(
          Object.values(config.equipment)[0].performanceModel.copTable,
          economics.breakevenCop
        );
        return t === null ? null : round(t, 1);
      })(),
    },
    zones,
  };

  if (shouldWrite(previous, next, config.heartbeatMin, now)) {
    await env.STATE.put(STATE_KEY, JSON.stringify(next));
    return next;
  }
  return previous;
}

// MARK: - Handler

async function handleZones(env: Env, zoneId: string | null, now: Date): Promise<Response> {
  const config = await readConfig(env);
  if (!config) return apiError("config_missing", "Configurazione assente o non valida", 503);

  const state = await readState(env);
  if (!state) return apiError("state_missing", "Nessuno stato calcolato", 503);

  const stale = isStale(state, config.staleAfterMin, now);

  const render = (id: string) => {
    const zone = state.zones[id];
    return {
      schema: 2,
      computedAt: state.computedAt,
      stale,
      zone: id,
      equipmentId: zone.equipmentId,
      // Stale ⇒ fail-safe verso gas, come il bridge (§0.3, §15).
      recommendation: stale ? "gas" : zone.recommendation,
      heatPumpEconomicallyPreferred: stale ? false : zone.heatPumpEconomicallyPreferred,
      since: zone.since,
      reason: stale ? "stale_data_failsafe" : zone.reason,
      outdoor: state.outdoor,
      economics: {
        estimatedCop: zone.estimatedCop,
        heatPumpCostPerKwhThermal: zone.heatPumpCostPerKwhThermal,
        gasCostPerKwhThermal: state.economics.gasCostPerKwhThermal,
        breakevenCop: state.economics.breakevenCop,
        estimatedBreakevenOutdoorTempC: state.economics.estimatedBreakevenOutdoorTempC,
      },
    };
  };

  if (zoneId === null) {
    return json({
      schema: 2,
      computedAt: state.computedAt,
      stale,
      zones: Object.keys(state.zones).map(render),
    });
  }
  if (!state.zones[zoneId]) {
    return apiError("zone_not_found", `Zona "${zoneId}" sconosciuta`, 404);
  }
  return json(render(zoneId));
}

async function handleBridge(env: Env, url: URL, zoneId: string, now: Date): Promise<Response> {
  if (!hasBridgeAccess(url, env)) return bridgeBody("0", 401);

  const config = await readConfig(env);
  if (!config) return bridgeBody("0", 200);

  const state = await readState(env);
  if (!state) return bridgeBody("0", 200);
  if (!state.zones[zoneId]) return bridgeBody("0", 404);
  if (isStale(state, config.staleAfterMin, now)) return bridgeBody("0", 200);

  return bridgeBody(state.zones[zoneId].heatPumpEconomicallyPreferred ? "1" : "0");
}

/**
 * Completa l'input di /evaluate con la configurazione salvata.
 *
 * Scostamento dalla spec v2 (§9), che imponeva di ripassare prezzi e curva a
 * ogni chiamata. Va bene per le simulazioni del wizard — «e se il gas costasse
 * 0,72?» — ma per la domanda normale («cosa decide a −4 °C con i MIEI prezzi?»)
 * obbligava il chiamante a tenersi una copia dei prezzi, che diverge dalla
 * configurazione appena la si modifica con la PUT.
 *
 * Con tutti i campi presenti la chiamata resta pura come da spec: KV non viene
 * nemmeno letto.
 */
export async function resolveEvaluateInput(payload: any, env: Env): Promise<any> {
  const needsPrices = !payload?.prices;
  const needsModel = !payload?.performanceModel;
  const needsHysteresis = payload?.hysteresisCop === undefined && payload?.previous !== undefined;
  if (!needsPrices && !needsModel && !needsHysteresis) return payload;

  const config = await readConfig(env);
  if (!config) {
    throw new EngineError(
      "Nessuna configurazione salvata: passa prices e performanceModel nel corpo della richiesta"
    );
  }

  let performanceModel = payload?.performanceModel;
  if (needsModel) {
    const equipmentIds = Object.keys(config.equipment);
    const equipmentId =
      payload?.equipmentId ??
      (payload?.zone ? config.zones[payload.zone]?.equipmentId : undefined) ??
      (equipmentIds.length === 1 ? equipmentIds[0] : undefined);

    if (!equipmentId || !config.equipment[equipmentId]) {
      throw new EngineError(
        `Indica "zone" o "equipmentId": la configurazione contiene ${equipmentIds.length} apparecchiature (${equipmentIds.join(", ")})`
      );
    }
    performanceModel = config.equipment[equipmentId].performanceModel;
  }

  return {
    ...payload,
    prices: payload?.prices ?? config.prices,
    performanceModel,
    hysteresisCop: payload?.hysteresisCop ?? config.hysteresisCop,
  };
}

async function handleEvaluate(request: Request, env: Env): Promise<Response> {
  let payload: any;
  try {
    payload = await request.json();
  } catch {
    return apiError("invalid_json", "Corpo della richiesta non è JSON valido", 400);
  }
  try {
    return json(evaluate(await resolveEvaluateInput(payload, env)));
  } catch (error) {
    if (error instanceof EngineError) {
      return apiError("invalid_input", error.message, 400);
    }
    return apiError("invalid_input", "Payload non valido", 400);
  }
}

async function handleConfigPut(request: Request, env: Env): Promise<Response> {
  let payload: any;
  try {
    payload = await request.json();
  } catch {
    return apiError("invalid_json", "Corpo della richiesta non è JSON valido", 400);
  }
  try {
    const config = validateConfig(payload);
    await env.STATE.put(CONFIG_KEY, JSON.stringify(config));
    return json({ schema: 2, ok: true, config });
  } catch (error) {
    if (error instanceof ConfigError) {
      // Niente scrittura: la vecchia configurazione valida resta al suo posto.
      return apiError("invalid_config", error.message, 400);
    }
    throw error;
  }
}

// MARK: - Worker

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "");
    const now = new Date();

    // Bridge: namespace separato, token in query string, sempre `0` in errore.
    const bridgeMatch = path.match(/^\/v1\/bridge\/climate\/state\/([^/]+)$/);
    if (bridgeMatch) {
      if (request.method !== "GET") return bridgeBody("0", 405);
      return handleBridge(env, url, decodeURIComponent(bridgeMatch[1]), now);
    }

    if (path === "/v1/climate/health") {
      const state = await readState(env);
      const config = await readConfig(env);
      const staleAfterMin = config?.staleAfterMin ?? 60;
      return json({
        ok: true,
        schema: 2,
        lastCronAt: state?.computedAt ?? null,
        stale: isStale(state, staleAfterMin, now),
      });
    }

    if (path === "/v1/climate/evaluate") {
      if (request.method !== "POST") return apiError("method_not_allowed", "Usa POST", 405);
      if (!hasReadAccess(request, env)) return apiError("unauthorized", "Token mancante o non valido", 401);
      return handleEvaluate(request, env);
    }

    if (path === "/v1/climate/config") {
      if (request.method === "GET") {
        if (!hasReadAccess(request, env)) return apiError("unauthorized", "Token mancante o non valido", 401);
        const config = await readConfig(env);
        if (!config) return apiError("config_missing", "Configurazione assente o non valida", 404);
        return json(config);
      }
      if (request.method === "PUT") {
        if (!hasAdminAccess(request, env)) return apiError("unauthorized", "Token amministrativo richiesto", 401);
        return handleConfigPut(request, env);
      }
      return apiError("method_not_allowed", "Usa GET o PUT", 405);
    }

    const zoneMatch = path.match(/^\/v1\/climate\/zones(?:\/([^/]+))?$/);
    if (zoneMatch) {
      if (request.method !== "GET") return apiError("method_not_allowed", "Usa GET", 405);
      if (!hasReadAccess(request, env)) return apiError("unauthorized", "Token mancante o non valido", 401);
      return handleZones(env, zoneMatch[1] ? decodeURIComponent(zoneMatch[1]) : null, now);
    }

    return apiError("not_found", `Nessuna rotta per ${path}`, 404);
  },

  /** Un solo cron con fan-out interno (§16): oggi climate, domani energy e insights. */
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runClimateCycle(env, new Date()).then(() => undefined));
  },
};
