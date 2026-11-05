import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { openDb, toJson } from "../../src/db/db.js";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestClient, TestTown, type Reply } from "../helpers/harness.js";

const MESSAGE = "pi is no longer supported; retire this agent";

// A town an older Town Hall made, with an agent that ran on pi (removed in protocol 1.4). The
// town loads, the agent stays and reads blocked with what to do, its finished work can still be
// accepted, retiring it works as for any agent, and pi is in none of the lists a player chooses
// from or configures.
describe("an agent on a legacy harness (pi)", () => {
  let town: TestTown;
  let c: TestClient;
  let hello: Reply;
  let mira: string;
  let pim: string;
  let partyId: string;
  const review: string[] = [];

  beforeAll(async () => {
    // A town made through the protocol: two agents, two finished tasks, a budget and a party...
    const before = await TestTown.start("legacy-harness");
    const c0 = await before.client();
    mira = await summonAgent(c0, { name: "Mira", workspace: makeRepo(before.work, "app") });
    pim = await summonAgent(c0, { name: "Pim", workspace: makeRepo(before.work, "tools"), tile: { x: 60, y: 52 } });
    for (const title of ["First note", "Second note"]) {
      const { task_id: taskId } = await c0.ok("assign_task", {
        agent_id: pim,
        title,
        prompt: "[fake:basic] Leave a note",
        size: "S",
        courier: { mode: "express" },
      });
      await c0.waitTask(taskId, "awaiting_review");
      review.push(taskId);
    }
    await c0.ok("set_budget", { period: "day", pool_usd: 5, billing: { claude: "subscription", codex: "subscription" }, confirm_raise: true });
    before.ctx.db.tx(() => {
      before.ctx.settings.setState("age", { current: 2, research: null });
      before.ctx.db.run("UPDATE agents SET xp = 150, stats_json = json_set(stats_json, '$.accepted', 2) WHERE id = ?", [mira]);
      before.ctx.agents.recomputeRank(mira);
    });
    partyId = (await c0.ok("form_party", { lead_agent_id: mira, member_ids: [pim] })).party_id;
    await c0.close();
    await before.stop(false);

    // ...then made into what an older Town Hall left behind: Pim ran on pi, and pi has billing,
    // spending this period, a usage window and a usage-limit incident.
    const db = openDb(path.join(before.config.dataDir, "townhall.db"));
    const later = new Date(before.clock.now() + 3_600_000).toISOString();
    db.run("UPDATE agents SET provider = 'pi', model = 'openrouter/deepseek/deepseek-chat' WHERE id = ?", [pim]);
    db.run("UPDATE town_state SET value_json = json_set(value_json, '$.billing.pi', 'api_key') WHERE key = 'budget'");
    db.run("UPDATE budget_periods SET by_provider_json = json_set(by_provider_json, '$.pi', 250000)");
    db.run(
      "INSERT INTO town_state (key, value_json) VALUES ('provider_windows', ?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json",
      [
        toJson([
          { provider: "claude", window: "five_hour", window_minutes: 300, used_percent: 10, resets_at: later },
          { provider: "pi", window: "five_hour", window_minutes: 300, used_percent: 50, resets_at: later },
        ]),
      ],
    );
    db.run(
      "INSERT INTO incidents (id, kind, severity, agent_id, task_id, key, message, opened_at) VALUES ('inc_pi_limit', 'font_dark', 'warn', ?, NULL, 'font_dark:provider:pi', 'pi reached its usage limit', ?)",
      [pim, before.clock.iso()],
    );
    db.close();

    town = await TestTown.start("legacy-harness", { root: before.root, clock: before.clock });
    c = await TestClient.connect(town.port);
    hello = await c.hello(town.token);
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("loads the town and keeps the agent, blocked, with what to do", async () => {
    expect(hello.ok).toBe(true);
    const state = await c.ok("get_state");
    expect(state.agents.find((a: { id: string }) => a.id === pim)).toMatchObject({
      provider: "pi",
      model: "openrouter/deepseek/deepseek-chat",
      lifecycle: "active",
      activity: "blocked",
      blocked_reason: "provider_unsupported",
    });
    expect(state.agents.find((a: { id: string }) => a.id === mira)).toMatchObject({ provider: "claude", activity: "idle", blocked_reason: null });
    // Its finished work waits for review as before; the usage limit pi reached can no longer clear, so it is closed.
    const tasks = state.tasks.filter((t: { id: string }) => review.includes(t.id));
    expect(tasks.map((t: { state: string }) => t.state)).toEqual(["awaiting_review", "awaiting_review"]);
    expect(state.incidents.map((i: { id: string }) => i.id)).not.toContain("inc_pi_limit");
    // It stays on its party's roll, but the lead can no longer hand it work.
    expect(state.parties.find((p: { id: string }) => p.id === partyId).member_ids).toEqual([pim]);
    expect(town.ctx.parties.members(partyId)).toEqual([]);
  });

  it("leaves pi out of every list a player chooses from or configures", async () => {
    expect(Object.keys(hello.payload.sdk_versions).sort()).toEqual(["claude", "codex"]);
    const { providers } = await c.ok("check_providers", {});
    expect(providers.map((p: { id: string }) => p.id)).toEqual(["claude", "codex"]);
    expect((await c.send("list_models", { provider: "pi" })).error?.code).toBe("BAD_REQUEST");
    const summon = await c.send("create_agent", {
      spec: {
        name: "Pia",
        provider: "pi",
        model: "openrouter/deepseek/deepseek-chat",
        role: "artificer",
        workspace: { path: path.join(town.work, "app") },
      },
    });
    expect(summon.error?.code).toBe("BAD_REQUEST");
    const { mana } = await c.ok("get_state");
    expect(Object.keys(mana.by_provider)).toEqual(["claude", "codex"]);
    expect(mana.provider_windows.map((w: { provider: string }) => w.provider)).toEqual(["claude"]);
    expect(town.ctx.mana.config().billing).toEqual({ claude: "subscription", codex: "subscription" });
    // An older client may still send a billing for pi: it is ignored.
    const saved = await c.ok("set_budget", { period: "day", pool_usd: 5, billing: { claude: "api_key", codex: "subscription", pi: "subscription" } });
    expect(Object.keys(saved.mana.by_provider)).toEqual(["claude", "codex"]);
    expect(town.ctx.mana.config().billing).toEqual({ claude: "api_key", codex: "subscription" });
    expect(town.ctx.agents.row(pim).billing).toBe("subscription");
  });

  it("refuses new work and spending for the agent, and keeps its finished work reviewable", async () => {
    const refusals = [
      await c.send("assign_task", { agent_id: pim, title: "Third note", prompt: "[fake:basic] Another", size: "S", courier: { mode: "express" } }),
      await c.send("send_back", { task_id: review[0], feedback: "Once more, please." }),
      await c.send("resume_task", { task_id: review[0] }),
      await c.send("attach_tool", { agent_id: pim, type: "forge", tile: { x: 63, y: 50 } }),
    ];
    for (const r of refusals) expect(r.error).toMatchObject({ code: "INVALID_STATE", message: MESSAGE });
    await c.ok("disband_party", { party_id: partyId });
    const party = await c.send("form_party", { lead_agent_id: mira, member_ids: [pim] });
    expect(party.error).toMatchObject({ code: "INVALID_STATE", message: `Pim: ${MESSAGE}` });
    // Reviewing needs no harness: the work it finished can still be accepted.
    const accepted = await c.ok("accept_result", { task_id: review[1], integrate: "keep_branch" });
    expect(accepted.rewards).not.toBeNull();
    await c.waitTask(review[1], "accepted");
  });

  it("retires the agent like any other, and the town still loads afterwards", async () => {
    await c.ok("retire_agent", { agent_id: pim, when: "now" });
    await c.waitEvent((e) => e.type === "agent_retired" && e.payload.agent_id === pim);
    const retired = (await c.ok("get_state")).agents.find((a: { id: string }) => a.id === pim);
    expect(retired).toMatchObject({ provider: "pi", lifecycle: "retired", activity: "idle", blocked_reason: null });
    await c.close();
    await town.restart();
    c = await town.client();
    const state = await c.ok("get_state");
    expect(state.agents.find((a: { id: string }) => a.id === pim)).toMatchObject({ provider: "pi", lifecycle: "retired" });
    expect(state.agents.find((a: { id: string }) => a.id === mira)).toMatchObject({ lifecycle: "active", activity: "idle", blocked_reason: null });
  });
});
