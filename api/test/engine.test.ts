import { describe, expect, it } from "vitest";
import {
  breakevenOutdoorTempC,
  computeEconomics,
  estimatedCopAt,
  evaluate,
  heatPumpCostPerKwhThermal,
  nextRecommendation,
  type CopTable,
  type Prices,
} from "../src/engine";
import { validateConfig, ConfigError } from "../src/config";
import { shouldWrite, carrySince, isStale, type ClimateState } from "../src/state";

/** Configurazione di riferimento di §22 — η = 0,94 come nel documento. */
const referencePrices: Prices = {
  pGasQuota: 0.677,
  tauGas: 0.2547,
  kSmcKwh: 10.69,
  etaBoiler: 0.94,
  pElecQuota: 0.184363,
  tauElec: 0.2112,
};

const copTable: CopTable = [
  [15, 5.0],
  [10, 4.3],
  [5, 3.6],
  [0, 3.0],
  [-5, 2.5],
  [-10, 2.2],
];

const COST_TOLERANCE = 0.001;

describe("§22 — test numerici di accettazione", () => {
  const economics = computeEconomics(referencePrices);

  it("gasCostPerKwhThermal ≈ 0.0846", () => {
    expect(Math.abs(economics.gasCostPerKwhThermal - 0.0846)).toBeLessThan(COST_TOLERANCE);
  });

  it("electricityMarginalPrice ≈ 0.2233", () => {
    expect(Math.abs(economics.electricityMarginalPrice - 0.2233)).toBeLessThan(COST_TOLERANCE);
  });

  it("breakevenCop ≈ 2.64", () => {
    expect(Math.abs(economics.breakevenCop - 2.64)).toBeLessThan(0.01);
  });

  it("estimatedBreakevenOutdoorTempC ≈ -3.6 °C", () => {
    const t = breakevenOutdoorTempC(copTable, economics.breakevenCop);
    expect(t).not.toBeNull();
    expect(Math.abs((t as number) - -3.6)).toBeLessThan(0.05);
  });

  it.each([
    { outdoor: 2, cop: 3.24, hpCost: 0.0689, recommendation: "heat_pump" },
    { outdoor: -4, cop: 2.6, hpCost: 0.0859, recommendation: "gas" },
    { outdoor: -6, cop: 2.44, hpCost: 0.0915, recommendation: "gas" },
  ])("$outdoor °C → cop $cop, $hpCost €/kWh, $recommendation", (testCase) => {
    const cop = estimatedCopAt(copTable, testCase.outdoor);
    expect(Math.abs(cop - testCase.cop)).toBeLessThan(0.001);

    const cost = heatPumpCostPerKwhThermal(economics.electricityMarginalPrice, cop);
    expect(Math.abs(cost - testCase.hpCost)).toBeLessThan(COST_TOLERANCE);

    const result = evaluate({
      outdoorTempC: testCase.outdoor,
      prices: referencePrices,
      performanceModel: { type: "outdoor_temperature_cop_table", copTable },
    });
    expect(result.recommendation).toBe(testCase.recommendation);
  });
});

describe("§23 — isteresi", () => {
  const breakeven = 2.64;
  const hysteresis = 0.15; // banda 2,49 – 2,79
  const cop = 2.7;

  it("caso A: previous = gas → resta gas", () => {
    expect(nextRecommendation("gas", cop, breakeven, hysteresis).recommendation).toBe("gas");
  });

  it("caso B: previous = heat_pump → resta heat_pump", () => {
    expect(nextRecommendation("heat_pump", cop, breakeven, hysteresis).recommendation).toBe("heat_pump");
  });

  it("i due casi devono differire, altrimenti l'isteresi non c'è", () => {
    const a = nextRecommendation("gas", cop, breakeven, hysteresis).recommendation;
    const b = nextRecommendation("heat_pump", cop, breakeven, hysteresis).recommendation;
    expect(a).not.toBe(b);
  });

  it("sopra la soglia superiore si passa alla pompa di calore", () => {
    expect(nextRecommendation("gas", 2.8, breakeven, hysteresis)).toEqual({
      recommendation: "heat_pump",
      reason: "estimated_cop_above_upper_threshold",
    });
  });

  it("sotto la soglia inferiore si torna al gas", () => {
    expect(nextRecommendation("heat_pump", 2.4, breakeven, hysteresis)).toEqual({
      recommendation: "gas",
      reason: "estimated_cop_below_lower_threshold",
    });
  });
});

