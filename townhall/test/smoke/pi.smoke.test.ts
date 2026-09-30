import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { PiAdapter } from "../../src/providers/pi/adapter.js";
import { testDeps } from "../helpers/run-host.js";
import { publish, SMOKE_CAP_MICROS, SMOKE_CONTENT, smokeRun } from "./smoke-helpers.js";

// Opt-in: runs pi on the cheapest model among the providers it has credentials for. Without
// credentials (no API key in the environment and no pi /login) the test reports and skips.
describe.skipIf(process.env.AURELHAVEN_SMOKE_PI !== "1")("smoke: pi", () => {
  it("creates a file through one approval, survives an interrupt, and records a cost", async (ctx) => {
    const adapter = new PiAdapter(testDeps(path.join(os.tmpdir(), "aurelhaven-smoke-data"), process.env));
    const info = await adapter.probe();
    publish("pi-probe", info);
    expect(info.installed).toBe(true);
    if (!info.logged_in) {
      ctx.skip("pi has no provider credentials on this machine");
      return;
    }
    const models = await adapter.listModels();
    const price = (hint: string | undefined) => (hint ? [...hint.matchAll(/\$([\d.]+)/g)].reduce((s, m) => s + Number(m[1]), 0) : Infinity);
    const cheapest = [...models].sort((a, b) => price(a.cost_hint) - price(b.cost_hint))[0]!;
    const report = await smokeRun(adapter, "pi", cheapest.id, info.version);
    publish("pi", report);
    expect(report.firstOutcome).toEqual({ kind: "interrupted" });
    expect(report.secondOutcome.kind).toBe("completed");
    expect(report.fileContent?.trim()).toBe(SMOKE_CONTENT);
    expect(report.costMicros.total).toBeGreaterThan(0);
    expect(report.costMicros.total).toBeLessThanOrEqual(SMOKE_CAP_MICROS);
  });
});
