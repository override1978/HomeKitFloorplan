/**
 * Stato in KV (§13) e politica di scrittura (§14, §15).
 */

import type { Recommendation, Reason } from "./engine";

export const STATE_KEY = "climate:state";

export interface OutdoorReading {
  tempC: number;
  observedAt: string;
  source: string;
}

export interface ZoneState {
  equipmentId: string;
  recommendation: Recommendation;
  heatPumpEconomicallyPreferred: boolean;
  /** Da quando vale questa recommendation. Non si azzera negli heartbeat. */
  since: string;
  estimatedCop: number;
  heatPumpCostPerKwhThermal: number;
  reason: Reason;
}

export interface ClimateState {
  schema: 2;
  computedAt: string;
  outdoor: OutdoorReading;
  economics: {
    gasCostPerKwhThermal: number;
    electricityMarginalPrice: number;
    breakevenCop: number;
    estimatedBreakevenOutdoorTempC: number | null;
  };
  zones: Record<string, ZoneState>;
}

export function isStale(state: ClimateState | null, staleAfterMin: number, now: Date): boolean {
  if (!state) return true;
  const computedAt = Date.parse(state.computedAt);
  if (Number.isNaN(computedAt)) return true;
  return now.getTime() - computedAt > staleAfterMin * 60_000;
}

export function ageMinutes(iso: string, now: Date): number {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return Number.POSITIVE_INFINITY;
  return (now.getTime() - t) / 60_000;
}

/**
 * Si scrive solo se cambia almeno una recommendation, oppure se è trascorso
 * l'heartbeat (§14). L'heartbeat serve a distinguere «stabile da ore» da
 * «l'engine non gira più» (§15).
 */
export function shouldWrite(
  previous: ClimateState | null,
  next: ClimateState,
  heartbeatMin: number,
  now: Date
): boolean {
  if (!previous) return true;

  const previousZones = Object.keys(previous.zones).sort().join(",");
  const nextZones = Object.keys(next.zones).sort().join(",");
  if (previousZones !== nextZones) return true;

  for (const [id, zone] of Object.entries(next.zones)) {
    if (previous.zones[id]?.recommendation !== zone.recommendation) return true;
  }

  return ageMinutes(previous.computedAt, now) > heartbeatMin;
}

/**
 * `since` appartiene alla recommendation, non alla scrittura: sopravvive agli
 * heartbeat e si sposta solo quando la fonte cambia davvero.
 */
export function carrySince(
  previous: ClimateState | null,
  zoneId: string,
  recommendation: Recommendation,
  now: Date
): string {
  const before = previous?.zones[zoneId];
  if (before && before.recommendation === recommendation) return before.since;
  return now.toISOString();
}
