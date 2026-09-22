import { describe, expect, it } from "vitest";
import { resolveEvaluateInput } from "../src/index";
import type { Env } from "../src/auth";

const storedConfig = {
  schema: 2,
  prices: {
    pGasQuota: 0.677,
    tauGas: 0.2547,
    kSmcKwh: 10.69,
    etaBoiler: 0.9,
    pElecQuota: 0.184363,
    tauElec: 0.2112,
  },
  hysteresisCop: 0.15,
  heartbeatMin: 30,
  staleAfterMin: 60,
  location: { lat: 45.22, lon: 8.02 },
  equipment: {
    split_pt: {
      type: "air_to_air_heat_pump",
      performanceModel: {
        type: "outdoor_temperature_cop_table",
        copTable: [[15, 5.0], [10, 4.3], [5, 3.6], [0, 3.0], [-5, 2.5], [-10, 2.2]],
      },
    },
    split_mansarda: {
      type: "air_to_air_heat_pump",
      performanceModel: {
        type: "outdoor_temperature_cop_table",
        copTable: [[15, 4.6], [10, 4.0], [5, 3.3], [0, 2.8], [-5, 2.3], [-10, 2.0]],
      },
    },
  },
  zones: {
    living: { equipmentId: "split_pt" },
    mansarda: { equipmentId: "split_mansarda" },
  },
};

/** KV finto: registra le letture per poter dimostrare che il caso puro non tocca lo storage. */
function makeEnv(config: unknown = storedConfig) {
  const reads: string[] = [];
  const env = {
    STATE: {
      get: async (key: string) => {
        reads.push(key);
        return key === "climate:config" ? config : null;
      },
    },
  } as unknown as Env;
  return { env, reads };
}

describe("/evaluate — completamento dalla configurazione salvata", () => {
  it("con solo temperatura e zona prende prezzi, curva e isteresi dalla config", async () => {
    const { env } = makeEnv();
    const resolved = await resolveEvaluateInput({ outdoorTempC: -4, zone: "living" }, env);

    expect(resolved.prices.etaBoiler).toBe(0.9);
    expect(resolved.hysteresisCop).toBe(0.15);
    expect(resolved.performanceModel.copTable[0]).toEqual([15, 5.0]);
  });

  it("zone diverse portano curve diverse", async () => {
    const { env } = makeEnv();
    const living = await resolveEvaluateInput({ outdoorTempC: 0, zone: "living" }, env);
    const mansarda = await resolveEvaluateInput({ outdoorTempC: 0, zone: "mansarda" }, env);

    expect(living.performanceModel.copTable).not.toEqual(mansarda.performanceModel.copTable);
  });

  it("`equipmentId` esplicito funziona senza zona", async () => {
    const { env } = makeEnv();
    const resolved = await resolveEvaluateInput(
      { outdoorTempC: 0, equipmentId: "split_mansarda" },
      env
    );
    expect(resolved.performanceModel.copTable[0]).toEqual([15, 4.6]);
  });

  it("con più apparecchiature e nessuna indicazione spiega cosa manca", async () => {
    const { env } = makeEnv();
    await expect(resolveEvaluateInput({ outdoorTempC: 0 }, env)).rejects.toThrow(
      /zone.*equipmentId|equipmentId.*zone/
    );
  });

  it("i valori passati esplicitamente vincono sulla configurazione", async () => {
    const { env } = makeEnv();
    const resolved = await resolveEvaluateInput(
      {
        outdoorTempC: 0,
        zone: "living",
        prices: { ...storedConfig.prices, etaBoiler: 0.94 },
      },
      env
    );
    expect(resolved.prices.etaBoiler).toBe(0.94);
  });

  it("payload completo: resta puro, KV non viene nemmeno letto", async () => {
    const { env, reads } = makeEnv();
    const payload = {
      outdoorTempC: 0,
      prices: storedConfig.prices,
      performanceModel: storedConfig.equipment.split_pt.performanceModel,
    };
    const resolved = await resolveEvaluateInput(payload, env);

    expect(resolved).toBe(payload);
    expect(reads).toHaveLength(0);
  });

  it("senza configurazione salvata dice cosa passare nel corpo", async () => {
    const { env } = makeEnv(null);
    await expect(resolveEvaluateInput({ outdoorTempC: 0 }, env)).rejects.toThrow(
      /prices e performanceModel/
    );
  });
});
