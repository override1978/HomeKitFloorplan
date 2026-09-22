/**
 * Climate Economics Engine — nucleo deterministico.
 *
 * Questo file non conosce Cloudflare, KV, rete, orologio o configurazione:
 * prende numeri e restituisce numeri. È la controparte TypeScript di
 * `HybridHeatingCalculator` in Swift (§27 della spec), e la parità fra i due
 * si verifica confrontando gli stessi casi di §22.
 *
 * Risponde a «quale fonte di calore costa meno», mai a «cosa deve fare la
 * casa»: temperatura interna, presenza, finestre e setpoint non entrano qui
 * e non entrano nel Worker (§0.2, §32).
 */

// MARK: - Tipi

export interface Prices {
  /** Quota energia gas, €/Smc, al netto delle imposte. */
  pGasQuota: number;
  /** τ_gas — imposte / imponibile. */
  tauGas: number;
  /** kWh per Smc. Coefficiente ARERA, riferito al PCS. */
  kSmcKwh: number;
  /** Rendimento caldaia, riferito al PCS come kSmcKwh. */
  etaBoiler: number;
  /** Quota energia elettrica, €/kWh, al netto delle imposte. */
  pElecQuota: number;
  /** τ_elec. */
  tauElec: number;
}

/** Coppie [temperatura esterna °C, COP]. */
export type CopTable = [number, number][];

export type Recommendation = "heat_pump" | "gas";

export type Reason =
  | "estimated_cop_above_upper_threshold"
  | "estimated_cop_below_lower_threshold"
  | "held_in_hysteresis_band"
  /**
   * Scostamento dalla spec v2. La funzione di §20 restituiva
   * "held_in_hysteresis_band" anche quando il COP è LONTANO dalla banda ma la
   * transizione non serve (già sulla fonte giusta). Siccome `reason` esiste per
   * la diagnostica, quel valore mentiva proprio nei casi estremi.
   */
  | "no_transition_needed"
  | "stale_data_failsafe";

export interface Economics {
  pGasMarg: number;
  gasCostPerKwhThermal: number;
  electricityMarginalPrice: number;
  breakevenCop: number;
}

export class EngineError extends Error {}

// MARK: - Modello economico (§18)

export function computeEconomics(prices: Prices): Economics {
  if (!(prices.kSmcKwh > 0)) {
    throw new EngineError("kSmcKwh deve essere maggiore di zero");
  }
  if (!(prices.etaBoiler > 0)) {
    throw new EngineError("etaBoiler deve essere maggiore di zero");
  }

  const pGasMarg = prices.pGasQuota * (1 + prices.tauGas);
  const gasCostPerKwhThermal = pGasMarg / prices.kSmcKwh / prices.etaBoiler;
  const electricityMarginalPrice = prices.pElecQuota * (1 + prices.tauElec);

  if (!(gasCostPerKwhThermal > 0)) {
    throw new EngineError("gasCostPerKwhThermal non positivo: prezzi gas incoerenti");
  }

  return {
    pGasMarg,
    gasCostPerKwhThermal,
    electricityMarginalPrice,
    breakevenCop: electricityMarginalPrice / gasCostPerKwhThermal,
  };
}

// MARK: - Curva di prestazione (§19)

/**
 * COP interpolato linearmente sulla tabella. Fuori intervallo NON estrapola:
 * appiattisce sull'estremo, perché prolungare la retta sotto −10 °C produce
 * COP che scendono verso zero, cioè numeri che non esistono.
 */
export function estimatedCopAt(table: CopTable, outdoorTempC: number): number {
  const pts = sortedAscending(table);
  const first = pts[0];
  const last = pts[pts.length - 1];

  if (outdoorTempC <= first[0]) return first[1];
  if (outdoorTempC >= last[0]) return last[1];

  for (let i = 1; i < pts.length; i++) {
    const [ta, ca] = pts[i - 1];
    const [tb, cb] = pts[i];
    if (outdoorTempC > tb) continue;
    const span = tb - ta;
    if (span <= 0) return cb;
    return ca + ((outdoorTempC - ta) / span) * (cb - ca);
  }
  return last[1];
}

/**
 * Temperatura alla quale la curva raggiunge `breakevenCop` (§21).
 *
 * `null` quando il pareggio cade fuori dai COP tabulati: non è un errore, è il
 * caso «una delle due fonti conviene sempre». La spec non lo specificava.
 * Valore diagnostico, non usato dalla decisione.
 */
export function breakevenOutdoorTempC(table: CopTable, breakevenCop: number): number | null {
  const pts = sortedAscending(table);

  for (let i = 1; i < pts.length; i++) {
    const [ta, ca] = pts[i - 1];
    const [tb, cb] = pts[i];
    const lower = Math.min(ca, cb);
    const upper = Math.max(ca, cb);
    if (breakevenCop < lower || breakevenCop > upper) continue;
    const span = cb - ca;
    if (span === 0) return ta;
    return ta + ((breakevenCop - ca) / span) * (tb - ta);
  }
  return null;
}