describe("scostamenti dalla spec v2", () => {
  it("`reason` non dichiara la banda quando il COP ne è lontano", () => {
    // Molto sotto la banda, già su gas: nessuna transizione, ma non è
    // «tenuto in banda». Nella spec v2 rispondeva held_in_hysteresis_band.
    expect(nextRecommendation("gas", 1.0, 2.64, 0.15).reason).toBe("no_transition_needed");
    expect(nextRecommendation("heat_pump", 5.0, 2.64, 0.15).reason).toBe("no_transition_needed");
  });

  it("dentro la banda `reason` è held_in_hysteresis_band", () => {
    expect(nextRecommendation("gas", 2.7, 2.64, 0.15).reason).toBe("held_in_hysteresis_band");
    expect(nextRecommendation("heat_pump", 2.6, 2.64, 0.15).reason).toBe("held_in_hysteresis_band");
  });

  it("pareggio fuori tabella → null, non un estremo spacciato per soglia", () => {
    expect(breakevenOutdoorTempC(copTable, 1.5)).toBeNull(); // sotto il COP minimo
    expect(breakevenOutdoorTempC(copTable, 9.0)).toBeNull(); // sopra il massimo
  });

  it("/evaluate con `previous` restituisce anche il ramo isteretico", () => {
    const raw = evaluate({
      outdoorTempC: -4,
      prices: referencePrices,
      performanceModel: { type: "outdoor_temperature_cop_table", copTable },
    });
    expect(raw.recommendation).toBe("gas");
    expect(raw.hysteretic).toBeUndefined();

    const withPrevious = evaluate({
      outdoorTempC: -4,
      prices: referencePrices,
      performanceModel: { type: "outdoor_temperature_cop_table", copTable },
      hysteresisCop: 0.15,
      previous: "heat_pump",
    });
    // Il confronto crudo dice gas, l'isteresi tiene la pompa: è proprio la
    // divergenza che il wizard avrebbe mostrato come un bug.
    expect(withPrevious.recommendation).toBe("gas");
    expect(withPrevious.hysteretic?.recommendation).toBe("heat_pump");
  });
});

describe("curva di prestazione", () => {
  it("fuori intervallo appiattisce, non estrapola", () => {
    expect(estimatedCopAt(copTable, -30)).toBe(2.2);
    expect(estimatedCopAt(copTable, 40)).toBe(5.0);
  });

  it("l'ordine delle righe non conta", () => {
    const shuffled: CopTable = [[0, 3.0], [15, 5.0], [-10, 2.2], [5, 3.6], [-5, 2.5], [10, 4.3]];
    expect(estimatedCopAt(shuffled, 2)).toBeCloseTo(3.24, 6);
  });
});

describe("impianto reale (η = 0,90)", () => {
  it("la soglia scende a circa −4,7 °C", () => {
    const economics = computeEconomics({ ...referencePrices, etaBoiler: 0.9 });
    expect(Math.abs(economics.gasCostPerKwhThermal - 0.0883)).toBeLessThan(COST_TOLERANCE);
    const t = breakevenOutdoorTempC(copTable, economics.breakevenCop);
    expect(Math.abs((t as number) - -4.71)).toBeLessThan(0.05);
  });
});

