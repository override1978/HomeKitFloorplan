/**
 * Temperatura esterna da Open-Meteo.
 *
 * Nessuna chiave API, nessun account, coordinate già arrotondate a ~1 km dalla
 * validazione della configurazione.
 */

import type { OutdoorReading } from "./state";

const ENDPOINT = "https://api.open-meteo.com/v1/forecast";

export async function fetchOutdoorTemperature(
  lat: number,
  lon: number,
  signal?: AbortSignal
): Promise<OutdoorReading> {
  const url = new URL(ENDPOINT);
  url.searchParams.set("latitude", String(lat));
  url.searchParams.set("longitude", String(lon));
  url.searchParams.set("current", "temperature_2m");
  url.searchParams.set("timezone", "UTC");

  const response = await fetch(url.toString(), { signal });
  if (!response.ok) {
    throw new Error(`open-meteo HTTP ${response.status}`);
  }

  const payload = (await response.json()) as any;
  const tempC = payload?.current?.temperature_2m;
  if (typeof tempC !== "number" || !Number.isFinite(tempC)) {
    throw new Error("open-meteo: temperature_2m assente o non numerica");
  }

  const observed = payload?.current?.time;
  const observedAt = observed ? new Date(`${observed}Z`).toISOString() : new Date().toISOString();

  return { tempC, observedAt, source: "open-meteo" };
}
