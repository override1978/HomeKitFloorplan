/**
 * Autenticazione (§3).
 *
 * READ  → lettura stato e configurazione
 * ADMIN → scrittura configurazione (vale anche come READ)
 * BRIDGE→ solo /v1/bridge/*, in query string, da considerare visibile nei log
 */

export interface Env {
  STATE: KVNamespace;
  CLIMATE_READ_TOKEN: string;
  CLIMATE_ADMIN_TOKEN: string;
  CLIMATE_BRIDGE_TOKEN: string;
}

function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length).trim();
}

/**
 * Confronto a tempo costante: su un token corto un confronto che esce al primo
 * byte diverso è un oracolo, e questi token stanno dietro un dominio pubblico.
 */
function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export function hasReadAccess(request: Request, env: Env): boolean {
  const token = bearer(request);
  if (!token) return false;
  return (
    constantTimeEquals(token, env.CLIMATE_READ_TOKEN) ||
    constantTimeEquals(token, env.CLIMATE_ADMIN_TOKEN)
  );
}

export function hasAdminAccess(request: Request, env: Env): boolean {
  const token = bearer(request);
  if (!token) return false;
  return constantTimeEquals(token, env.CLIMATE_ADMIN_TOKEN);
}

export function hasBridgeAccess(url: URL, env: Env): boolean {
  const token = url.searchParams.get("t");
  if (!token) return false;
  return constantTimeEquals(token, env.CLIMATE_BRIDGE_TOKEN);
}
