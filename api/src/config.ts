/**
 * Configurazione (§10, §11) e sua validazione.
 *
 * Principio di §10: «una configurazione vecchia e valida è preferibile a una
 * nuova configurazione corrotta». Quindi la validazione è integrale e avviene
 * PRIMA di qualunque scrittura: o passa tutta, o non si scrive niente.
 */

import type { CopTable, Prices } from "./engine";
import { round } from "./engine";

export interface Equipment {
  type: string;
  manufacturer?: string;
  model?: string;
  performanceModel: { type: string; copTable: CopTable };
}

export interface Zone {
  equipmentId: string;
}

export interface ClimateConfig {
  schema: 2;
  prices: Prices;
  hysteresisCop: number;
  staleAfterMin: number;
  heartbeatMin: number;
  /** Età massima di una lettura meteo riutilizzabile. Vedi README, scostamento 3. */
  weatherMaxAgeMin: number;
  location: { lat: number; lon: number };
  equipment: Record<string, Equipment>;
  zones: Record<string, Zone>;
}

export const CONFIG_KEY = "climate:config";

/**
 * Default dei parametri temporali.
 *
 * `staleAfterMin` NON è 30 come nella spec v2: con `heartbeatMin` = 30 e cron a
 * 5 minuti, lo stato diventava stale a T+30 mentre l'heartbeat scriveva solo a
 * T+35 — cinque minuti di `0` spurio ogni mezz'ora, a sistema sano, cioè
 * accensioni e spegnimenti del compressore ogni 30 minuti. `staleAfterMin`
 * deve superare `heartbeatMin` più almeno un periodo di cron.
 */
export const DEFAULT_HEARTBEAT_MIN = 30;
export const DEFAULT_STALE_AFTER_MIN = 60;
export const DEFAULT_WEATHER_MAX_AGE_MIN = 120;

export class ConfigError extends Error {}

function requireFiniteNumber(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ConfigError(`${path}: atteso un numero finito`);
  }
  return value;
}

function requirePositive(value: unknown, path: string): number {
  const n = requireFiniteNumber(value, path);
  if (!(n > 0)) throw new ConfigError(`${path}: deve essere maggiore di zero`);
  return n;
}

function requireNonNegative(value: unknown, path: string): number {
  const n = requireFiniteNumber(value, path);
  if (n < 0) throw new ConfigError(`${path}: non può essere negativo`);
  return n;
}

function validateCopTable(raw: unknown, path: string): CopTable {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new ConfigError(`${path}: tabella COP vuota o non valida`);
  }
  const table: CopTable = raw.map((row, index) => {
    if (!Array.isArray(row) || row.length !== 2) {
      throw new ConfigError(`${path}[${index}]: atteso [temperatura, cop]`);
    }
    const t = requireFiniteNumber(row[0], `${path}[${index}][0]`);
    const cop = requirePositive(row[1], `${path}[${index}][1]`);
    return [t, cop];
  });

  const temperatures = new Set(table.map(([t]) => t));
  if (temperatures.size !== table.length) {
    throw new ConfigError(`${path}: temperature duplicate nella tabella COP`);
  }
  return table;
}

/**
 * Coordinate arrotondate a 2 decimali (~1 km) già in validazione, non «in
 * futuro» come diceva §12: al meteo serve la cella, non la casa. Quello che non
 * memorizziamo non può trapelare.
 */
function validateLocation(raw: any, path: string): { lat: number; lon: number } {
  if (!raw || typeof raw !== "object") throw new ConfigError(`${path}: mancante`);
  const lat = requireFiniteNumber(Number(raw.lat), `${path}.lat`);
  const lon = requireFiniteNumber(Number(raw.lon), `${path}.lon`);
  if (lat < -90 || lat > 90) throw new ConfigError(`${path}.lat: fuori intervallo`);
  if (lon < -180 || lon > 180) throw new ConfigError(`${path}.lon: fuori intervallo`);
  return { lat: round(lat, 2), lon: round(lon, 2) };
}

