import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("economy rules through the protocol", () => {
  let town: TestTown;
  let c: TestClient;
  let repo: string;

  beforeAll(async () => {
    town = await TestTown.start("rules");
    c = await town.client();
    repo = makeRepo(town.work, "app");
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("spends with a balance check, refunds once and never more than the spend", async () => {
    const t1 = await c.ok("spend_resources", { op_id: "s1", reason: "townsfolk", cost: { food: 50 } });
    expect(t1.treasury.food).toBe(150);
    const poor = await c.send("spend_resources", { op_id: "s2", reason: "cottage", cost: { wood: 5000 } });
    expect(poor.error?.code).toBe("INSUFFICIENT_RESOURCES");
    const refund = await c.ok("refund_resources", { op_id: "r1", spend_op_id: "s1", fraction: 0.5 });
    expect(refund.treasury.food).toBe(175);
    const twice = await c.send("refund_resources", { op_id: "r2", spend_op_id: "s1", fraction: 0.5 });
    expect(twice.error?.code).toBe("CONFLICT");
    const unknown = await c.send("refund_resources", { op_id: "r3", spend_op_id: "nope", fraction: 1 });
    expect(unknown.error?.code).toBe("NOT_FOUND");
    const tooMuch = await c.send("refund_resources", { op_id: "r4", spend_op_id: "s1", fraction: 1.5 });
    expect(tooMuch.error?.code).toBe("BAD_REQUEST");
    const replayed = await c.ok("spend_resources", { op_id: "s1", reason: "townsfolk", cost: { food: 50 } });
    expect(replayed.treasury.food).toBe(175);
  });

  it("caps gathering by age and storehouses, but not rewards", async () => {
    const cap = town.ctx.econ.storageCap(1, 0);
    const g = await c.ok("report_gather", { op_id: "g1", deposits: { food: 5000, wood: 10 }, storehouses: 0 });
    expect(g.treasury.food).toBe(cap);
    const g2 = await c.ok("report_gather", { op_id: "g2", deposits: { food: 5000 }, storehouses: 1 });
    expect(g2.treasury.food).toBe(town.ctx.econ.storageCap(1, 1));
    town.ctx.treasury.credit({ food: 500, wood: 0, stone: 0, gold: 0 }, "reward", "reward", null, "test-reward");
    const over = town.ctx.treasury.balance().food;
    expect(over).toBeGreaterThan(town.ctx.econ.storageCap(1, 1));
    const g3 = await c.ok("report_gather", { op_id: "g3", deposits: { food: 100 }, storehouses: 1 });
    expect(g3.treasury.food).toBe(over);
  });

  it("trades at the Quartermaster at a rate that worsens and recovers", async () => {
    const before = town.ctx.treasury.balance();
    const t1 = await c.ok("trade", { op_id: "q1", give: { resource: "food", amount: 100 }, get: "gold" });
    expect(t1.treasury.gold).toBe(before.gold + 25);
    expect(t1.rate).toBeCloseTo(0.95, 5);
    const t2 = await c.ok("trade", { op_id: "q2", give: { resource: "food", amount: 100 }, get: "gold" });
    expect(t2.treasury.gold).toBe(before.gold + 25 + 23);
    // The penalty recovers in real time between the two trades, so allow a little drift under load.
    expect(t2.rate).toBeCloseTo(0.9, 3);
    town.clock.advance(5 * 60_000);
    expect(town.ctx.treasury.marketRate()).toBeCloseTo(0.95, 3);
    const precious = await c.ok("trade", { op_id: "q3", give: { resource: "gold", amount: 25 }, get: "wood" });
    expect(precious.treasury.wood).toBe(t2.treasury.wood + 47);
    const bad = await c.send("trade", { op_id: "q4", give: { resource: "food", amount: 100 }, get: "wood" });
    expect(bad.error?.code).toBe("BAD_REQUEST");
  });

  it("checks role age, approval-mode age and rank, provider limits and the agent limit", async () => {
    const base = {
      name: "Test",
      provider: "claude",
      model: "fake-claude",
      role: "artificer",
      instructions: "",
      approval_mode: "trusted_edits",
      workspace: { path: repo },
      starting_tools: [],
    };
    expect((await c.send("create_agent", { spec: { ...base, role: "warden" } })).error?.code).toBe("AGE_REQUIRED");
    expect((await c.send("create_agent", { spec: { ...base, approval_mode: "free_hand" } })).error?.code).toBe("AGE_REQUIRED");
    expect((await c.send("create_agent", { spec: { ...base, provider: "codex", approval_mode: "plan_first" } })).error?.code).toBe(
      "BAD_REQUEST",
    );

    const first = await c.ok("create_agent", { spec: base });
    expect(first.free).toBe(true);
    const second = await c.ok("create_agent", { spec: { ...base, name: "Second" } });
    expect(second.free).toBe(false);
    // 20% more for each existing agent: 120 food * 1.2, 60 gold * 1.2.
    expect(second.cost).toEqual({ food: 144, wood: 0, stone: 0, gold: 72 });
    const third = await c.send("create_agent", { spec: { ...base, name: "Third" } });
    expect(third.error?.code).toBe("LIMIT_REACHED");

    // Cancelling training refunds in full.
    const treasury = town.ctx.treasury.balance();
    await c.ok("retire_agent", { agent_id: second.agent_id, when: "now" });
    await c.waitEvent((e) => e.type === "agent_retired" && e.payload.agent_id === second.agent_id);
    expect(town.ctx.treasury.balance().food).toBe(treasury.food + 144);
    await c.ok("retire_agent", { agent_id: first.agent_id, when: "now" });
  });

  it("enforces tool ages, slots, prerequisites and the dismantle refund", async () => {
    const agentId = await summonAgent(c, { name: "Smith", workspace: repo, tools: ["lectern", "quillworks"] });
    const noLectern = await c.ok("create_agent", {
      spec: {
        name: "Bare",
        provider: "claude",
        model: "fake-claude",
        role: "scribe",
        instructions: "",
        approval_mode: "trusted_edits",
        workspace: { path: repo },
        starting_tools: [],
      },
    });
    await c.ok("agent_trained", { agent_id: noLectern.agent_id });
    await c.ok("place_home", { agent_id: noLectern.agent_id, tile: { x: 70, y: 70 } });
    const prereq = await c.send("attach_tool", { agent_id: noLectern.agent_id, type: "quillworks", tile: { x: 71, y: 70 } });
    expect(prereq.error?.code).toBe("INVALID_STATE");
    await c.ok("retire_agent", { agent_id: noLectern.agent_id, when: "now" });

    const waygate = await c.send("attach_tool", {
      agent_id: agentId,
      type: "waygate",
      tile: { x: 45, y: 50 },
      config: { server_name: "github", transport: "stdio", command: "npx" },
    });
    expect(waygate.error?.code).toBe("AGE_REQUIRED");
    const dup = await c.send("attach_tool", { agent_id: agentId, type: "lectern", tile: { x: 45, y: 50 } });
    expect(dup.error?.code).toBe("CONFLICT");

    town.ctx.treasury.credit({ food: 0, wood: 500, stone: 500, gold: 500 }, "reward", "reward", null, "test-tools");
    const forge = await c.ok("attach_tool", { agent_id: agentId, type: "forge", tile: { x: 45, y: 50 } });
    await c.ok("attach_tool", { agent_id: agentId, type: "archive", tile: { x: 46, y: 50 } });
    const slots = await c.send("attach_tool", { agent_id: agentId, type: "rookery", tile: { x: 47, y: 50 } });
    expect(slots.error?.code).toBe("LIMIT_REACHED");
    const lecternId = (await c.ok("get_state")).agents.find((a: { id: string }) => a.id === agentId).tool_ids[0];
    const needed = await c.send("detach_tool", { tool_id: lecternId });
    expect(needed.error?.code).toBe("INVALID_STATE");
    const refund = await c.ok("detach_tool", { tool_id: forge.tool_id });
    expect(refund.refund).toEqual({ food: 0, wood: 30, stone: 30, gold: 15 });
  });

  it("advances the age after the cost, the milestones and the research timer", async () => {
    const blocked = await c.send("advance_age", {});
    expect(blocked.error?.code).toBe("INVALID_STATE");
    expect(blocked.error?.message).toMatch(/tasks accepted: 0\/3/);

    // Seed three rewarded tasks for the milestone.
    const agentId = town.ctx.db.get<{ id: string }>("SELECT id FROM agents WHERE retired_at IS NULL LIMIT 1")!.id;
    town.ctx.db.tx(() => {
      for (let i = 0; i < 3; i++) {
        town.ctx.db.run(
          `INSERT INTO tasks (id, agent_id, title, prompt, prompt_hash, size, acceptance_json, state, seal_micros, courier_json, created_at, updated_at, accepted_at, reward_rp)
           VALUES (?, ?, 't', 'p', ?, 'S', '[]', 'accepted', 1, '{"mode":"express"}', ?, ?, ?, 60)`,
          [`tsk_seed${i}`, agentId, `h${i}`, town.clock.iso(), town.clock.iso(), town.clock.iso()],
        );
      }
    });
    town.ctx.treasury.credit({ food: 1000, wood: 1000, stone: 1000, gold: 1000 }, "reward", "reward", null, "test-age");
    const started = await c.ok("advance_age", {});
    expect(started.research.target).toBe(2);
    expect(started.research.duration_ms).toBe(90_000);
    await c.waitEvent((e) => e.type === "age_updated" && e.payload.age.research?.target === 2);
    const again = await c.send("advance_age", {});
    expect(again.error?.code).toBe("INVALID_STATE");
    town.clock.advance(90_000);
    await c.waitEvent((e) => e.type === "age_updated" && e.payload.age.current === 2);
    expect(town.ctx.ages.current()).toBe(2);
    expect(town.ctx.econ.agentLimit(2)).toBe(4);
  });

  it("saves the town with revision conflicts and keeps the last 20", async () => {
    let rev = 0;
    for (let i = 0; i < 22; i++) rev = (await c.ok("save_town", { base_rev: rev, schema_version: 1, snapshot: { n: i } })).rev;
    expect(rev).toBe(22);
    const stale = await c.send("save_town", { base_rev: 5, schema_version: 1, snapshot: {} });
    expect(stale.error?.code).toBe("CONFLICT");
    const loaded = await c.ok("load_town", {});
    expect(loaded).toEqual({ rev: 22, schema_version: 1, snapshot: { n: 21 } });
    expect(town.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM town_saves")!.n).toBe(20);
  });

  it("stores settings with defaults", async () => {
    const state = await c.ok("get_state");
    expect(state.settings).toEqual({ work_while_away: true, express_dispatch: false, lantern_hours: { start: 20, end: 7 } });
    const r = await c.ok("set_setting", { key: "express_dispatch", value: true });
    expect(r.settings.express_dispatch).toBe(true);
    const bad = await c.send("set_setting", { key: "express_dispatch", value: "yes" });
    expect(bad.error?.code).toBe("BAD_REQUEST");
    const lanterns = await c.ok("set_setting", { key: "lantern_hours", value: { start: 21, end: 6 } });
    expect(lanterns.settings.lantern_hours).toEqual({ start: 21, end: 6 });
  });

  it("lists providers, models and folders", async () => {
    const providers = await c.ok("check_providers", {});
    expect(providers.providers.map((p: { id: string }) => p.id)).toEqual(["claude", "codex", "pi"]);
    expect(providers.providers[0].installed).toBe(true);
    const models = await c.ok("list_models", { provider: "codex" });
    expect(models.models[0].default).toBe(true);
    const roots = await c.ok("browse_folder", {});
    expect(roots.path).toBeNull();
    expect(roots.roots).toHaveLength(1);
    const listing = await c.ok("browse_folder", { path: town.work });
    expect(listing.entries.some((e: { name: string; is_git_repo: boolean }) => e.name === "app" && e.is_git_repo)).toBe(true);
    const outside = await c.send("browse_folder", { path: town.root });
    expect(outside.error?.code).toBe("WORKSPACE_DENIED");
  });
});