export function heatPumpCostPerKwhThermal(
  electricityMarginalPrice: number,
  estimatedCop: number
): number {
  if (!(estimatedCop > 0)) {
    throw new EngineError("estimatedCop deve essere maggiore di zero");
  }
  return electricityMarginalPrice / estimatedCop;
}

// MARK: - Isteresi economica (§20)

export interface Transition {
  recommendation: Recommendation;
  reason: Reason;
}

/**
 * Stato successivo, data la fonte in uso ora.
 *
 * L'isteresi lavora sul COP e non sulla temperatura: una banda espressa in
 * gradi cambierebbe ampiezza a seconda del tratto di curva in cui si cade.
 *
 * A freddo (KV vuoto) il chiamante passa "gas", coerentemente con il fail-safe
 * di §0.3 — la spec non lo diceva e lasciava `previous` indefinito.
 */
export function nextRecommendation(
  previous: Recommendation,
  estimatedCop: number,
  breakevenCop: number,
  hysteresisCop: number
): Transition {
  const margin = Math.abs(hysteresisCop);
  const upper = breakevenCop + margin;
  const lower = breakevenCop - margin;

  if (previous === "gas") {
    if (estimatedCop >= upper) {
      return { recommendation: "heat_pump", reason: "estimated_cop_above_upper_threshold" };
    }
    return {
      recommendation: "gas",
      reason: estimatedCop < lower ? "no_transition_needed" : "held_in_hysteresis_band",
    };
  }

  if (estimatedCop < lower) {
    return { recommendation: "gas", reason: "estimated_cop_below_lower_threshold" };
  }
  return {
    recommendation: "heat_pump",
    reason: estimatedCop >= upper ? "no_transition_needed" : "held_in_hysteresis_band",
  };
}

// MARK: - Valutazione pura (§9)

export interface EvaluateInput {
  outdoorTempC: number;
  /**
   * Prezzi e curva restano obbligatori QUI: questo modulo non legge nulla e
   * non sa che esista una configurazione. Il completamento dai valori salvati
   * avviene nell'handler HTTP, così il motore rimane puro e confrontabile con
   * la controparte Swift.
   */
  prices: Prices;
  performanceModel: { type: string; copTable: CopTable };
  hysteresisCop?: number;
  /**
   * Scostamento dalla spec v2. Senza `previous` l'endpoint restituiva il
   * confronto CRUDO mentre il cron applica l'isteresi: stessi input, risposte
   * diverse, e il wizard avrebbe mostrato "gas" mentre il sistema live diceva
   * "heat_pump". Passandolo si ottiene anche il ramo isteretico.
   */
  previous?: Recommendation;
}

export interface EvaluateResult {
  schema: 2;
  gasCostPerKwhThermal: number;
  electricityMarginalPrice: number;
  estimatedCop: number;
  heatPumpCostPerKwhThermal: number;
  breakevenCop: number;
  estimatedBreakevenOutdoorTempC: number | null;
  /** Confronto puro, senza isteresi. */
  recommendation: Recommendation;
  heatPumpEconomicallyPreferred: boolean;
  /** Presenti solo se è stato passato `previous`. */
  hysteretic?: Transition;
}

export function evaluate(input: EvaluateInput): EvaluateResult {
  const table = input.performanceModel.copTable;
  if (!Array.isArray(table) || table.length === 0) {
    throw new EngineError("copTable vuota");
  }

  const economics = computeEconomics(input.prices);
  const estimatedCop = estimatedCopAt(table, input.outdoorTempC);
  const hpCost = heatPumpCostPerKwhThermal(economics.electricityMarginalPrice, estimatedCop);
  const preferred = estimatedCop >= economics.breakevenCop;

  const result: EvaluateResult = {
    schema: 2,
    gasCostPerKwhThermal: round(economics.gasCostPerKwhThermal, 4),
    electricityMarginalPrice: round(economics.electricityMarginalPrice, 4),
    estimatedCop: round(estimatedCop, 2),
    heatPumpCostPerKwhThermal: round(hpCost, 4),
    breakevenCop: round(economics.breakevenCop, 2),
    estimatedBreakevenOutdoorTempC: roundOrNull(
      breakevenOutdoorTempC(table, economics.breakevenCop),
      1
    ),
    recommendation: preferred ? "heat_pump" : "gas",
    heatPumpEconomicallyPreferred: preferred,
  };

  if (input.previous) {
    result.hysteretic = nextRecommendation(
      input.previous,
      estimatedCop,
      economics.breakevenCop,
      input.hysteresisCop ?? 0
    );
  }
  return result;
}

// MARK: - Helper

function sortedAscending(table: CopTable): CopTable {
  return [...table].sort((a, b) => a[0] - b[0]);
}

export function round(value: number, decimals: number): number {
  const factor = Math.pow(10, decimals);
  return Math.round(value * factor) / factor;
}

function roundOrNull(value: number | null, decimals: number): number | null {
  return value === null ? null : round(value, decimals);
}