export function validateConfig(raw: any): ClimateConfig {
  if (!raw || typeof raw !== "object") throw new ConfigError("payload non è un oggetto");
  if (raw.schema !== 2) throw new ConfigError("schema: attesa versione 2");

  const p = raw.prices;
  if (!p || typeof p !== "object") throw new ConfigError("prices: mancante");
  const prices: Prices = {
    pGasQuota: requirePositive(p.pGasQuota, "prices.pGasQuota"),
    tauGas: requireNonNegative(p.tauGas, "prices.tauGas"),
    kSmcKwh: requirePositive(p.kSmcKwh, "prices.kSmcKwh"),
    etaBoiler: requirePositive(p.etaBoiler, "prices.etaBoiler"),
    pElecQuota: requirePositive(p.pElecQuota, "prices.pElecQuota"),
    tauElec: requireNonNegative(p.tauElec, "prices.tauElec"),
  };
  if (prices.etaBoiler > 1.2) {
    throw new ConfigError("prices.etaBoiler: valore implausibile (riferirlo al PCS)");
  }

  const equipmentRaw = raw.equipment;
  if (!equipmentRaw || typeof equipmentRaw !== "object" || Array.isArray(equipmentRaw)) {
    throw new ConfigError("equipment: mancante");
  }
  const equipment: Record<string, Equipment> = {};
  for (const [id, value] of Object.entries<any>(equipmentRaw)) {
    if (!value?.performanceModel) {
      throw new ConfigError(`equipment.${id}.performanceModel: mancante`);
    }
    const modelType = value.performanceModel.type;
    if (modelType !== "outdoor_temperature_cop_table") {
      throw new ConfigError(`equipment.${id}.performanceModel.type: "${modelType}" non supportato`);
    }
    equipment[id] = {
      type: String(value.type ?? "air_to_air_heat_pump"),
      manufacturer: value.manufacturer ? String(value.manufacturer) : undefined,
      model: value.model ? String(value.model) : undefined,
      performanceModel: {
        type: modelType,
        copTable: validateCopTable(
          value.performanceModel.copTable,
          `equipment.${id}.performanceModel.copTable`
        ),
      },
    };
  }

  const zonesRaw = raw.zones;
  if (!zonesRaw || typeof zonesRaw !== "object" || Array.isArray(zonesRaw)) {
    throw new ConfigError("zones: mancante");
  }
  const zones: Record<string, Zone> = {};
  for (const [id, value] of Object.entries<any>(zonesRaw)) {
    const equipmentId = String(value?.equipmentId ?? "");
    if (!equipment[equipmentId]) {
      throw new ConfigError(`zones.${id}.equipmentId: "${equipmentId}" non esiste in equipment`);
    }
    zones[id] = { equipmentId };
  }
  if (Object.keys(zones).length === 0) throw new ConfigError("zones: nessuna zona definita");

  const heartbeatMin = raw.heartbeatMin === undefined
    ? DEFAULT_HEARTBEAT_MIN
    : requirePositive(raw.heartbeatMin, "heartbeatMin");
  const staleAfterMin = raw.staleAfterMin === undefined
    ? DEFAULT_STALE_AFTER_MIN
    : requirePositive(raw.staleAfterMin, "staleAfterMin");

  // Il vincolo che mancava alla spec: senza margine il sistema va stale fra un
  // heartbeat e l'altro e il bridge sbatte a 0 a sistema sano.
  if (staleAfterMin <= heartbeatMin + 5) {
    throw new ConfigError(
      `staleAfterMin (${staleAfterMin}) deve superare heartbeatMin (${heartbeatMin}) di almeno un periodo di cron`
    );
  }

  return {
    schema: 2,
    prices,
    hysteresisCop: raw.hysteresisCop === undefined
      ? 0.15
      : requireNonNegative(raw.hysteresisCop, "hysteresisCop"),
    staleAfterMin,
    heartbeatMin,
    weatherMaxAgeMin: raw.weatherMaxAgeMin === undefined
      ? DEFAULT_WEATHER_MAX_AGE_MIN
      : requirePositive(raw.weatherMaxAgeMin, "weatherMaxAgeMin"),
    location: validateLocation(raw.location, "location"),
    equipment,
    zones,
  };
}
