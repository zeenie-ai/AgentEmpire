import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import { testDeps } from "../helpers/run-host.js";
import { publish, SMOKE_CAP_MICROS, SMOKE_CONTENT, smokeRun } from "./smoke-helpers.js";

// Opt-in: runs the installed Codex CLI on the cheapest model model/list offers (a real model call,
// capped at $0.10 of API-equivalent usage).
describe.skipIf(process.env.AURELHAVEN_SMOKE_CODEX !== "1")("smoke: Codex CLI", () => {
  it("creates a file through one approval, survives an interrupt, and records a cost", async () => {
    const deps = testDeps(path.join(os.tmpdir(), "aurelhaven-smoke-data"), process.env);
    const adapter = new CodexCliAdapter(deps);
    const info = await adapter.probe();
    expect(info).toMatchObject({ installed: true, logged_in: true });
    const offered = (await adapter.listModels()).map((m) => m.id);
    const cheapest = deps.pricing.models("codex").find((id) => offered.includes(id));
    expect(cheapest, `no priced model among ${offered.join(", ")}`).toBeTruthy();
    const report = await smokeRun(adapter, "codex", cheapest!, info.version);
    publish("codex", { offered, ...report });
    expect(report.firstOutcome).toEqual({ kind: "interrupted" });
    expect(report.secondOutcome.kind).toBe("completed");
    expect(report.fileContent?.trim()).toBe(SMOKE_CONTENT);
    expect(report.approvals.some((a) => a.run === 2 && a.category === "write")).toBe(true);
    expect(report.costMicros.total).toBeGreaterThan(0);
    expect(report.costMicros.total).toBeLessThanOrEqual(SMOKE_CAP_MICROS);
    expect(report.sessionIds[0]).toBe(report.sessionIds[1]);
  });
});
