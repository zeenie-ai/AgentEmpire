import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath, srcPath } from "../../src/paths.js";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import { FakeProvider } from "../../src/providers/fake/adapter.js";
import { ScenarioLibrary } from "../../src/providers/fake/scenarios.js";
import { harnessDeps } from "../../src/providers/real.js";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";
import { FIXTURES, writeJson } from "../helpers/run-host.js";

const HOUR = 3600;

describe("provider usage windows in Mana (protocol 1.3)", () => {
  let town: TestTown | null = null;
  let c: TestClient | null = null;

  afterEach(async () => {
    await c?.close();
    await town?.stop();
    town = null;
    c = null;
  });

  it("shows the windows a run reports, keeps them across a restart and drops them once they reset", async () => {
    town = await TestTown.start("windows");
    c = await town.client();
    const agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
    expect((await c.ok("get_state")).mana.provider_windows).toEqual([]);
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Mind the limits",
      prompt: "[fake:rate_limits] Mind the limits",
      size: "S",
      courier: { mode: "express" },
    });
    const update = await c.waitEvent((e) => e.type === "mana_updated" && e.payload.mana.provider_windows.length === 2);
    const now = town.clock.now();
    const windows = update.payload.mana.provider_windows as Array<Record<string, unknown>>;
    expect(windows.map((w) => [w.provider, w.window, w.window_minutes, w.used_percent])).toEqual([
      ["claude", "five_hour", 300, 42.5],
      ["claude", "seven_day", 10_080, 12],
    ]);
    expect(Date.parse(windows[0]!.resets_at as string) - now).toBeGreaterThan(2 * HOUR * 1000 - 60_000);
    await c.waitTask(taskId, "awaiting_review");

    await c.close();
    await town.restart();
    c = await town.client();
    expect((await c.ok("get_state")).mana.provider_windows).toEqual(windows);

    // The five-hour window resets after two hours; the weekly one stays.
    town.clock.advance(2 * HOUR * 1000 + 1000);
    const later = (await c.ok("get_state")).mana.provider_windows as Array<{ window: string }>;
    expect(later.map((w) => w.window)).toEqual(["seven_day"]);
  });

  it("reads Claude Code's rate_limit_event and Codex's account/rateLimits/updated", async () => {
    const env: Record<string, string | undefined> = { ...process.env };
    town = await TestTown.start("windows-real", {
      adapters: ({ root, dataDir }) => {
        Object.assign(env, {
          AURELHAVEN_CLAUDE_BIN: path.join(FIXTURES, "fake-claude.mjs"),
          FAKE_CLAUDE_HOME: path.join(root, "claude-sessions"),
          AURELHAVEN_CODEX_BIN: path.join(FIXTURES, "fake-codex.mjs"),
          FAKE_CODEX_HOME: path.join(root, "codex-threads"),
        });
        const econ = Economy.load(defaultEconomyPath()).data;
        const deps = harnessDeps({ econ, dataDir, pricingPath: defaultPricingPath(), env });
        const fake = new FakeProvider("pi", { library: new ScenarioLibrary(srcPath("providers", "fake", "scenarios")), defaultScenario: "basic", microsPerMana: 10_000 });
        return { claude: new ClaudeCodeAdapter(deps), codex: new CodexCliAdapter(deps), pi: fake };
      },
    });
    c = await town.client();
    const reset = Math.floor(town.clock.now() / 1000) + 3 * HOUR;
    env.FAKE_CLAUDE_SCENARIO = writeJson(town.root, "claude.json", {
      turns: [
        {
          steps: [
            {
              rate_limit: {
                status: "allowed_warning",
                rateLimitType: "five_hour",
                utilization: 0.91,
                resetsAt: reset,
                unifiedWindows: { five_hour: { utilization: 0.91, resetsAt: reset }, seven_day: { utilization: 0.4, resetsAt: reset + 24 * HOUR } },
              },
            },
            { text: "Within limits." },
          ],
        },
      ],
    });
    env.FAKE_CODEX_SCENARIO = writeJson(town.root, "codex.json", {
      turns: [
        {
          steps: [
            {
              rate_limits: {
                limitId: "codex",
                limitName: null,
                primary: { usedPercent: 66, windowDurationMins: 300, resetsAt: reset },
                secondary: { usedPercent: 7.5, windowDurationMins: 10_080, resetsAt: reset + 48 * HOUR },
                credits: null,
                individualLimit: null,
                planType: "plus",
                rateLimitReachedType: null,
              },
            },
            { text: "Within limits." },
          ],
        },
      ],
    });
    for (const [provider, model, x] of [["claude", "haiku", 40], ["codex", "gpt-5.6-luna", 60]] as const) {
      const agentId = await summonAgent(c, { name: `Agent ${provider}`, provider, model, workspace: makeRepo(town.work, `app-${provider}`), tile: { x, y: 52 } });
      const { task_id: taskId } = await c.ok("assign_task", {
        agent_id: agentId,
        title: "Check the limits",
        prompt: "Report how much of your limits is left.",
        size: "S",
        courier: { mode: "express" },
      });
      await c.waitTask(taskId, "awaiting_review", 30_000);
    }
    const windows = (await c.ok("get_state")).mana.provider_windows as Array<Record<string, unknown>>;
    expect(windows.map((w) => [w.provider, w.window, w.window_minutes, w.used_percent])).toEqual([
      ["claude", "five_hour", 300, 91],
      ["claude", "seven_day", 10_080, 40],
      ["codex", "five_hour", 300, 66],
      ["codex", "seven_day", 10_080, 7.5],
    ]);
    expect(windows[2]!.resets_at).toBe(new Date(reset * 1000).toISOString());
  });
});