describe("validazione configurazione (§10)", () => {
  const validConfig = {
    schema: 2,
    prices: referencePrices,
    hysteresisCop: 0.15,
    heartbeatMin: 30,
    staleAfterMin: 60,
    location: { lat: 45.2214567, lon: 8.0154321 },
    equipment: {
      split_pt: {
        type: "air_to_air_heat_pump",
        performanceModel: { type: "outdoor_temperature_cop_table", copTable },
      },
    },
    zones: { living: { equipmentId: "split_pt" } },
  };

  it("accetta una configurazione valida", () => {
    expect(validateConfig(validConfig).zones.living.equipmentId).toBe("split_pt");
  });

  it("arrotonda le coordinate a ~1 km", () => {
    const config = validateConfig(validConfig);
    expect(config.location.lat).toBe(45.22);
    expect(config.location.lon).toBe(8.02);
  });

  it("rifiuta una zona che punta a un equipment inesistente", () => {
    const broken = { ...validConfig, zones: { living: { equipmentId: "fantasma" } } };
    expect(() => validateConfig(broken)).toThrow(ConfigError);
  });

  it("rifiuta staleAfterMin troppo vicino a heartbeatMin (il flapping della spec v2)", () => {
    const broken = { ...validConfig, heartbeatMin: 30, staleAfterMin: 30 };
    expect(() => validateConfig(broken)).toThrow(/staleAfterMin/);
  });

  it("rifiuta η implausibile e coefficienti a zero", () => {
    expect(() => validateConfig({ ...validConfig, prices: { ...referencePrices, etaBoiler: 0 } })).toThrow(ConfigError);
    expect(() => validateConfig({ ...validConfig, prices: { ...referencePrices, etaBoiler: 1.5 } })).toThrow(ConfigError);
    expect(() => validateConfig({ ...validConfig, prices: { ...referencePrices, kSmcKwh: 0 } })).toThrow(ConfigError);
  });
});

describe("politica di scrittura KV (§14) e stale (§15)", () => {
  const base = (computedAt: string, recommendation: "gas" | "heat_pump"): ClimateState => ({
    schema: 2,
    computedAt,
    outdoor: { tempC: 8, observedAt: computedAt, source: "open-meteo" },
    economics: {
      gasCostPerKwhThermal: 0.0883,
      electricityMarginalPrice: 0.2233,
      breakevenCop: 2.53,
      estimatedBreakevenOutdoorTempC: -4.7,
    },
    zones: {
      living: {
        equipmentId: "split_pt",
        recommendation,
        heatPumpEconomicallyPreferred: recommendation === "heat_pump",
        since: computedAt,
        estimatedCop: 4.0,
        heatPumpCostPerKwhThermal: 0.0558,
        reason: "no_transition_needed",
      },
    },
  });

  const now = new Date("2026-09-21T14:00:00Z");

  it("non riscrive se nulla cambia e l'heartbeat non è scaduto", () => {
    const previous = base("2026-09-21T13:50:00Z", "heat_pump");
    expect(shouldWrite(previous, base(now.toISOString(), "heat_pump"), 30, now)).toBe(false);
  });

  it("riscrive quando cambia la recommendation", () => {
    const previous = base("2026-09-21T13:50:00Z", "heat_pump");
    expect(shouldWrite(previous, base(now.toISOString(), "gas"), 30, now)).toBe(true);
  });

  it("riscrive all'heartbeat", () => {
    const previous = base("2026-09-21T13:25:00Z", "heat_pump"); // 35 minuti fa
    expect(shouldWrite(previous, base(now.toISOString(), "heat_pump"), 30, now)).toBe(true);
  });

  it("`since` sopravvive agli heartbeat e si sposta solo al cambio di fonte", () => {
    const previous = base("2026-09-21T13:25:00Z", "heat_pump");
    previous.zones.living.since = "2026-09-21T09:35:00Z";
    expect(carrySince(previous, "living", "heat_pump", now)).toBe("2026-09-21T09:35:00Z");
    expect(carrySince(previous, "living", "gas", now)).toBe(now.toISOString());
  });

  it("con stale 60 e heartbeat 30 non esiste la finestra di flapping della spec v2", () => {
    // Nella spec (stale 30) a T+30 lo stato era già stale mentre l'heartbeat
    // scriveva solo a T+35: cinque minuti di `0` a sistema sano.
    const writtenAt = new Date("2026-09-21T13:30:00Z");
    const state = base(writtenAt.toISOString(), "heat_pump");
    const atMinute = (m: number) => new Date(writtenAt.getTime() + m * 60_000);

    expect(isStale(state, 30, atMinute(31))).toBe(true);   // spec v2: stale, e il bridge dava 0
    expect(isStale(state, 60, atMinute(31))).toBe(false);  // con il default corretto, no
    expect(isStale(state, 60, atMinute(35))).toBe(false);  // l'heartbeat arriva in tempo
    expect(isStale(state, 60, atMinute(61))).toBe(true);   // engine davvero fermo
  });
});
