import path from "node:path";
import os from "node:os";
import { describe, expect, it } from "vitest";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import { testDeps } from "../helpers/run-host.js";
import { publish, SMOKE_CAP_MICROS, SMOKE_CONTENT, smokeRun } from "./smoke-helpers.js";

// Opt-in: runs the installed Claude Code on Haiku 4.5 (a real, paid model call, capped at $0.10).
describe.skipIf(process.env.AURELHAVEN_SMOKE_CLAUDE !== "1")("smoke: Claude Code", () => {
  it("creates a file through one approval, survives an interrupt, and records a cost", async () => {
    const adapter = new ClaudeCodeAdapter(testDeps(path.join(os.tmpdir(), "aurelhaven-smoke-data"), process.env));
    const info = await adapter.probe();
    expect(info).toMatchObject({ installed: true, logged_in: true });
    const report = await smokeRun(adapter, "claude", "haiku", info.version);
    publish("claude", report);
    expect(report.firstOutcome).toEqual({ kind: "interrupted" });
    expect(report.secondOutcome.kind).toBe("completed");
    expect(report.fileContent?.trim()).toBe(SMOKE_CONTENT);
    expect(report.approvals.some((a) => a.run === 2 && a.category === "write")).toBe(true);
    expect(report.costMicros.total).toBeGreaterThan(0);
    expect(report.costMicros.total).toBeLessThanOrEqual(SMOKE_CAP_MICROS);
    expect(report.sessionIds[0]).toBe(report.sessionIds[1]);
  });
});
